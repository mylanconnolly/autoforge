defmodule AutoforgeWeb.UserGroupShowLive do
  use AutoforgeWeb, :live_view

  alias Autoforge.Accounts.{User, UserGroup, UserGroupMembership}

  require Ash.Query

  on_mount {AutoforgeWeb.LiveUserAuth, :live_user_required}

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    current_user = socket.assigns.current_user

    case load_group(id, current_user) do
      {:ok, nil} ->
        {:ok,
         socket
         |> put_flash(:error, "Group not found.")
         |> push_navigate(to: ~p"/user-groups")}

      {:ok, group} ->
        available_users = load_available_users(group, current_user)

        {:ok,
         assign(socket,
           page_title: group.name,
           group: group,
           available_users: available_users
         )}

      {:error, _} ->
        {:ok,
         socket
         |> put_flash(:error, "Group not found.")
         |> push_navigate(to: ~p"/user-groups")}
    end
  end

  @impl true
  def handle_event("delete", _params, socket) do
    current_user = socket.assigns.current_user
    group = socket.assigns.group

    Ash.destroy!(group, actor: current_user)

    {:noreply,
     socket
     |> put_flash(:info, "Group deleted successfully.")
     |> push_navigate(to: ~p"/user-groups")}
  end

  def handle_event("add_member", %{"user_id" => user_id}, socket) do
    current_user = socket.assigns.current_user
    group = socket.assigns.group

    UserGroupMembership
    |> AshPhoenix.Form.for_create(:create, actor: current_user)
    |> AshPhoenix.Form.submit(params: %{"user_group_id" => group.id, "user_id" => user_id})
    |> case do
      {:ok, _} ->
        {:noreply, reload_group(socket)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to add member.")}
    end
  end

  def handle_event("remove_member", %{"user_id" => user_id}, socket) do
    current_user = socket.assigns.current_user
    group = socket.assigns.group

    membership =
      UserGroupMembership
      |> Ash.Query.filter(user_group_id == ^group.id and user_id == ^user_id)
      |> Ash.read_one!(actor: current_user)

    if membership do
      Ash.destroy!(membership, actor: current_user)
    end

    {:noreply, reload_group(socket)}
  end

  defp reload_group(socket) do
    current_user = socket.assigns.current_user
    group_id = socket.assigns.group.id

    case load_group(group_id, current_user) do
      {:ok, group} when not is_nil(group) ->
        available_users = load_available_users(group, current_user)

        assign(socket,
          group: group,
          available_users: available_users
        )

      _ ->
        socket
        |> put_flash(:error, "Group not found.")
        |> push_navigate(to: ~p"/user-groups")
    end
  end

  defp load_group(id, actor) do
    UserGroup
    |> Ash.Query.filter(id == ^id)
    |> Ash.Query.load([:members])
    |> Ash.read_one(actor: actor)
  end

  defp load_available_users(group, actor) do
    member_ids = Enum.map(group.members, & &1.id)

    User
    |> Ash.Query.sort(email: :asc)
    |> Ash.read!(actor: actor)
    |> Enum.reject(&(&1.id in member_ids))
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user} active_page={:user_groups}>
      <div class="max-w-3xl mx-auto">
        <div class="mb-6">
          <.link
            navigate={~p"/user-groups"}
            class="text-sm text-base-content/60 hover:text-base-content transition-colors"
          >
            <.icon name="hero-arrow-left" class="w-4 h-4 inline-block mr-1" /> Back to Groups
          </.link>
        </div>

        <div class="flex items-center justify-between mb-6">
          <h1 class="text-2xl font-bold tracking-tight">{@group.name}</h1>
          <div class="flex items-center gap-2">
            <.link navigate={~p"/user-groups/#{@group.id}/edit"}>
              <.button variant="outline" size="sm">
                <.icon name="hero-pencil-square" class="w-4 h-4 mr-1" /> Edit
              </.button>
            </.link>
            <.button
              variant="outline"
              size="sm"
              color="danger"
              phx-click="delete"
              data-confirm="Are you sure you want to delete this group?"
            >
              <.icon name="hero-trash" class="w-4 h-4 mr-1" /> Delete
            </.button>
          </div>
        </div>

        <div class="card bg-base-200 shadow-sm mb-6">
          <div class="card-body">
            <h2 class="text-lg font-semibold mb-4">Details</h2>
            <dl class="grid grid-cols-1 sm:grid-cols-2 gap-x-6 gap-y-4">
              <div>
                <dt class="text-sm text-base-content/60">Name</dt>
                <dd class="mt-1 font-medium">{@group.name}</dd>
              </div>
              <div>
                <dt class="text-sm text-base-content/60">Description</dt>
                <dd class="mt-1 font-medium">{@group.description || "—"}</dd>
              </div>
            </dl>
          </div>
        </div>

        <div class="card bg-base-200 shadow-sm">
          <div class="card-body">
            <div class="flex items-center gap-2 mb-4">
              <h2 class="text-lg font-semibold">Members</h2>
              <span class="badge badge-sm">{length(@group.members)}</span>
            </div>

            <%= if @available_users != [] do %>
              <.form
                for={%{}}
                phx-submit="add_member"
                class="flex items-end gap-3 mb-4"
              >
                <div class="flex-1">
                  <label class="text-sm font-medium mb-1 block">Add a member</label>
                  <select
                    name="user_id"
                    class="select select-bordered w-full"
                  >
                    <option :for={user <- @available_users} value={user.id}>
                      {user.name || user.email} ({user.email})
                    </option>
                  </select>
                </div>
                <.button type="submit" variant="solid" color="primary" size="sm">
                  <.icon name="hero-plus" class="w-4 h-4 mr-1" /> Add
                </.button>
              </.form>
            <% end %>

            <%= if @group.members == [] do %>
              <p class="text-sm text-base-content/50">No members yet.</p>
            <% else %>
              <.table>
                <.table_head>
                  <:col class="w-full">Name</:col>
                  <:col>Email</:col>
                  <:col></:col>
                </.table_head>
                <.table_body>
                  <.table_row :for={member <- @group.members}>
                    <:cell class="w-full">
                      <.link navigate={~p"/users/#{member.id}"} class="font-medium hover:underline">
                        {member.name || "—"}
                      </.link>
                    </:cell>
                    <:cell>
                      {member.email}
                    </:cell>
                    <:cell>
                      <.button
                        variant="ghost"
                        size="sm"
                        color="danger"
                        phx-click="remove_member"
                        phx-value-user_id={member.id}
                        data-confirm="Remove this member from the group?"
                      >
                        <.icon name="hero-x-mark" class="w-4 h-4" />
                      </.button>
                    </:cell>
                  </.table_row>
                </.table_body>
              </.table>
            <% end %>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
