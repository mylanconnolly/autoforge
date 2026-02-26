defmodule AutoforgeWeb.UserGroupsLive do
  use AutoforgeWeb, :live_view

  alias Autoforge.Accounts.UserGroup

  require Ash.Query

  on_mount {AutoforgeWeb.LiveUserAuth, :live_user_required}

  @limit 20

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "Groups", query: "", sort: nil)}
  end

  @impl true
  def handle_params(params, _url, socket) do
    query = params["q"] || ""
    sort = params["sort"]

    page_opts =
      AshPhoenix.LiveView.params_to_page_opts(params, default_limit: @limit, count?: true)

    args = %{query: query}
    args = if sort, do: Map.put(args, :sort, sort), else: args

    page =
      UserGroup
      |> Ash.Query.for_read(:search, args)
      |> Ash.Query.load([:members])
      |> Ash.read!(actor: socket.assigns.current_user, page: page_opts)

    {:noreply, assign(socket, page: page, query: query, sort: sort)}
  end

  @impl true
  def handle_event("search", %{"q" => query}, socket) do
    params = if query == "", do: %{}, else: %{"q" => query}

    params =
      if socket.assigns.sort, do: Map.put(params, "sort", socket.assigns.sort), else: params

    {:noreply, push_patch(socket, to: ~p"/user-groups?#{params}")}
  end

  def handle_event("sort", %{"column" => column}, socket) do
    sort = next_sort(column, socket.assigns.sort)
    params = %{}

    params =
      if socket.assigns.query != "", do: Map.put(params, "q", socket.assigns.query), else: params

    params = if sort, do: Map.put(params, "sort", sort), else: params
    {:noreply, push_patch(socket, to: ~p"/user-groups?#{params}")}
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

    {:noreply, push_patch(socket, to: ~p"/user-groups?#{params}")}
  end

  def handle_event("delete", %{"id" => id}, socket) do
    user = socket.assigns.current_user
    target = Enum.find(socket.assigns.page.results, &(&1.id == id))

    if target do
      Ash.destroy!(target, actor: user)
    end

    {:noreply,
     socket
     |> put_flash(:info, "Group deleted successfully.")
     |> push_patch(to: current_path(socket))}
  end

  defp current_path(socket) do
    params = %{}

    params =
      if socket.assigns.query != "", do: Map.put(params, "q", socket.assigns.query), else: params

    offset = socket.assigns.page.offset || 0
    params = if offset > 0, do: Map.put(params, "offset", to_string(offset)), else: params

    params =
      if socket.assigns.sort, do: Map.put(params, "sort", socket.assigns.sort), else: params

    ~p"/user-groups?#{params}"
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user} active_page={:user_groups}>
      <div>
        <div class="flex items-center justify-between mb-6">
          <div>
            <h1 class="text-2xl font-bold tracking-tight">Groups</h1>
            <p class="mt-2 text-base-content/70">
              Manage user groups for permissions and organization.
            </p>
          </div>
          <.link navigate={~p"/user-groups/new"}>
            <.button variant="solid" color="primary">
              <.icon name="hero-plus" class="w-4 h-4 mr-1" /> New Group
            </.button>
          </.link>
        </div>

        <div class="mb-4">
          <.search_bar query={@query} placeholder="Search groups..." />
        </div>

        <%= if @page.results == [] do %>
          <div class="card bg-base-200">
            <div class="card-body items-center text-center py-12">
              <.icon name="hero-user-group" class="w-10 h-10 text-base-content/30 mb-2" />
              <p class="text-lg font-medium text-base-content/70">No groups yet</p>
              <p class="text-sm text-base-content/50 mt-1">
                Create your first group to get started.
              </p>
              <.link navigate={~p"/user-groups/new"} class="mt-4">
                <.button variant="solid" color="primary" size="sm">
                  <.icon name="hero-plus" class="w-4 h-4 mr-1" /> Create Group
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
              <:col>
                <.sort_header column="description" sort={@sort}>Description</.sort_header>
              </:col>
              <:col>Members</:col>
              <:col></:col>
            </.table_head>
            <.table_body>
              <.table_row :for={group <- @page.results}>
                <:cell>
                  <.link navigate={~p"/user-groups/#{group.id}"} class="font-medium hover:underline">
                    {group.name}
                  </.link>
                </:cell>
                <:cell>
                  <span class="text-sm text-base-content/70">{group.description || "—"}</span>
                </:cell>
                <:cell>
                  <span class="badge badge-sm">{length(group.members)}</span>
                </:cell>
                <:cell>
                  <.dropdown placement="bottom-end">
                    <:toggle>
                      <button class="p-1 rounded-lg hover:bg-base-300 transition-colors">
                        <.icon name="hero-ellipsis-horizontal" class="w-5 h-5" />
                      </button>
                    </:toggle>
                    <.dropdown_link navigate={~p"/user-groups/#{group.id}"}>
                      <.icon name="hero-eye" class="w-4 h-4 mr-2" /> View
                    </.dropdown_link>
                    <.dropdown_link navigate={~p"/user-groups/#{group.id}/edit"}>
                      <.icon name="hero-pencil-square" class="w-4 h-4 mr-2" /> Edit
                    </.dropdown_link>
                    <.dropdown_separator />
                    <.dropdown_button
                      phx-click="delete"
                      phx-value-id={group.id}
                      data-confirm="Are you sure you want to delete this group?"
                      class="text-error"
                    >
                      <.icon name="hero-trash" class="w-4 h-4 mr-2" /> Delete
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
