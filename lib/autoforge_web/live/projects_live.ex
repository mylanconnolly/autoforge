defmodule AutoforgeWeb.ProjectsLive do
  use AutoforgeWeb, :live_view

  alias Autoforge.Projects.Project

  require Ash.Query

  on_mount {AutoforgeWeb.LiveUserAuth, :live_user_required}

  @limit 20

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Autoforge.PubSub, "project:updated")
    end

    {:ok, assign(socket, page_title: "Projects", query: "", sort: nil)}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, load_page(socket, params)}
  end

  @impl true
  def handle_info(
        %Phoenix.Socket.Broadcast{payload: %Ash.Notifier.Notification{}},
        socket
      ) do
    params = build_params(socket)
    {:noreply, load_page(socket, params)}
  end

  @impl true
  def handle_event("search", %{"q" => query}, socket) do
    params = if query == "", do: %{}, else: %{"q" => query}

    params =
      if socket.assigns.sort, do: Map.put(params, "sort", socket.assigns.sort), else: params

    {:noreply, push_patch(socket, to: ~p"/projects?#{params}")}
  end

  def handle_event("sort", %{"column" => column}, socket) do
    sort = next_sort(column, socket.assigns.sort)
    params = %{}

    params =
      if socket.assigns.query != "", do: Map.put(params, "q", socket.assigns.query), else: params

    params = if sort, do: Map.put(params, "sort", sort), else: params
    {:noreply, push_patch(socket, to: ~p"/projects?#{params}")}
  end

  def handle_event("paginate", %{"direction" => dir}, socket) do
    page = socket.assigns.page

    new_offset =
      case dir do
        "next" -> (page.offset || 0) + page.limit
        "prev" -> max((page.offset || 0) - page.limit, 0)
      end

    params = %{"offset" => to_string(new_offset)}

    params =
      if socket.assigns.query != "", do: Map.put(params, "q", socket.assigns.query), else: params

    params =
      if socket.assigns.sort, do: Map.put(params, "sort", socket.assigns.sort), else: params

    {:noreply, push_patch(socket, to: ~p"/projects?#{params}")}
  end

  def handle_event("stop", %{"id" => id}, socket) do
    project = find_project(socket, id)

    if project do
      Task.Supervisor.start_child(Autoforge.TaskSupervisor, fn ->
        Autoforge.Projects.Sandbox.stop(project)
      end)
    end

    {:noreply, socket}
  end

  def handle_event("start", %{"id" => id}, socket) do
    project = find_project(socket, id)

    if project do
      Task.Supervisor.start_child(Autoforge.TaskSupervisor, fn ->
        Autoforge.Projects.Sandbox.start(project)
      end)
    end

    {:noreply, socket}
  end

  def handle_event("destroy", %{"id" => id}, socket) do
    project = find_project(socket, id)

    if project do
      Task.Supervisor.start_child(Autoforge.TaskSupervisor, fn ->
        Autoforge.Projects.Sandbox.destroy(project)
      end)
    end

    {:noreply, socket}
  end

  defp load_page(socket, params) do
    query = params["q"] || ""
    sort = params["sort"]

    page_opts =
      AshPhoenix.LiveView.params_to_page_opts(params, default_limit: @limit, count?: true)

    args = %{query: query}
    args = if sort, do: Map.put(args, :sort, sort), else: args

    page =
      Project
      |> Ash.Query.for_read(:search, args)
      |> Ash.Query.load(:project_template)
      |> Ash.read!(actor: socket.assigns.current_user, page: page_opts)

    assign(socket, page: page, query: query, sort: sort)
  end

  defp build_params(socket) do
    params = %{}

    params =
      if socket.assigns.query != "", do: Map.put(params, "q", socket.assigns.query), else: params

    offset = socket.assigns.page.offset || 0
    params = if offset > 0, do: Map.put(params, "offset", to_string(offset)), else: params
    if socket.assigns.sort, do: Map.put(params, "sort", socket.assigns.sort), else: params
  end

  defp find_project(socket, id) do
    Enum.find(socket.assigns.page.results, &(&1.id == id))
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

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user} active_page={:projects}>
      <div>
        <div class="flex items-center justify-between mb-6">
          <div>
            <h1 class="text-2xl font-bold tracking-tight">Projects</h1>
            <p class="mt-2 text-base-content/70">
              Manage your sandbox projects.
            </p>
          </div>
          <.link navigate={~p"/projects/new"}>
            <.button variant="solid" color="primary">
              <.icon name="hero-plus" class="w-4 h-4 mr-1" /> New Project
            </.button>
          </.link>
        </div>

        <div class="mb-4">
          <.search_bar query={@query} placeholder="Search projects..." />
        </div>

        <%= if @page.results == [] do %>
          <div class="card bg-base-200">
            <div class="card-body items-center text-center py-12">
              <.icon name="hero-cube-transparent" class="w-10 h-10 text-base-content/30 mb-2" />
              <p class="text-lg font-medium text-base-content/70">No projects yet</p>
              <p class="text-sm text-base-content/50 mt-1">
                Create your first project to get started.
              </p>
              <.link navigate={~p"/projects/new"} class="mt-4">
                <.button variant="solid" color="primary" size="sm">
                  <.icon name="hero-plus" class="w-4 h-4 mr-1" /> Create Project
                </.button>
              </.link>
            </div>
          </div>
        <% else %>
          <.table>
            <.table_head>
              <:col>
                <.sort_header column="name" sort={@sort}>Name</.sort_header>
              </:col>
              <:col>Template</:col>
              <:col>
                <.sort_header column="state" sort={@sort}>Status</.sort_header>
              </:col>
              <:col>
                <.sort_header column="last_activity_at" sort={@sort}>Last Activity</.sort_header>
              </:col>
              <:col></:col>
            </.table_head>
            <.table_body>
              <.table_row :for={project <- @page.results}>
                <:cell>
                  <.link navigate={~p"/projects/#{project.id}"} class="font-medium hover:underline">
                    {project.name}
                  </.link>
                </:cell>
                <:cell>
                  <span class="text-sm text-base-content/70">
                    {project.project_template && project.project_template.name}
                  </span>
                </:cell>
                <:cell>
                  <span class={"badge badge-sm #{state_badge_class(project.state)}"}>
                    {project.state}
                  </span>
                </:cell>
                <:cell class="text-base-content/70 text-sm">
                  <%= if project.last_activity_at do %>
                    <.local_time value={project.last_activity_at} user={@current_user} />
                  <% else %>
                    —
                  <% end %>
                </:cell>
                <:cell>
                  <.dropdown placement="bottom-end">
                    <:toggle>
                      <button class="p-1 rounded-lg hover:bg-base-300 transition-colors">
                        <.icon name="hero-ellipsis-horizontal" class="w-5 h-5" />
                      </button>
                    </:toggle>
                    <.dropdown_link navigate={~p"/projects/#{project.id}"}>
                      <.icon name="hero-eye" class="w-4 h-4 mr-2" /> Open
                    </.dropdown_link>
                    <.dropdown_button
                      :if={project.state == :stopped}
                      phx-click="start"
                      phx-value-id={project.id}
                    >
                      <.icon name="hero-play" class="w-4 h-4 mr-2" /> Start
                    </.dropdown_button>
                    <.dropdown_button
                      :if={project.state == :running}
                      phx-click="stop"
                      phx-value-id={project.id}
                    >
                      <.icon name="hero-stop" class="w-4 h-4 mr-2" /> Stop
                    </.dropdown_button>
                    <.dropdown_separator />
                    <.dropdown_button
                      :if={project.state in [:running, :stopped, :error]}
                      phx-click="destroy"
                      phx-value-id={project.id}
                      data-confirm="Are you sure you want to destroy this project? This cannot be undone."
                      class="text-error"
                    >
                      <.icon name="hero-trash" class="w-4 h-4 mr-2" /> Destroy
                    </.dropdown_button>
                  </.dropdown>
                </:cell>
              </.table_row>
            </.table_body>
          </.table>

          <.pagination page={@page} />
        <% end %>
      </div>
    </Layouts.app>
    """
  end
end
