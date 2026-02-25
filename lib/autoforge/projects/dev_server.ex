defmodule Autoforge.Projects.DevServer do
  @moduledoc """
  GenServer that manages a dev server process inside a project container.
  Streams stdout/stderr via PubSub so LiveView can display server logs.

  The command to run is defined by the project template's `dev_server_script`.
  On stop, the process tree started by the exec is killed via SIGTERM before
  the socket is closed.
  """

  use GenServer

  alias Autoforge.Projects.TemplateRenderer

  require Logger

  defstruct [:socket, :exec_id, :project_id, :project]

  # Public API

  def start_link(project) do
    GenServer.start_link(__MODULE__, project, name: via(project.id))
  end

  def stop(project_id) do
    case Registry.lookup(Autoforge.DevServerRegistry, project_id) do
      [{pid, _}] -> GenServer.stop(pid, :normal)
      [] -> :ok
    end
  end

  def running?(project_id) do
    Registry.lookup(Autoforge.DevServerRegistry, project_id) != []
  end

  # GenServer callbacks

  @impl true
  def init(project) do
    project = Ash.load!(project, [:project_template, :env_vars], authorize?: false)

    case build_script(project) do
      {:ok, script} ->
        case start_exec_session(project, script) do
          {:ok, socket, exec_id, initial_data} ->
            if initial_data != "" do
              broadcast(project.id, {:dev_server_output, initial_data})
            end

            {:ok,
             %__MODULE__{
               socket: socket,
               exec_id: exec_id,
               project_id: project.id,
               project: project
             }}

          {:error, reason} ->
            Logger.error(
              "Failed to start dev server for project #{project.id}: #{inspect(reason)}"
            )

            broadcast(project.id, {:dev_server_stopped, reason})
            {:stop, :normal}
        end

      {:error, reason} ->
        Logger.error(
          "Failed to build dev server script for project #{project.id}: #{inspect(reason)}"
        )

        broadcast(project.id, {:dev_server_stopped, reason})
        {:stop, :normal}
    end
  end

  @impl true
  def handle_info({:tcp, socket, data}, %{socket: socket} = state) do
    broadcast(state.project_id, {:dev_server_output, data})
    {:noreply, state}
  end

  def handle_info({:tcp_closed, socket}, %{socket: socket} = state) do
    Logger.info("Dev server socket closed for project #{state.project_id}")
    broadcast(state.project_id, {:dev_server_stopped, :closed})
    {:stop, :normal, state}
  end

  def handle_info({:tcp_error, socket, reason}, %{socket: socket} = state) do
    Logger.error("Dev server socket error for project #{state.project_id}: #{inspect(reason)}")
    broadcast(state.project_id, {:dev_server_stopped, reason})
    {:stop, :normal, state}
  end

  @impl true
  def terminate(_reason, state) do
    kill_exec_process(state)

    if state.socket do
      :gen_tcp.close(state.socket)
    end

    :ok
  end

  # Private helpers

  defp via(project_id) do
    {:via, Registry, {Autoforge.DevServerRegistry, project_id}}
  end

  defp broadcast(project_id, message) do
    Phoenix.PubSub.broadcast(
      Autoforge.PubSub,
      "project:dev_server:#{project_id}",
      message
    )
  end

  defp docker_socket_path do
    Application.get_env(:autoforge, Autoforge.Projects.Docker, [])[:socket_path] ||
      "/var/run/docker.sock"
  end

  defp build_script(project) do
    template = project.project_template

    case template.dev_server_script do
      nil -> {:error, :no_dev_server_script}
      "" -> {:error, :no_dev_server_script}
      script -> TemplateRenderer.render_script(script, TemplateRenderer.build_variables(project))
    end
  end

  defp kill_exec_process(state) do
    socket_path = docker_socket_path()

    with {:ok, %{status: 200, body: %{"Pid" => pid}}} when pid > 0 <-
           Req.request(
             unix_socket: socket_path,
             base_url: "http://localhost/v1.45",
             url: "/exec/#{state.exec_id}/json",
             method: :get
           ) do
      # Kill the process group (negative PID) to get all children
      Autoforge.Projects.Docker.exec_run(
        state.project.container_id,
        ["kill", "-TERM", "-#{pid}"]
      )
    else
      _ -> :ok
    end
  rescue
    _ -> :ok
  end

  defp start_exec_session(project, script) do
    # Wrap in `exec` so the shell is replaced by the script's final command,
    # making PID tracking cleaner. Use set -e so early lines fail fast.
    wrapped = "set -e\n#{script}"

    vars = TemplateRenderer.build_variables(project)

    user_env_vars = build_user_env_vars(project)

    tailscale_env = build_tailscale_env_vars(vars)

    exec_config = %{
      "AttachStdin" => false,
      "AttachStdout" => true,
      "AttachStderr" => true,
      "Tty" => true,
      "Cmd" => ["/bin/bash", "-c", wrapped],
      "User" => "app",
      "WorkingDir" => "/app",
      "Env" =>
        [
          "TERM=xterm-256color",
          "HOME=/home/app",
          "MIX_ENV=dev",
          "PORT=4000",
          "DATABASE_URL=postgresql://#{vars["db_user"]}:#{vars["db_password"]}@#{vars["db_host"]}:#{vars["db_port"]}/#{vars["db_name"]}",
          "DATABASE_TEST_URL=postgresql://#{vars["db_user"]}:#{vars["db_password"]}@#{vars["db_host"]}:#{vars["db_port"]}/#{vars["db_test_name"]}",
          "DB_HOST=#{vars["db_host"]}",
          "DB_PORT=#{vars["db_port"]}",
          "DB_NAME=#{vars["db_name"]}",
          "DB_TEST_NAME=#{vars["db_test_name"]}",
          "DB_USER=#{vars["db_user"]}",
          "DB_PASSWORD=#{vars["db_password"]}"
        ] ++ tailscale_env ++ user_env_vars
    }

    socket_path = docker_socket_path()

    with {:ok, exec_id} <- create_exec(project.container_id, exec_config),
         {:ok, socket, initial_data} <- start_exec_stream(exec_id, socket_path) do
      {:ok, socket, exec_id, initial_data}
    end
  end

  defp create_exec(container_id, config) do
    socket_path = docker_socket_path()

    case Req.request(
           unix_socket: socket_path,
           base_url: "http://localhost/v1.45",
           url: "/containers/#{container_id}/exec",
           method: :post,
           json: config
         ) do
      {:ok, %{status: 201, body: %{"Id" => id}}} -> {:ok, id}
      {:ok, %{body: body}} -> {:error, {:exec_create_failed, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp start_exec_stream(exec_id, socket_path) do
    case :gen_tcp.connect({:local, socket_path}, 0, [:binary, active: false, packet: :raw]) do
      {:ok, socket} ->
        body = Jason.encode!(%{"Detach" => false, "Tty" => true})

        request =
          "POST /v1.45/exec/#{exec_id}/start HTTP/1.1\r\n" <>
            "Host: localhost\r\n" <>
            "Content-Type: application/json\r\n" <>
            "Connection: Upgrade\r\n" <>
            "Upgrade: tcp\r\n" <>
            "Content-Length: #{byte_size(body)}\r\n" <>
            "\r\n" <>
            body

        :ok = :gen_tcp.send(socket, request)

        case read_http_response(socket) do
          {:ok, status, initial_data} when status in [101, 200] ->
            :inet.setopts(socket, active: true)
            {:ok, socket, initial_data}

          {:ok, _status, _} ->
            :gen_tcp.close(socket)
            {:error, :unexpected_status}

          {:error, reason} ->
            :gen_tcp.close(socket)
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp read_http_response(socket, buffer \\ <<>>) do
    case :gen_tcp.recv(socket, 0, 5_000) do
      {:ok, data} ->
        buffer = buffer <> data

        case :binary.split(buffer, "\r\n\r\n") do
          [headers, rest] ->
            case parse_status(headers) do
              {:ok, status} -> {:ok, status, rest}
              :error -> {:error, :invalid_response}
            end

          [_incomplete] ->
            read_http_response(socket, buffer)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_status(headers) do
    case String.split(headers, "\r\n", parts: 2) do
      ["HTTP/1.1 " <> status_line | _] ->
        case Integer.parse(status_line) do
          {status, _} -> {:ok, status}
          :error -> :error
        end

      _ ->
        :error
    end
  end

  defp build_user_env_vars(%{env_vars: vars}) when is_list(vars) do
    Enum.map(vars, fn var -> "#{var.key}=#{var.value}" end)
  end

  defp build_user_env_vars(_), do: []

  defp build_tailscale_env_vars(%{"phx_host" => host, "app_url" => url})
       when is_binary(host) and is_binary(url) do
    ["APP_URL=#{url}", "PHX_HOST=#{host}"]
  end

  defp build_tailscale_env_vars(_), do: []
end
