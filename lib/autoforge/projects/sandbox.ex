defmodule Autoforge.Projects.Sandbox do
  @moduledoc """
  High-level orchestration module for project sandbox lifecycle.
  """

  alias Autoforge.Projects.{
    Docker,
    ProjectFiles,
    ProjectTemplateFile,
    Tailscale,
    TarBuilder,
    TemplateRenderer
  }

  require Ash.Query
  require Logger

  @pg_ready_attempts 30
  @pg_ready_delay_ms 1_000

  @doc """
  Provisions a project: creates Docker network, Postgres container, app container,
  uploads template files, runs bootstrap script, and transitions to :running.
  """
  def provision(project) do
    project = Ash.load!(project, [:project_template, :env_vars], authorize?: false)
    variables = TemplateRenderer.build_variables(project)
    network_name = "autoforge-#{project.id}"
    db_alias = "db-#{project.id}"
    base_image = project.project_template.base_image
    db_image = project.project_template.db_image

    with {:ok, project} <- transition(project, :provision),
         {:ok, host_port} <- allocate_port(),
         {:ok, code_server_port} <- allocate_port(),
         :ok <-
           log_and_run(project, "Pulling image #{db_image}...", fn ->
             Docker.pull_image(db_image)
           end),
         :ok <-
           log_and_run(project, "Pulling image #{base_image}...", fn ->
             Docker.pull_image(base_image)
           end),
         {:ok, network_id} <-
           log_and_run(project, "Creating network...", fn ->
             Docker.create_network(network_name)
           end),
         {:ok, db_container_id} <-
           log_and_run(project, "Starting database...", fn ->
             create_db_container(project, network_id, db_alias)
           end),
         :ok <- Docker.start_container(db_container_id),
         :ok <-
           log_and_run(project, "Waiting for database...", fn ->
             wait_for_postgres(db_container_id)
           end),
         _ <- broadcast_provision_log(project, "Database ready"),
         :ok <- create_test_database(db_container_id, project),
         {:ok, app_container_id} <-
           log_and_run(project, "Creating application container...", fn ->
             create_app_container(project, network_id, host_port, code_server_port)
           end),
         :ok <- Docker.start_container(app_container_id),
         {ts_container_id, ts_hostname} <-
           maybe_create_tailscale_sidecar(project, app_container_id),
         variables <- maybe_add_tailscale_vars(variables, ts_hostname),
         :ok <-
           log_and_run(project, "Uploading template files...", fn ->
             upload_template_files(app_container_id, project, variables)
           end),
         :ok <- run_bootstrap_script(app_container_id, project, variables),
         :ok <-
           log_and_run(project, "Creating app user...", fn ->
             create_sandbox_user(app_container_id)
           end),
         :ok <- install_code_server(app_container_id, project),
         :ok <- install_code_server_extensions(app_container_id, project),
         :ok <- run_startup_script(app_container_id, project, variables),
         _ <- sync_project_files(project),
         _ <- broadcast_provision_log(project, "Provisioning complete"),
         {:ok, project} <-
           Ash.update(
             project,
             %{
               container_id: app_container_id,
               db_container_id: db_container_id,
               network_id: network_id,
               host_port: host_port,
               code_server_port: code_server_port,
               tailscale_container_id: ts_container_id,
               tailscale_hostname: ts_hostname
             },
             action: :mark_running,
             authorize?: false
           ) do
      {:ok, project}
    else
      {:error, reason} ->
        Logger.error("Failed to provision project #{project.id}: #{inspect(reason)}")
        broadcast_provision_log(project, "Error: #{inspect(reason)}")

        Ash.update(project, %{error_message: inspect(reason)},
          action: :mark_error,
          authorize?: false
        )

        {:error, reason}
    end
  end

  @doc """
  Starts a stopped project by restarting its containers.
  """
  def start(project) do
    project = Ash.load!(project, [:project_template, :env_vars], authorize?: false)
    variables = TemplateRenderer.build_variables(project)

    with :ok <- Docker.start_container(project.db_container_id),
         :ok <- Docker.start_container(project.container_id),
         :ok <- maybe_start_tailscale(project),
         :ok <- create_sandbox_user(project.container_id),
         :ok <- run_startup_script(project.container_id, project, variables),
         _ <- sync_project_files(project),
         {:ok, project} <- Ash.update(project, %{}, action: :start, authorize?: false) do
      {:ok, project}
    else
      {:error, reason} ->
        Logger.error("Failed to start project #{project.id}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Stops a running project by stopping its containers.
  """
  def stop(project) do
    with :ok <- maybe_stop_tailscale(project),
         :ok <- Docker.stop_container(project.container_id),
         :ok <- Docker.stop_container(project.db_container_id),
         {:ok, project} <- Ash.update(project, %{}, action: :stop, authorize?: false) do
      {:ok, project}
    else
      {:error, reason} ->
        Logger.error("Failed to stop project #{project.id}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Destroys a project by removing its containers and network.
  """
  def destroy(project) do
    with {:ok, project} <- Ash.update(project, %{}, action: :begin_destroy, authorize?: false) do
      Tailscale.remove_sidecar(project)

      if project.container_id do
        Docker.stop_container(project.container_id, timeout: 5)
        Docker.remove_container(project.container_id, force: true)
      end

      if project.db_container_id do
        Docker.stop_container(project.db_container_id, timeout: 5)
        Docker.remove_container(project.db_container_id, force: true)
      end

      if project.network_id do
        Docker.remove_network(project.network_id)
      end

      Ash.update(project, %{}, action: :mark_destroyed, authorize?: false)
    end
  end

  @doc """
  Updates the last activity timestamp on a project.
  """
  def touch(project) do
    Ash.update(project, %{}, action: :touch, authorize?: false)
  end

  @doc """
  Asynchronously touches a project's last activity timestamp.
  """
  def touch_async(project) do
    Task.Supervisor.start_child(Autoforge.TaskSupervisor, fn ->
      touch(project)
    end)
  end

  @doc """
  Writes a `.autoforge.env` file to the running container with `export KEY='VALUE'`
  lines for each env var. New exec sessions (terminals, dev server) will pick these up.
  """
  def sync_env_vars(project_id) do
    alias Autoforge.Projects.Project

    project =
      Project
      |> Ash.Query.filter(id == ^project_id)
      |> Ash.Query.load(:env_vars)
      |> Ash.read_one!(authorize?: false)

    if project && project.container_id && project.state == :running do
      lines =
        project.env_vars
        |> Enum.map(fn var ->
          escaped = String.replace(var.value, "'", "'\\''")
          "export #{var.key}='#{escaped}'"
        end)
        |> Enum.join("\n")

      content = if lines == "", do: "", else: lines <> "\n"

      Docker.exec_run(project.container_id, [
        "/bin/bash",
        "-c",
        "cat > /app/.autoforge.env << 'AUTOFORGE_EOF'\n#{content}AUTOFORGE_EOF"
      ])
    end

    :ok
  end

  # Private helpers

  defp allocate_port do
    case :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true]) do
      {:ok, socket} ->
        {:ok, port} = :inet.port(socket)
        :gen_tcp.close(socket)
        {:ok, port}

      {:error, reason} ->
        {:error, {:port_allocation_failed, reason}}
    end
  end

  defp broadcast_provision_log(project, message) do
    Phoenix.PubSub.broadcast(
      Autoforge.PubSub,
      "project:provision_log:#{project.id}",
      {:provision_log, message}
    )
  end

  defp log_and_run(project, message, fun) do
    broadcast_provision_log(project, message)
    fun.()
  end

  defp transition(project, action) do
    Ash.update(project, %{}, action: action, authorize?: false)
  end

  defp create_db_container(project, network_id, db_alias) do
    config = %{
      "Image" => project.project_template.db_image,
      "Env" => [
        "POSTGRES_DB=#{project.db_name}",
        "POSTGRES_USER=postgres",
        "POSTGRES_PASSWORD=#{project.db_password}"
      ],
      "HostConfig" => %{
        "NetworkMode" => network_id
      },
      "NetworkingConfig" => %{
        "EndpointsConfig" => %{
          network_id => %{
            "Aliases" => [db_alias]
          }
        }
      }
    }

    Docker.create_container(config, name: "autoforge-db-#{project.id}")
  end

  defp create_app_container(project, network_id, host_port, code_server_port) do
    template = project.project_template

    user_env_vars = build_user_env_vars(project)

    config = %{
      "Image" => template.base_image,
      "Cmd" => ["sleep", "infinity"],
      "WorkingDir" => "/app",
      "Env" =>
        [
          "PORT=4000",
          "DATABASE_URL=postgresql://postgres:#{project.db_password}@db-#{project.id}:5432/#{project.db_name}",
          "DATABASE_TEST_URL=postgresql://postgres:#{project.db_password}@db-#{project.id}:5432/#{project.db_name}_test",
          "DB_HOST=db-#{project.id}",
          "DB_PORT=5432",
          "DB_NAME=#{project.db_name}",
          "DB_TEST_NAME=#{project.db_name}_test",
          "DB_USER=postgres",
          "DB_PASSWORD=#{project.db_password}"
        ] ++ user_env_vars,
      "ExposedPorts" => %{"4000/tcp" => %{}, "8080/tcp" => %{}},
      "HostConfig" => %{
        "NetworkMode" => network_id,
        "PortBindings" => %{
          "4000/tcp" => [%{"HostPort" => to_string(host_port)}],
          "8080/tcp" => [%{"HostPort" => to_string(code_server_port)}]
        }
      }
    }

    Docker.create_container(config, name: "autoforge-app-#{project.id}")
  end

  defp wait_for_postgres(container_id, attempt \\ 1) do
    if attempt > @pg_ready_attempts do
      {:error, :postgres_not_ready}
    else
      case Docker.exec_run(container_id, ["pg_isready", "-U", "postgres"]) do
        {:ok, %{exit_code: 0}} ->
          # pg_isready can succeed during the postgres Docker image's first init phase,
          # before it restarts to apply final configuration. Verify with an actual query
          # to ensure postgres is fully ready and accepting real connections.
          verify_postgres_connection(container_id)

        _ ->
          Process.sleep(@pg_ready_delay_ms)
          wait_for_postgres(container_id, attempt + 1)
      end
    end
  end

  defp verify_postgres_connection(container_id, attempt \\ 1) do
    case Docker.exec_run(container_id, ["psql", "-U", "postgres", "-c", "SELECT 1"]) do
      {:ok, %{exit_code: 0}} ->
        :ok

      _ when attempt < @pg_ready_attempts ->
        Process.sleep(@pg_ready_delay_ms)
        verify_postgres_connection(container_id, attempt + 1)

      _ ->
        {:error, :postgres_not_ready}
    end
  end

  defp create_test_database(db_container_id, project) do
    test_db = project.db_name <> "_test"

    case Docker.exec_run(db_container_id, [
           "psql",
           "-U",
           "postgres",
           "-c",
           "CREATE DATABASE \"#{test_db}\";"
         ]) do
      {:ok, %{exit_code: 0}} -> :ok
      {:ok, %{exit_code: _, output: output}} -> {:error, "Failed to create test DB: #{output}"}
      {:error, reason} -> {:error, reason}
    end
  end

  defp upload_template_files(container_id, project, variables) do
    files =
      ProjectTemplateFile
      |> Ash.Query.filter(project_template_id == ^project.project_template_id)
      |> Ash.read!(authorize?: false)

    case files do
      [] ->
        :ok

      files ->
        case TarBuilder.build_from_template_files(files, variables) do
          {:ok, tar_binary} -> Docker.put_archive(container_id, "/app", tar_binary)
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp run_bootstrap_script(container_id, project, variables) do
    template = project.project_template

    case TemplateRenderer.render_script(template.bootstrap_script, variables) do
      {:ok, ""} ->
        :ok

      {:ok, script} ->
        broadcast_provision_log(project, "Running bootstrap script...")

        callback = fn chunk ->
          broadcast_provision_log(project, {:output, chunk})
        end

        case Docker.exec_stream(container_id, ["/bin/bash", "-c", script], callback,
               working_dir: "/app"
             ) do
          {:ok, 0} ->
            :ok

          {:ok, code} ->
            {:error, "Bootstrap failed (exit #{code})"}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp create_sandbox_user(container_id) do
    # Create the app user idempotently, handling the case where UID 1000
    # is already taken by another user (e.g. "ubuntu" in Ubuntu images).
    script = """
    if id -u app >/dev/null 2>&1; then
      exit 0
    fi
    existing=$(getent passwd 1000 | cut -d: -f1)
    if [ -n "$existing" ]; then
      usermod -l app -d /home/app -m "$existing"
      groupmod -n app "$existing"
    else
      useradd -m -u 1000 -s /bin/bash app
    fi
    """

    with {:ok, %{exit_code: 0}} <-
           Docker.exec_run(container_id, ["/bin/bash", "-c", script]),
         {:ok, %{exit_code: 0}} <-
           Docker.exec_run(container_id, ["chown", "-R", "app:app", "/app"]) do
      :ok
    else
      {:ok, %{exit_code: code, output: output}} ->
        {:error, "Failed to create app user (exit #{code}): #{output}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp install_code_server(container_id, project) do
    broadcast_provision_log(project, "Installing code-server...")

    script = """
    if command -v code-server >/dev/null 2>&1; then
      exit 0
    fi
    curl -fsSL https://code-server.dev/install.sh | sh
    """

    callback = fn chunk -> broadcast_provision_log(project, {:output, chunk}) end

    case Docker.exec_stream(container_id, ["/bin/bash", "-c", script], callback) do
      {:ok, 0} -> :ok
      {:ok, code} -> {:error, "code-server install failed (exit #{code})"}
      {:error, reason} -> {:error, reason}
    end
  end

  defp install_code_server_extensions(container_id, project) do
    extensions = project.project_template.code_server_extensions || []

    if extensions == [] do
      :ok
    else
      broadcast_provision_log(project, "Installing code-server extensions...")

      Enum.reduce_while(extensions, :ok, fn ext, :ok ->
        case Docker.exec_run(container_id, ["code-server", "--install-extension", ext.id],
               user: "app"
             ) do
          {:ok, %{exit_code: 0}} ->
            {:cont, :ok}

          {:ok, %{exit_code: _code, output: output}} ->
            Logger.warning("Failed to install extension #{ext.id}: #{output}")
            {:cont, :ok}

          {:error, reason} ->
            {:halt, {:error, reason}}
        end
      end)
    end
  end

  defp run_startup_script(container_id, project, variables) do
    template = project.project_template

    case TemplateRenderer.render_script(template.startup_script, variables) do
      {:ok, ""} ->
        :ok

      {:ok, script} ->
        broadcast_provision_log(project, "Running startup script...")

        callback = fn chunk ->
          broadcast_provision_log(project, {:output, chunk})
        end

        case Docker.exec_stream(container_id, ["/bin/bash", "-c", script], callback,
               working_dir: "/app",
               user: "app"
             ) do
          {:ok, 0} ->
            :ok

          {:ok, code} ->
            {:error, "Startup script failed (exit #{code})"}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build_user_env_vars(project) do
    case project do
      %{env_vars: vars} when is_list(vars) ->
        Enum.map(vars, fn var -> "#{var.key}=#{var.value}" end)

      _ ->
        []
    end
  end

  defp maybe_create_tailscale_sidecar(project, app_container_id) do
    case Tailscale.create_sidecar(project, app_container_id) do
      {:ok, container_id, hostname} ->
        broadcast_provision_log(project, "Starting Tailscale sidecar...")
        {container_id, hostname}

      :disabled ->
        {nil, nil}

      {:error, reason} ->
        Logger.warning("Tailscale sidecar failed, continuing without: #{inspect(reason)}")
        broadcast_provision_log(project, "Tailscale sidecar failed, continuing without")
        {nil, nil}
    end
  end

  defp maybe_add_tailscale_vars(variables, nil), do: variables

  defp maybe_add_tailscale_vars(variables, hostname) do
    case Tailscale.get_tailnet_name() do
      {:ok, tailnet} ->
        url = Tailscale.build_url(hostname, tailnet)

        Map.merge(variables, %{
          "app_url" => url,
          "phx_host" => "#{hostname}.#{tailnet}"
        })

      :disabled ->
        variables
    end
  end

  defp maybe_start_tailscale(%{tailscale_container_id: id}) when is_binary(id) do
    Docker.start_container(id)
  end

  defp maybe_start_tailscale(_), do: :ok

  defp maybe_stop_tailscale(%{tailscale_container_id: id}) when is_binary(id) do
    Docker.stop_container(id)
  end

  defp maybe_stop_tailscale(_), do: :ok

  defp sync_project_files(project) do
    case ProjectFiles.sync_to_container(project) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("Failed to sync project files for #{project.id}: #{inspect(reason)}")
        :ok
    end
  rescue
    error ->
      Logger.warning("Failed to sync project files for #{project.id}: #{inspect(error)}")
      :ok
  end
end
