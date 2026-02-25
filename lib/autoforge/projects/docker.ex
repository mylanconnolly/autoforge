defmodule Autoforge.Projects.Docker do
  @moduledoc """
  Docker Engine API client using Req over a Unix socket.
  """

  @doc """
  Pulls a Docker image by name (e.g. "postgres:18-alpine").
  """
  def pull_image(image) do
    case docker_req(:post, "/images/create",
           params: [fromImage: image],
           receive_timeout: 300_000,
           raw: true
         ) do
      {:ok, %{status: 200}} -> :ok
      {:ok, %{body: body}} -> {:error, body}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Creates a Docker container with the given configuration.
  """
  def create_container(config, opts \\ []) do
    name = Keyword.get(opts, :name)
    query = if name, do: [name: name], else: []

    case docker_req(:post, "/containers/create", json: config, params: query) do
      {:ok, %{status: 201, body: %{"Id" => id}}} -> {:ok, id}
      {:ok, %{body: body}} -> {:error, body}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Starts a Docker container by ID.
  """
  def start_container(id) do
    case docker_req(:post, "/containers/#{id}/start") do
      {:ok, %{status: status}} when status in [204, 304] -> :ok
      {:ok, %{body: body}} -> {:error, body}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Stops a Docker container by ID.
  """
  def stop_container(id, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 10)

    case docker_req(:post, "/containers/#{id}/stop", params: [t: timeout]) do
      {:ok, %{status: status}} when status in [204, 304] -> :ok
      {:ok, %{status: 404}} -> :ok
      {:ok, %{body: body}} -> {:error, body}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Removes a Docker container by ID.
  """
  def remove_container(id, opts \\ []) do
    force = Keyword.get(opts, :force, false)
    volumes = Keyword.get(opts, :volumes, true)

    case docker_req(:delete, "/containers/#{id}", params: [force: force, v: volumes]) do
      {:ok, %{status: 204}} -> :ok
      {:ok, %{status: 404}} -> :ok
      {:ok, %{body: body}} -> {:error, body}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Inspects a Docker container by ID.
  """
  def inspect_container(id) do
    case docker_req(:get, "/containers/#{id}/json") do
      {:ok, %{status: 200, body: body}} -> {:ok, body}
      {:ok, %{body: body}} -> {:error, body}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Runs a command inside a container and returns its output.

  This is a multi-step process:
  1. POST /containers/{id}/exec to create the exec instance
  2. POST /exec/{id}/start to run it (non-interactive, returns multiplexed stream)
  3. GET /exec/{id}/json to get the exit code
  """
  def exec_run(container_id, cmd, opts \\ []) do
    env = Keyword.get(opts, :env, [])
    working_dir = Keyword.get(opts, :working_dir)
    user = Keyword.get(opts, :user)

    exec_config =
      %{
        "Cmd" => cmd,
        "AttachStdout" => true,
        "AttachStderr" => true,
        "Env" => env
      }
      |> then(fn config ->
        if working_dir, do: Map.put(config, "WorkingDir", working_dir), else: config
      end)
      |> then(fn config ->
        if user, do: Map.put(config, "User", user), else: config
      end)

    with {:ok, %{status: 201, body: %{"Id" => exec_id}}} <-
           docker_req(:post, "/containers/#{container_id}/exec", json: exec_config),
         {:ok, %{status: 200, body: raw_output}} <-
           docker_req(:post, "/exec/#{exec_id}/start",
             json: %{"Detach" => false, "Tty" => false},
             raw: true
           ),
         {:ok, %{status: 200, body: %{"ExitCode" => exit_code}}} <-
           docker_req(:get, "/exec/#{exec_id}/json") do
      output = demux_docker_stream(raw_output)
      {:ok, %{exit_code: exit_code, output: output}}
    else
      {:ok, %{body: body}} -> {:error, body}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Uploads a tar archive to a container at the given path.
  """
  def put_archive(container_id, path, tar_binary) do
    case docker_req(:put, "/containers/#{container_id}/archive",
           params: [path: path],
           body: tar_binary,
           headers: [{"content-type", "application/x-tar"}]
         ) do
      {:ok, %{status: 200}} -> :ok
      {:ok, %{body: body}} -> {:error, body}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Creates a Docker network.
  """
  def create_network(name) do
    config = %{"Name" => name, "Driver" => "bridge"}

    case docker_req(:post, "/networks/create", json: config) do
      {:ok, %{status: 201, body: %{"Id" => id}}} -> {:ok, id}
      {:ok, %{body: body}} -> {:error, body}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Connects a container to a network with optional aliases.
  """
  def connect_network(network_id, container_id, opts \\ []) do
    aliases = Keyword.get(opts, :aliases, [])

    config = %{
      "Container" => container_id,
      "EndpointConfig" => %{"Aliases" => aliases}
    }

    case docker_req(:post, "/networks/#{network_id}/connect", json: config) do
      {:ok, %{status: 200}} -> :ok
      {:ok, %{body: body}} -> {:error, body}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Removes a Docker network.
  """
  def remove_network(network_id) do
    case docker_req(:delete, "/networks/#{network_id}") do
      {:ok, %{status: 204}} -> :ok
      {:ok, %{status: 404}} -> :ok
      {:ok, %{body: body}} -> {:error, body}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Creates a Docker volume with the given name.
  """
  def create_volume(name) do
    case docker_req(:post, "/volumes/create", json: %{"Name" => name}) do
      {:ok, %{status: 201}} -> {:ok, name}
      {:ok, %{body: body}} -> {:error, body}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Removes a Docker volume by name.
  """
  def remove_volume(name) do
    case docker_req(:delete, "/volumes/#{name}") do
      {:ok, %{status: 204}} -> :ok
      {:ok, %{status: 404}} -> :ok
      {:ok, %{body: body}} -> {:error, body}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Runs a command inside a container, streaming output chunks to a callback.

  Similar to `exec_run/3`, but instead of collecting all output, it opens a raw
  TCP streaming connection and calls `callback.(chunk)` for each output chunk.

  Returns `{:ok, exit_code}` or `{:error, reason}`.
  """
  def exec_stream(container_id, cmd, callback, opts \\ []) do
    working_dir = Keyword.get(opts, :working_dir)
    user = Keyword.get(opts, :user)

    exec_config =
      %{
        "Cmd" => cmd,
        "AttachStdout" => true,
        "AttachStderr" => true,
        "Tty" => true
      }
      |> then(fn config ->
        if working_dir, do: Map.put(config, "WorkingDir", working_dir), else: config
      end)
      |> then(fn config ->
        if user, do: Map.put(config, "User", user), else: config
      end)

    with {:ok, %{status: 201, body: %{"Id" => exec_id}}} <-
           docker_req(:post, "/containers/#{container_id}/exec", json: exec_config),
         {:ok, socket, initial_data} <- open_stream_socket(exec_id),
         :ok <- stream_output(socket, initial_data, callback),
         {:ok, %{status: 200, body: %{"ExitCode" => exit_code}}} <-
           docker_req(:get, "/exec/#{exec_id}/json") do
      {:ok, exit_code}
    else
      {:ok, %{body: body}} -> {:error, body}
      {:error, reason} -> {:error, reason}
    end
  end

  defp open_stream_socket(exec_id) do
    socket_path =
      Application.get_env(:autoforge, __MODULE__, [])[:socket_path] || "/var/run/docker.sock"

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

        case read_stream_http_response(socket) do
          {:ok, status, initial_data} when status in [101, 200] ->
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

  defp stream_output(socket, initial_data, callback) do
    if initial_data != "", do: callback.(initial_data)
    stream_recv_loop(socket, callback)
  end

  defp stream_recv_loop(socket, callback) do
    case :gen_tcp.recv(socket, 0, 300_000) do
      {:ok, data} ->
        callback.(data)
        stream_recv_loop(socket, callback)

      {:error, :closed} ->
        :gen_tcp.close(socket)
        :ok

      {:error, reason} ->
        :gen_tcp.close(socket)
        {:error, reason}
    end
  end

  defp read_stream_http_response(socket, buffer \\ <<>>) do
    case :gen_tcp.recv(socket, 0, 10_000) do
      {:ok, data} ->
        buffer = buffer <> data

        case :binary.split(buffer, "\r\n\r\n") do
          [headers, rest] ->
            case parse_stream_status(headers) do
              {:ok, status} -> {:ok, status, rest}
              :error -> {:error, :invalid_response}
            end

          [_incomplete] ->
            read_stream_http_response(socket, buffer)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_stream_status(headers) do
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

  # Private helpers

  defp docker_req(method, path, opts \\ []) do
    socket_path =
      Application.get_env(:autoforge, __MODULE__, [])[:socket_path] || "/var/run/docker.sock"

    {json_opt, opts} = Keyword.pop(opts, :json)
    {body_opt, opts} = Keyword.pop(opts, :body)
    {headers_opt, opts} = Keyword.pop(opts, :headers, [])
    {raw, opts} = Keyword.pop(opts, :raw, false)

    req_opts =
      [
        unix_socket: socket_path,
        base_url: "http://localhost/v1.45",
        url: path,
        method: method,
        headers: headers_opt
      ] ++ opts

    req_opts =
      cond do
        json_opt -> Keyword.put(req_opts, :json, json_opt)
        body_opt -> Keyword.put(req_opts, :body, body_opt)
        true -> req_opts
      end

    req_opts =
      if raw do
        Keyword.put(req_opts, :decode_body, false)
      else
        req_opts
      end

    Req.request(req_opts)
  end

  @doc false
  def demux_docker_stream(data) when is_binary(data) do
    demux_frames(data, [])
  end

  def demux_docker_stream(_), do: ""

  defp demux_frames(
         <<_type::8, 0, 0, 0, size::big-32, payload::binary-size(size), rest::binary>>,
         acc
       ) do
    demux_frames(rest, [acc, payload])
  end

  defp demux_frames(<<>>, acc), do: IO.iodata_to_binary(acc)
  defp demux_frames(_other, acc), do: IO.iodata_to_binary(acc)
end
