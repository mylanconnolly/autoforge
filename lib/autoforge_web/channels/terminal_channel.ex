defmodule AutoforgeWeb.TerminalChannel do
  use AutoforgeWeb, :channel

  alias Autoforge.Projects.{Project, Terminal}

  require Ash.Query

  @impl true
  def join("terminal:" <> project_id, payload, socket) do
    user_id = socket.assigns.user_id
    session_name = Map.get(payload, "session_name", "term-1")

    user =
      Autoforge.Accounts.User
      |> Ash.Query.filter(id == ^user_id)
      |> Ash.read_one!(authorize?: false)

    project =
      Project
      |> Ash.Query.filter(id == ^project_id)
      |> Ash.read_one!(actor: user)

    cond do
      is_nil(project) ->
        {:error, %{reason: "not_found"}}

      project.state != :running ->
        {:error, %{reason: "not_running"}}

      true ->
        {:ok, terminal_pid} =
          Terminal.start_link(
            project: project,
            user: user,
            channel_pid: self(),
            session_name: session_name
          )

        {:ok, socket |> assign(:terminal_pid, terminal_pid) |> assign(:utf8_buffer, "")}
    end
  end

  @impl true
  def handle_in("input", %{"data" => data}, socket) do
    Terminal.send_input(socket.assigns.terminal_pid, data)
    {:noreply, socket}
  end

  def handle_in("resize", %{"cols" => cols, "rows" => rows}, socket) do
    Terminal.resize(socket.assigns.terminal_pid, cols, rows)
    {:noreply, socket}
  end

  @impl true
  def handle_info({:terminal_output, data}, socket) do
    combined = socket.assigns.utf8_buffer <> data

    case :unicode.characters_to_binary(combined) do
      valid when is_binary(valid) ->
        push(socket, "output", %{data: valid})
        {:noreply, assign(socket, :utf8_buffer, "")}

      {:incomplete, valid, rest} ->
        if byte_size(valid) > 0, do: push(socket, "output", %{data: valid})
        {:noreply, assign(socket, :utf8_buffer, IO.iodata_to_binary(rest))}

      {:error, valid, _bad} ->
        if byte_size(valid) > 0, do: push(socket, "output", %{data: valid})
        {:noreply, assign(socket, :utf8_buffer, "")}
    end
  end

  def handle_info(:terminal_closed, socket) do
    push(socket, "output", %{data: "\r\n\x1b[31mTerminal session ended.\x1b[0m\r\n"})
    {:stop, :normal, socket}
  end

  @impl true
  def terminate(_reason, socket) do
    if socket.assigns[:terminal_pid] && Process.alive?(socket.assigns.terminal_pid) do
      GenServer.stop(socket.assigns.terminal_pid)
    end

    :ok
  end
end
