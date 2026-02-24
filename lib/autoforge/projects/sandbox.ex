defmodule Autoforge.Projects.Sandbox do
  @moduledoc """
  High-level orchestration module for project sandbox lifecycle.
  """

  alias Autoforge.Projects.{Docker, ProjectTemplateFile, TarBuilder, TemplateRenderer}

  require Ash.Query
  require Logger

  @pg_ready_attempts 30
  @pg_ready_delay_ms 1_000

  @doc """
  Provisions a project: creates Docker network, Postgres container, app container,
  uploads template files, runs bootstrap script, and transitions to :running.
  """
  def provision(project) do
    project = Ash.load!(project, [:project_template], authorize?: false)
    variables = TemplateRenderer.build_variables(project)
    network_name = "autoforge-#{project.id}"
    db_alias = "db-#{project.id}"
    base_image = project.project_template.base_image

    with {:ok, project} <- transition(project, :provision),
         :ok <-
           log_and_run(project, "Pulling image postgres:18-alpine...", fn ->
             Docker.pull_image("postgres:18-alpine")
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
             create_app_container(project, network_id)
           end),
         :ok <- Docker.start_container(app_container_id),
         :ok <-
           log_and_run(project, "Uploading template files...", fn ->
             upload_template_files(app_container_id, project, variables)
           end),
         :ok <- run_bootstrap_script(app_container_id, project, variables),
         _ <- broadcast_provision_log(project, "Provisioning complete"),
         {:ok, project} <-
           Ash.update(
             project,
             %{
               container_id: app_container_id,
               db_container_id: db_container_id,
               network_id: network_id
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
    with :ok <- Docker.start_container(project.db_container_id),
         :ok <- Docker.start_container(project.container_id),
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
    with :ok <- Docker.stop_container(project.container_id),
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

  # Private helpers

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
      "Image" => "postgres:18-alpine",
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

  defp create_app_container(project, network_id) do
    template = project.project_template

    config = %{
      "Image" => template.base_image,
      "Cmd" => ["sleep", "infinity"],
      "WorkingDir" => "/app",
      "Env" => [
        "DATABASE_URL=postgresql://postgres:#{project.db_password}@db-#{project.id}:5432/#{project.db_name}",
        "DATABASE_TEST_URL=postgresql://postgres:#{project.db_password}@db-#{project.id}:5432/#{project.db_name}_test",
        "DB_HOST=db-#{project.id}",
        "DB_PORT=5432",
        "DB_NAME=#{project.db_name}",
        "DB_TEST_NAME=#{project.db_name}_test",
        "DB_USER=postgres",
        "DB_PASSWORD=#{project.db_password}"
      ],
      "HostConfig" => %{
        "NetworkMode" => network_id
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
          :ok

        _ ->
          Process.sleep(@pg_ready_delay_ms)
          wait_for_postgres(container_id, attempt + 1)
      end
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

        case Docker.exec_stream(container_id, ["/bin/sh", "-c", script], callback,
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
end
