defmodule Autoforge.Projects.CodeServer do
  @moduledoc """
  GenServer that manages a code-server (VS Code in browser) process inside a
  project container. Broadcasts readiness and output via PubSub so the LiveView
  can embed code-server in an iframe once it's listening.

  On stop, the process tree started by the exec is killed via SIGTERM before
  the socket is closed.
  """

  use GenServer

  require Logger

  defstruct [:socket, :exec_id, :project_id, :project, ready?: false]

  # Public API

  def start_link(project) do
    GenServer.start_link(__MODULE__, project, name: via(project.id))
  end

  def stop(project_id) do
    case Registry.lookup(Autoforge.CodeServerRegistry, project_id) do
      [{pid, _}] -> GenServer.stop(pid, :normal)
      [] -> :ok
    end
  end

  def running?(project_id) do
    Registry.lookup(Autoforge.CodeServerRegistry, project_id) != []
  end

  def ready?(project_id) do
    case Registry.lookup(Autoforge.CodeServerRegistry, project_id) do
      [{pid, _}] -> GenServer.call(pid, :ready?)
      [] -> false
    end
  catch
    :exit, _ -> false
  end

  # GenServer callbacks

  @impl true
  def init(project) do
    project = Ash.load!(project, [:project_template, :env_vars], authorize?: false)

    {:ok,
     %__MODULE__{
       project_id: project.id,
       project: project
     }, {:continue, :start}}
  end

  @impl true
  def handle_continue(:start, state) do
    project = state.project

    with :ok <- ensure_code_server_installed(project),
         {:ok, socket, exec_id, initial_data} <- start_exec_session(project) do
      ready = String.contains?(initial_data, "HTTP server listening on")

      if initial_data != "" do
        broadcast(project.id, {:code_server_output, initial_data})
      end

      if ready do
        broadcast(project.id, {:code_server_started})
      end

      install_extensions_async(project)

      {:noreply, %{state | socket: socket, exec_id: exec_id, ready?: ready}}
    else
      {:error, reason} ->
        Logger.error("Failed to start code-server for project #{project.id}: #{inspect(reason)}")

        broadcast(project.id, {:code_server_stopped, reason})
        {:stop, :normal, state}
    end
  end

  @impl true
  def handle_call(:ready?, _from, state) do
    {:reply, state.ready?, state}
  end

  @impl true
  def handle_info({:tcp, socket, data}, %{socket: socket} = state) do
    broadcast(state.project_id, {:code_server_output, data})

    state =
      if not state.ready? and String.contains?(data, "HTTP server listening on") do
        broadcast(state.project_id, {:code_server_started})
        %{state | ready?: true}
      else
        state
      end

    {:noreply, state}
  end

  def handle_info({:tcp_closed, socket}, %{socket: socket} = state) do
    Logger.info("Code-server socket closed for project #{state.project_id}")
    broadcast(state.project_id, {:code_server_stopped, :closed})
    {:stop, :normal, state}
  end

  def handle_info({:tcp_error, socket, reason}, %{socket: socket} = state) do
    Logger.error("Code-server socket error for project #{state.project_id}: #{inspect(reason)}")

    broadcast(state.project_id, {:code_server_stopped, reason})
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
    {:via, Registry, {Autoforge.CodeServerRegistry, project_id}}
  end

  defp broadcast(project_id, message) do
    Phoenix.PubSub.broadcast(
      Autoforge.PubSub,
      "project:code_server:#{project_id}",
      message
    )
  end

  defp docker_socket_path do
    Application.get_env(:autoforge, Autoforge.Projects.Docker, [])[:socket_path] ||
      "/var/run/docker.sock"
  end

  defp ensure_code_server_installed(project) do
    alias Autoforge.Projects.Docker

    script = """
    if command -v code-server >/dev/null 2>&1; then
      exit 0
    fi
    curl -fsSL https://code-server.dev/install.sh | sh
    """

    callback = fn _chunk -> :ok end

    case Docker.exec_stream(project.container_id, ["/bin/bash", "-c", script], callback) do
      {:ok, 0} -> :ok
      {:ok, code} -> {:error, "code-server install failed (exit #{code})"}
      {:error, reason} -> {:error, reason}
    end
  end

  defp install_extensions_async(project) do
    extensions = project.project_template.code_server_extensions || []

    if extensions != [] do
      Task.Supervisor.start_child(Autoforge.TaskSupervisor, fn ->
        Enum.each(extensions, fn ext ->
          case Autoforge.Projects.Docker.exec_run(
                 project.container_id,
                 ["code-server", "--install-extension", ext.id],
                 user: "app"
               ) do
            {:ok, %{exit_code: 0}} ->
              :ok

            {:ok, %{exit_code: _code, output: output}} ->
              Logger.warning("Failed to install extension #{ext.id}: #{output}")

            {:error, reason} ->
              Logger.warning("Failed to install extension #{ext.id}: #{inspect(reason)}")
          end
        end)
      end)
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

  defp start_exec_session(project) do
    cmd =
      "code-server --auth none --bind-addr 0.0.0.0:8080 --disable-telemetry --disable-update-check /app"

    exec_config = %{
      "AttachStdin" => false,
      "AttachStdout" => true,
      "AttachStderr" => true,
      "Tty" => true,
      "Cmd" => ["/bin/bash", "-c", cmd],
      "User" => "app",
      "WorkingDir" => "/app",
      "Env" => [
        "TERM=xterm-256color",
        "HOME=/home/app",
        "PORT=8080"
      ]
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
end
