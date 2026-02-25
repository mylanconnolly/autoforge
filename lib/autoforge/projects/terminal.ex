defmodule Autoforge.Projects.Terminal do
  @moduledoc """
  GenServer that manages a terminal session for a project sandbox.
  Connects to the Docker API via Unix socket to create a streaming exec
  session, piping stdin/stdout between the socket and a Phoenix Channel.
  """

  use GenServer

  alias Autoforge.Projects.Docker

  require Logger

  defstruct [:socket, :exec_id, :channel_pid, :project, :monitor_ref]

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  def send_input(pid, data) do
    GenServer.cast(pid, {:input, data})
  end

  def resize(pid, cols, rows) do
    GenServer.cast(pid, {:resize, cols, rows})
  end

  @impl true
  def init(opts) do
    project = Keyword.fetch!(opts, :project)
    project = Ash.load!(project, [:env_vars], authorize?: false)
    user = Keyword.fetch!(opts, :user)
    channel_pid = Keyword.fetch!(opts, :channel_pid)
    monitor_ref = Process.monitor(channel_pid)

    setup_container_user_config(project.container_id, user)

    case start_exec_session(project) do
      {:ok, socket, exec_id, initial_data} ->
        if initial_data != "" do
          send(channel_pid, {:terminal_output, initial_data})
        end

        Autoforge.Projects.Sandbox.touch_async(project)

        {:ok,
         %__MODULE__{
           socket: socket,
           exec_id: exec_id,
           channel_pid: channel_pid,
           project: project,
           monitor_ref: monitor_ref
         }}

      {:error, reason} ->
        Logger.error(
          "Failed to start terminal exec for project #{project.id}: #{inspect(reason)}"
        )

        send(channel_pid, :terminal_closed)
        {:stop, :normal}
    end
  end

  @impl true
  def handle_cast({:input, data}, state) do
    :gen_tcp.send(state.socket, data)
    Autoforge.Projects.Sandbox.touch_async(state.project)
    {:noreply, state}
  end

  def handle_cast({:resize, cols, rows}, state) do
    resize_exec(state.exec_id, cols, rows)
    {:noreply, state}
  end

  @impl true
  def handle_info({:tcp, socket, data}, %{socket: socket} = state) do
    send(state.channel_pid, {:terminal_output, data})
    {:noreply, state}
  end

  def handle_info({:tcp_closed, socket}, %{socket: socket} = state) do
    Logger.info("Terminal socket closed for project #{state.project.id}")
    send(state.channel_pid, :terminal_closed)
    {:stop, :normal, state}
  end

  def handle_info({:tcp_error, socket, reason}, %{socket: socket} = state) do
    Logger.error("Terminal socket error for project #{state.project.id}: #{inspect(reason)}")
    send(state.channel_pid, :terminal_closed)
    {:stop, :normal, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{monitor_ref: ref} = state) do
    Logger.info("Terminal channel disconnected for project #{state.project.id}")
    {:stop, :normal, state}
  end

  @impl true
  def terminate(_reason, state) do
    if state.socket do
      :gen_tcp.close(state.socket)
    end

    :ok
  end

  # Private helpers

  defp setup_container_user_config(container_id, user) do
    if user.ssh_private_key && user.ssh_public_key do
      inject_ssh_keys(container_id, user)
    end

    configure_git(container_id, user)
  rescue
    e ->
      Logger.warning("Container user config setup failed: #{inspect(e)}")
  end

  defp inject_ssh_keys(container_id, user) do
    ssh_config = "Host *\n  StrictHostKeyChecking accept-new\n"

    commands = [
      ["mkdir", "-p", "/home/app/.ssh"],
      [
        "/bin/bash",
        "-c",
        "cat > /home/app/.ssh/id_ed25519 << 'SSHEOF'\n#{user.ssh_private_key}SSHEOF"
      ],
      ["chmod", "600", "/home/app/.ssh/id_ed25519"],
      [
        "/bin/bash",
        "-c",
        "cat > /home/app/.ssh/id_ed25519.pub << 'SSHEOF'\n#{user.ssh_public_key}\nSSHEOF"
      ],
      ["chmod", "644", "/home/app/.ssh/id_ed25519.pub"],
      ["/bin/bash", "-c", "cat > /home/app/.ssh/config << 'SSHEOF'\n#{ssh_config}SSHEOF"],
      ["chmod", "600", "/home/app/.ssh/config"],
      ["chown", "-R", "app:app", "/home/app/.ssh"]
    ]

    run_setup_commands(container_id, commands, "SSH key injection")
  end

  defp configure_git(container_id, user) do
    # Only configure git if it's available in the container
    case Docker.exec_run(container_id, ["which", "git"]) do
      {:ok, %{exit_code: 0}} ->
        commands =
          [
            ["git", "config", "--global", "init.defaultBranch", "main"],
            ["git", "config", "--global", "user.email", to_string(user.email)]
          ] ++
            if(user.name, do: [["git", "config", "--global", "user.name", user.name]], else: []) ++
            if user.ssh_private_key && user.ssh_public_key do
              [
                ["git", "config", "--global", "gpg.format", "ssh"],
                [
                  "git",
                  "config",
                  "--global",
                  "user.signingkey",
                  "/home/app/.ssh/id_ed25519.pub"
                ],
                ["git", "config", "--global", "commit.gpgsign", "true"]
              ]
            else
              []
            end

        run_setup_commands(container_id, commands, "Git configuration", user: "app")

      _ ->
        Logger.debug("git not available in container #{container_id}, skipping git config")
    end
  end

  defp run_setup_commands(container_id, commands, label, opts \\ []) do
    Enum.each(commands, fn cmd ->
      case Docker.exec_run(container_id, cmd, opts) do
        {:ok, %{exit_code: 0}} ->
          :ok

        {:ok, %{exit_code: code, output: out}} ->
          Logger.warning("#{label} command failed (exit #{code}): #{out}")

        {:error, reason} ->
          Logger.warning("#{label} command error: #{inspect(reason)}")
      end
    end)
  end

  defp docker_socket_path do
    Application.get_env(:autoforge, Autoforge.Projects.Docker, [])[:socket_path] ||
      "/var/run/docker.sock"
  end

  defp start_exec_session(project) do
    user_env_vars = build_user_env_vars(project)

    exec_config = %{
      "AttachStdin" => true,
      "AttachStdout" => true,
      "AttachStderr" => true,
      "Tty" => true,
      "Cmd" => ["/bin/bash", "-l"],
      "User" => "app",
      "WorkingDir" => "/app",
      "Env" =>
        [
          "TERM=xterm-256color",
          "COLORTERM=truecolor",
          "HOME=/home/app",
          "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/home/app/.local/bin"
        ] ++ user_env_vars
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

          {:ok, status, _} ->
            :gen_tcp.close(socket)
            {:error, {:unexpected_status, status}}

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

  defp resize_exec(exec_id, cols, rows) do
    socket_path = docker_socket_path()

    Task.start(fn ->
      Req.request(
        unix_socket: socket_path,
        base_url: "http://localhost/v1.45",
        url: "/exec/#{exec_id}/resize",
        method: :post,
        params: [w: cols, h: rows]
      )
    end)
  end

  defp build_user_env_vars(%{env_vars: vars}) when is_list(vars) do
    Enum.map(vars, fn var -> "#{var.key}=#{var.value}" end)
  end

  defp build_user_env_vars(_), do: []
end
