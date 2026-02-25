defmodule AutoforgeWeb.ProjectLive do
  use AutoforgeWeb, :live_view

  alias Autoforge.Projects.{CodeServer, DevServer, Project, Sandbox}

  require Ash.Query

  on_mount {AutoforgeWeb.LiveUserAuth, :live_user_required}

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    user = socket.assigns.current_user

    project =
      Project
      |> Ash.Query.filter(id == ^id)
      |> Ash.Query.load(:project_template)
      |> Ash.read_one!(actor: user)

    if project do
      if connected?(socket) do
        Phoenix.PubSub.subscribe(Autoforge.PubSub, "project:updated:#{project.id}")
        Phoenix.PubSub.subscribe(Autoforge.PubSub, "project:provision_log:#{project.id}")
        Phoenix.PubSub.subscribe(Autoforge.PubSub, "project:dev_server:#{project.id}")
        Phoenix.PubSub.subscribe(Autoforge.PubSub, "project:code_server:#{project.id}")
      end

      token = Phoenix.Token.sign(AutoforgeWeb.Endpoint, "user_socket", user.id)

      dev_server_running = DevServer.running?(project.id)
      code_server_running = CodeServer.running?(project.id)

      terminals =
        if project.state == :running,
          do: [%{id: "term-1", label: "Terminal 1"}],
          else: []

      {:ok,
       assign(socket,
         page_title: project.name,
         project: project,
         user_token: token,
         provision_log_started: false,
         terminals: terminals,
         active_terminal: if(terminals != [], do: "term-1"),
         terminal_counter: length(terminals),
         dev_server_running: dev_server_running,
         dev_server_tab_open: dev_server_running,
         code_server_running: code_server_running,
         code_server_ready: code_server_running && CodeServer.ready?(project.id),
         code_server_tab_open: code_server_running
       )}
    else
      {:ok,
       socket
       |> put_flash(:error, "Project not found.")
       |> push_navigate(to: ~p"/projects")}
    end
  end

  @impl true
  def handle_info(
        %Phoenix.Socket.Broadcast{payload: %Ash.Notifier.Notification{data: updated_project}},
        socket
      ) do
    project =
      Project
      |> Ash.Query.filter(id == ^updated_project.id)
      |> Ash.Query.load(:project_template)
      |> Ash.read_one!(authorize?: false)

    was_running = socket.assigns.project.state == :running
    now_running = project.state == :running

    socket = assign(socket, project: project)

    socket =
      if not was_running and now_running and socket.assigns.terminals == [] do
        tab = %{id: "term-1", label: "Terminal 1"}
        assign(socket, terminals: [tab], active_terminal: "term-1", terminal_counter: 1)
      else
        socket
      end

    {:noreply, socket}
  end

  def handle_info({:provision_log, {:output, chunk}}, socket) do
    {:noreply,
     socket
     |> assign(provision_log_started: true)
     |> push_event("provision_log", %{type: "output", data: chunk})}
  end

  def handle_info({:provision_log, message}, socket) do
    {:noreply,
     socket
     |> assign(provision_log_started: true)
     |> push_event("provision_log", %{type: "step", data: message})}
  end

  def handle_info({:dev_server_output, chunk}, socket) do
    {:noreply, push_event(socket, "dev_server_output", %{type: "output", data: chunk})}
  end

  def handle_info({:dev_server_stopped, _reason}, socket) do
    {:noreply, assign(socket, dev_server_running: false)}
  end

  def handle_info({:code_server_started}, socket) do
    {:noreply, assign(socket, code_server_ready: true)}
  end

  def handle_info({:code_server_output, _chunk}, socket) do
    {:noreply, socket}
  end

  def handle_info({:code_server_stopped, _reason}, socket) do
    {:noreply, assign(socket, code_server_running: false, code_server_ready: false)}
  end

  @impl true
  def handle_event("new_terminal", _params, socket) do
    counter = socket.assigns.terminal_counter + 1
    id = "term-#{counter}"
    tab = %{id: id, label: "Terminal #{counter}"}

    {:noreply,
     assign(socket,
       terminals: socket.assigns.terminals ++ [tab],
       active_terminal: id,
       terminal_counter: counter
     )}
  end

  def handle_event("switch_terminal", %{"id" => id}, socket) do
    {:noreply, assign(socket, active_terminal: id)}
  end

  def handle_event("close_terminal", %{"id" => id}, socket) do
    terminals = Enum.reject(socket.assigns.terminals, &(&1.id == id))

    active =
      if socket.assigns.active_terminal == id do
        case terminals do
          [] -> nil
          [first | _] -> first.id
        end
      else
        socket.assigns.active_terminal
      end

    {:noreply, assign(socket, terminals: terminals, active_terminal: active)}
  end

  def handle_event("start", _params, socket) do
    project = socket.assigns.project

    Task.Supervisor.start_child(Autoforge.TaskSupervisor, fn ->
      Sandbox.start(project)
    end)

    {:noreply, put_flash(socket, :info, "Starting project...")}
  end

  def handle_event("stop", _params, socket) do
    project = socket.assigns.project

    Task.Supervisor.start_child(Autoforge.TaskSupervisor, fn ->
      Sandbox.stop(project)
    end)

    {:noreply, put_flash(socket, :info, "Stopping project...")}
  end

  def handle_event("destroy", _params, socket) do
    project = socket.assigns.project

    Task.Supervisor.start_child(Autoforge.TaskSupervisor, fn ->
      Sandbox.destroy(project)
    end)

    {:noreply,
     socket
     |> put_flash(:info, "Destroying project...")
     |> push_navigate(to: ~p"/projects")}
  end

  def handle_event("start_dev_server", _params, socket) do
    project = socket.assigns.project

    case DynamicSupervisor.start_child(
           Autoforge.Projects.DevServerSupervisor,
           {DevServer, project}
         ) do
      {:ok, _pid} ->
        {:noreply,
         assign(socket,
           dev_server_running: true,
           dev_server_tab_open: true,
           active_terminal: "dev-server"
         )}

      {:error, {:already_started, _pid}} ->
        {:noreply,
         assign(socket,
           dev_server_running: true,
           dev_server_tab_open: true,
           active_terminal: "dev-server"
         )}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to start dev server: #{inspect(reason)}")}
    end
  end

  def handle_event("stop_dev_server", _params, socket) do
    DevServer.stop(socket.assigns.project.id)
    {:noreply, assign(socket, dev_server_running: false)}
  end

  def handle_event("start_code_server", _params, socket) do
    project = socket.assigns.project

    if is_nil(project.code_server_port) do
      {:noreply,
       put_flash(
         socket,
         :error,
         "Editor requires reprovisioning. Please stop and destroy this project, then recreate it."
       )}
    else
      case DynamicSupervisor.start_child(
             Autoforge.Projects.CodeServerSupervisor,
             {CodeServer, project}
           ) do
        {:ok, _pid} ->
          {:noreply,
           assign(socket,
             code_server_running: true,
             code_server_tab_open: true,
             active_terminal: "code-server"
           )}

        {:error, {:already_started, _pid}} ->
          {:noreply,
           assign(socket,
             code_server_running: true,
             code_server_tab_open: true,
             active_terminal: "code-server"
           )}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Failed to start code-server: #{inspect(reason)}")}
      end
    end
  end

  def handle_event("stop_code_server", _params, socket) do
    CodeServer.stop(socket.assigns.project.id)
    {:noreply, assign(socket, code_server_running: false, code_server_ready: false)}
  end

  defp state_badge_class(state) do
    case state do
      :creating -> "badge-info"
      :provisioning -> "badge-info"
      :running -> "badge-success"
      :stopped -> "badge-warning"
      :error -> "badge-error"
      :destroying -> "badge-warning"
      :destroyed -> "badge-neutral"
      _ -> "badge-neutral"
    end
  end

  defp state_animating?(state) do
    state in [:creating, :provisioning, :destroying]
  end

  defp has_dev_server_script?(%{project_template: %{dev_server_script: script}})
       when is_binary(script) and script != "",
       do: true

  defp has_dev_server_script?(_), do: false

  defp project_url(%{tailscale_hostname: hostname}) when is_binary(hostname) do
    case Autoforge.Projects.Tailscale.get_tailnet_name() do
      {:ok, tailnet} -> "https://#{hostname}.#{tailnet}"
      :disabled -> nil
    end
  end

  defp project_url(%{host_port: port}) when is_integer(port) do
    "http://localhost:#{port}"
  end

  defp project_url(_), do: nil

  defp code_server_url(%{tailscale_hostname: hostname, code_server_port: _} = project)
       when is_binary(hostname) do
    case Autoforge.Projects.Tailscale.get_tailnet_name() do
      {:ok, tailnet} -> "https://#{hostname}.#{tailnet}:8443/?folder=/app"
      :disabled -> "http://localhost:#{project.code_server_port}/?folder=/app"
    end
  end

  defp code_server_url(%{code_server_port: port}) when is_integer(port) do
    "http://localhost:#{port}/?folder=/app"
  end

  defp code_server_url(_), do: nil

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      active_page={:projects}
      full_width
    >
      <div class="flex flex-col h-full">
        <%!-- Header Bar --%>
        <div class="flex items-center gap-4 px-4 py-3 border-b border-base-300 bg-base-100 flex-shrink-0">
          <.link
            navigate={~p"/projects"}
            class="text-base-content/50 hover:text-base-content transition-colors"
          >
            <.icon name="hero-arrow-left" class="w-5 h-5" />
          </.link>

          <div class="flex items-center gap-3 min-w-0">
            <h1 class="text-lg font-semibold tracking-tight truncate">{@project.name}</h1>
            <span class={"badge badge-sm #{state_badge_class(@project.state)}"}>
              <span
                :if={state_animating?(@project.state)}
                class="loading loading-spinner loading-xs mr-1"
              />
              {@project.state}
            </span>
          </div>

          <div class="flex items-center gap-3 text-sm text-base-content/50 ml-auto flex-shrink-0">
            <.link
              :if={@project.github_repo_owner && @project.github_repo_name}
              href={"https://github.com/#{@project.github_repo_owner}/#{@project.github_repo_name}"}
              target="_blank"
              class="inline-flex items-center gap-1 text-base-content/50 hover:text-primary transition-colors"
            >
              <.icon name="hero-code-bracket" class="w-4 h-4" />
              <span class="text-xs">{@project.github_repo_owner}/{@project.github_repo_name}</span>
            </.link>
            <span :if={@project.project_template}>
              {@project.project_template.name}
            </span>
            <span :if={@project.container_id} class="font-mono text-xs">
              {String.slice(@project.container_id, 0..11)}
            </span>
          </div>

          <div class="flex items-center gap-1.5 flex-shrink-0">
            <.dropdown placement="bottom-end" class="w-52">
              <:toggle>
                <.button variant="outline" size="xs">
                  <.icon name="hero-ellipsis-vertical" class="w-4 h-4" />
                </.button>
              </:toggle>

              <.dropdown_link navigate={~p"/projects/#{@project.id}/settings"}>
                <.icon name="hero-cog-6-tooth" class="icon w-4 h-4" /> Settings
              </.dropdown_link>

              <.dropdown_separator :if={
                @project.state == :running && has_dev_server_script?(@project)
              } />

              <.dropdown_button
                :if={
                  @project.state == :running && !@dev_server_running &&
                    has_dev_server_script?(@project)
                }
                phx-click="start_dev_server"
              >
                <.icon name="hero-globe-alt" class="icon w-4 h-4" /> Start Server
              </.dropdown_button>

              <.dropdown_button
                :if={@project.state == :running && @dev_server_running}
                phx-click="stop_dev_server"
              >
                <.icon name="hero-globe-alt" class="icon w-4 h-4" /> Stop Server
              </.dropdown_button>

              <.dropdown_link
                :if={@dev_server_running && (@project.tailscale_hostname || @project.host_port)}
                href={project_url(@project)}
                target="_blank"
              >
                <.icon name="hero-arrow-top-right-on-square" class="icon w-4 h-4" /> Open in Browser
              </.dropdown_link>

              <.dropdown_separator :if={@project.state == :running} />

              <.dropdown_button
                :if={@project.state == :running && !@code_server_running}
                phx-click="start_code_server"
              >
                <.icon name="hero-code-bracket-square" class="icon w-4 h-4" /> Open Editor
              </.dropdown_button>

              <.dropdown_button
                :if={@project.state == :running && @code_server_running}
                phx-click="stop_code_server"
              >
                <.icon name="hero-code-bracket-square" class="icon w-4 h-4" /> Stop Editor
              </.dropdown_button>

              <.dropdown_separator :if={
                @project.state == :running && has_dev_server_script?(@project)
              } />

              <.dropdown_button :if={@project.state == :stopped} phx-click="start">
                <.icon name="hero-play" class="icon w-4 h-4" /> Start
              </.dropdown_button>

              <.dropdown_button :if={@project.state == :running} phx-click="stop">
                <.icon name="hero-stop" class="icon w-4 h-4" /> Stop
              </.dropdown_button>

              <.dropdown_separator :if={@project.state in [:running, :stopped, :error]} />

              <.dropdown_button
                :if={@project.state in [:running, :stopped, :error]}
                phx-click="destroy"
                data-confirm="Are you sure? This will permanently destroy the project and its containers."
                class="text-red-500"
              >
                <.icon name="hero-trash" class="icon w-4 h-4" /> Destroy
              </.dropdown_button>
            </.dropdown>
          </div>
        </div>

        <%!-- Error Banner --%>
        <div
          :if={@project.state == :error && @project.error_message}
          class="px-4 py-2 bg-error/10 border-b border-error/30 flex items-center gap-2 flex-shrink-0"
        >
          <.icon name="hero-exclamation-triangle" class="w-4 h-4 text-error flex-shrink-0" />
          <p class="text-sm text-error font-mono truncate">{@project.error_message}</p>
        </div>

        <%!-- Main Content Area --%>
        <div class="flex-1 min-h-0 relative">
          <%!-- Provision Log --%>
          <div
            :if={@provision_log_started and @project.state in [:creating, :provisioning, :error]}
            class="h-full flex flex-col bg-[#1c1917]"
          >
            <div class="px-4 py-2 border-b border-stone-800 flex items-center gap-2 flex-shrink-0">
              <span
                :if={@project.state in [:creating, :provisioning]}
                class="loading loading-spinner loading-xs text-amber-400"
              />
              <.icon
                :if={@project.state == :error}
                name="hero-exclamation-triangle"
                class="w-4 h-4 text-error"
              />
              <span class="text-sm font-medium text-stone-300">Provisioning Log</span>
            </div>
            <div
              id="provision-log"
              phx-hook="ProvisionLog"
              phx-update="ignore"
              class="flex-1 min-h-0"
            />
          </div>

          <%!-- Terminal Tabs --%>
          <div :if={@project.state == :running} class="h-full flex flex-col">
            <%!-- Tab Bar --%>
            <div class="flex items-center bg-[#0c0a09] flex-shrink-0 overflow-x-auto">
              <%!-- Server Tab --%>
              <button
                :if={@dev_server_tab_open}
                phx-click="switch_terminal"
                phx-value-id="dev-server"
                class={[
                  "group flex items-center gap-1.5 px-4 py-2 text-sm transition-colors cursor-pointer",
                  if("dev-server" == @active_terminal,
                    do: "bg-[#1c1917] text-stone-100 border-b-2 border-b-amber-500",
                    else:
                      "bg-[#0c0a09] text-stone-500 hover:text-stone-300 hover:bg-stone-800/50 border-b-2 border-b-transparent"
                  )
                ]}
              >
                <.icon name="hero-globe-alt" class="w-3.5 h-3.5" />
                <span>Server</span>
                <span
                  :if={@dev_server_running}
                  class="w-2 h-2 rounded-full bg-green-400 ml-1"
                />
              </button>
              <%!-- Editor Tab --%>
              <button
                :if={@code_server_tab_open}
                phx-click="switch_terminal"
                phx-value-id="code-server"
                class={[
                  "group flex items-center gap-1.5 px-4 py-2 text-sm transition-colors cursor-pointer",
                  if("code-server" == @active_terminal,
                    do: "bg-[#1c1917] text-stone-100 border-b-2 border-b-amber-500",
                    else:
                      "bg-[#0c0a09] text-stone-500 hover:text-stone-300 hover:bg-stone-800/50 border-b-2 border-b-transparent"
                  )
                ]}
              >
                <.icon name="hero-code-bracket-square" class="w-3.5 h-3.5" />
                <span>Editor</span>
                <span
                  :if={@code_server_running && !@code_server_ready}
                  class="loading loading-spinner loading-xs ml-1"
                />
                <span
                  :if={@code_server_ready}
                  class="w-2 h-2 rounded-full bg-green-400 ml-1"
                />
              </button>
              <%!-- Terminal Tabs --%>
              <button
                :for={tab <- @terminals}
                phx-click="switch_terminal"
                phx-value-id={tab.id}
                class={[
                  "group flex items-center gap-1.5 px-4 py-2 text-sm transition-colors cursor-pointer",
                  if(tab.id == @active_terminal,
                    do: "bg-[#1c1917] text-stone-100 border-b-2 border-b-amber-500",
                    else:
                      "bg-[#0c0a09] text-stone-500 hover:text-stone-300 hover:bg-stone-800/50 border-b-2 border-b-transparent"
                  )
                ]}
              >
                <.icon name="hero-command-line" class="w-3.5 h-3.5" />
                <span>{tab.label}</span>
                <span
                  phx-click="close_terminal"
                  phx-value-id={tab.id}
                  data-confirm="Close this terminal session?"
                  class={[
                    "ml-1 rounded p-0.5 transition-colors",
                    if(tab.id == @active_terminal,
                      do: "text-stone-500 hover:text-stone-200 hover:bg-stone-700",
                      else:
                        "text-stone-600 hover:text-stone-300 hover:bg-stone-600 opacity-0 group-hover:opacity-100"
                    )
                  ]}
                >
                  <.icon name="hero-x-mark" class="w-3.5 h-3.5" />
                </span>
              </button>
              <button
                phx-click="new_terminal"
                class="flex items-center px-3 py-2 text-stone-600 hover:text-stone-400 transition-colors cursor-pointer"
                title="New terminal"
              >
                <.icon name="hero-plus" class="w-4 h-4" />
              </button>
            </div>
            <%!-- Tab Panels --%>
            <div class="flex-1 min-h-0 relative">
              <%!-- Dev Server Panel --%>
              <div
                :if={@dev_server_tab_open}
                id="terminal-panel-dev-server"
                class={[
                  "absolute inset-0",
                  if("dev-server" != @active_terminal, do: "invisible")
                ]}
              >
                <div
                  id="dev-server"
                  phx-hook="DevServer"
                  phx-update="ignore"
                  class="h-full"
                />
              </div>
              <%!-- Editor Panel --%>
              <div
                :if={@code_server_tab_open}
                id="terminal-panel-code-server"
                class={[
                  "absolute inset-0",
                  if("code-server" != @active_terminal, do: "invisible")
                ]}
              >
                <div
                  :if={!@code_server_ready}
                  class="h-full flex items-center justify-center text-base-content/30"
                >
                  <div class="text-center">
                    <span class="loading loading-spinner loading-lg mb-3" />
                    <p class="text-sm">Starting editor...</p>
                  </div>
                </div>
                <iframe
                  :if={@code_server_ready}
                  src={code_server_url(@project)}
                  class="w-full h-full border-0"
                  allow="clipboard-read; clipboard-write"
                />
              </div>
              <%!-- Terminal Panels --%>
              <div
                :for={tab <- @terminals}
                id={"terminal-panel-#{tab.id}"}
                class={[
                  "absolute inset-0",
                  if(tab.id != @active_terminal, do: "invisible")
                ]}
              >
                <div
                  id={tab.id}
                  phx-hook="Terminal"
                  phx-update="ignore"
                  data-project-id={@project.id}
                  data-user-token={@user_token}
                  class="h-full"
                />
              </div>
            </div>
          </div>

          <%!-- Idle State (stopped/creating without logs) --%>
          <div
            :if={
              @project.state in [:stopped, :destroyed, :destroying] or
                (@project.state in [:creating, :provisioning] and not @provision_log_started)
            }
            class="h-full flex items-center justify-center text-base-content/30"
          >
            <div class="text-center">
              <.icon name="hero-cube-transparent" class="w-12 h-12 mx-auto mb-3" />
              <p class="text-sm">
                <%= case @project.state do %>
                  <% :stopped -> %>
                    Project is stopped
                  <% :destroying -> %>
                    Destroying project...
                  <% :destroyed -> %>
                    Project has been destroyed
                  <% _ -> %>
                    Preparing project...
                <% end %>
              </p>
            </div>
          </div>

          <%!-- Files sidebar overlay --%>
          <.live_component
            :if={@project.state in [:running, :stopped, :error, :provisioning]}
            module={AutoforgeWeb.ProjectFilesComponent}
            id="project-files"
            project={@project}
            current_user={@current_user}
          />
        </div>
      </div>
    </Layouts.app>
    """
  end
end
