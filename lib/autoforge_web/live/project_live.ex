defmodule AutoforgeWeb.ProjectLive do
  use AutoforgeWeb, :live_view

  alias Autoforge.Projects.{Project, Sandbox}

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
      end

      token = Phoenix.Token.sign(AutoforgeWeb.Endpoint, "user_socket", user.id)

      {:ok,
       assign(socket,
         page_title: project.name,
         project: project,
         user_token: token,
         provision_log_started: false
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

    {:noreply, assign(socket, project: project)}
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

  @impl true
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

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user} active_page={:projects}>
      <div class="max-w-5xl mx-auto">
        <div class="mb-6">
          <.link
            navigate={~p"/projects"}
            class="text-sm text-base-content/60 hover:text-base-content transition-colors"
          >
            <.icon name="hero-arrow-left" class="w-4 h-4 inline-block mr-1" /> Back to Projects
          </.link>
          <div class="flex items-center gap-3 mt-2">
            <h1 class="text-2xl font-bold tracking-tight">{@project.name}</h1>
            <span class={"badge #{state_badge_class(@project.state)}"}>
              <span
                :if={state_animating?(@project.state)}
                class="loading loading-spinner loading-xs mr-1"
              />
              {@project.state}
            </span>
          </div>
        </div>

        <%!-- Action Buttons --%>
        <div class="flex items-center gap-2 mb-6">
          <.button
            :if={@project.state == :stopped}
            phx-click="start"
            variant="solid"
            color="primary"
            size="sm"
          >
            <.icon name="hero-play" class="w-4 h-4 mr-1" /> Start
          </.button>
          <.button
            :if={@project.state == :running}
            phx-click="stop"
            variant="outline"
            size="sm"
          >
            <.icon name="hero-stop" class="w-4 h-4 mr-1" /> Stop
          </.button>
          <.button
            :if={@project.state in [:running, :stopped, :error]}
            phx-click="destroy"
            data-confirm="Are you sure? This will permanently destroy the project and its containers."
            variant="ghost"
            size="sm"
            class="text-error"
          >
            <.icon name="hero-trash" class="w-4 h-4 mr-1" /> Destroy
          </.button>
        </div>

        <%!-- Error Panel --%>
        <div :if={@project.state == :error && @project.error_message} class="mb-6">
          <div class="card bg-error/10 border border-error/30">
            <div class="card-body py-3">
              <div class="flex items-start gap-2">
                <.icon
                  name="hero-exclamation-triangle"
                  class="w-5 h-5 text-error flex-shrink-0 mt-0.5"
                />
                <div>
                  <p class="font-medium text-error">Provisioning Error</p>
                  <p class="text-sm text-base-content/70 mt-1 font-mono whitespace-pre-wrap">
                    {@project.error_message}
                  </p>
                </div>
              </div>
            </div>
          </div>
        </div>

        <%!-- Provision Log Panel --%>
        <div
          :if={@provision_log_started and @project.state in [:creating, :provisioning, :error]}
          class="card bg-[#1c1917] shadow-sm mb-6 border border-base-300/30"
        >
          <div class="px-4 py-2 border-b border-stone-800 flex items-center gap-2">
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
            class="h-80"
          />
        </div>

        <%!-- Info Card --%>
        <div class="card bg-base-200 shadow-sm mb-6">
          <div class="card-body py-4">
            <div class="grid grid-cols-2 gap-4 text-sm">
              <div>
                <span class="text-base-content/50">Template</span>
                <p class="font-medium mt-0.5">
                  {if @project.project_template, do: @project.project_template.name, else: "—"}
                </p>
              </div>
              <div>
                <span class="text-base-content/50">Created</span>
                <p class="font-medium mt-0.5">
                  <.local_time value={@project.inserted_at} user={@current_user} />
                </p>
              </div>
              <div>
                <span class="text-base-content/50">Container ID</span>
                <p class="font-mono text-xs mt-0.5 truncate">
                  {String.slice(@project.container_id || "—", 0..11)}
                </p>
              </div>
              <div>
                <span class="text-base-content/50">Last Activity</span>
                <p class="font-medium mt-0.5">
                  <%= if @project.last_activity_at do %>
                    <.local_time value={@project.last_activity_at} user={@current_user} />
                  <% else %>
                    —
                  <% end %>
                </p>
              </div>
            </div>
          </div>
        </div>

        <%!-- Terminal Panel --%>
        <div :if={@project.state == :running} class="card bg-base-200 shadow-sm">
          <div class="card-body p-0">
            <div class="px-4 py-2 border-b border-base-300 flex items-center gap-2">
              <.icon name="hero-command-line" class="w-4 h-4 text-base-content/50" />
              <span class="text-sm font-medium">Terminal</span>
            </div>
            <div
              id="terminal"
              phx-hook="Terminal"
              phx-update="ignore"
              data-project-id={@project.id}
              data-user-token={@user_token}
              class="h-96"
            />
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
