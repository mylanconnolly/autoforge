defmodule AutoforgeWeb.UserShowLive do
  use AutoforgeWeb, :live_view

  alias Autoforge.Accounts.{User, UserGroup, UserGroupMembership}

  require Ash.Query

  on_mount {AutoforgeWeb.LiveUserAuth, :live_user_required}

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    current_user = socket.assigns.current_user

    case load_user(id, current_user) do
      {:ok, nil} ->
        {:ok,
         socket
         |> put_flash(:error, "User not found.")
         |> push_navigate(to: ~p"/users")}

      {:ok, user} ->
        available_groups = load_available_groups(user, current_user)

        {:ok,
         assign(socket,
           page_title: user.name || to_string(user.email),
           user: user,
           available_groups: available_groups
         )}

      {:error, _} ->
        {:ok,
         socket
         |> put_flash(:error, "User not found.")
         |> push_navigate(to: ~p"/users")}
    end
  end

  @impl true
  def handle_event("delete", _params, socket) do
    current_user = socket.assigns.current_user
    user = socket.assigns.user

    if user.id == current_user.id do
      {:noreply, put_flash(socket, :error, "You cannot delete yourself.")}
    else
      Ash.destroy!(user, actor: current_user)

      {:noreply,
       socket
       |> put_flash(:info, "User deleted successfully.")
       |> push_navigate(to: ~p"/users")}
    end
  end

  def handle_event("add_group", %{"group_id" => group_id}, socket) do
    current_user = socket.assigns.current_user
    user = socket.assigns.user

    UserGroupMembership
    |> AshPhoenix.Form.for_create(:create, actor: current_user)
    |> AshPhoenix.Form.submit(params: %{"user_group_id" => group_id, "user_id" => user.id})
    |> case do
      {:ok, _} ->
        {:noreply, reload_user(socket)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to add group.")}
    end
  end

  def handle_event("remove_group", %{"group_id" => group_id}, socket) do
    current_user = socket.assigns.current_user
    user = socket.assigns.user

    membership =
      UserGroupMembership
      |> Ash.Query.filter(user_group_id == ^group_id and user_id == ^user.id)
      |> Ash.read_one!(actor: current_user)

    if membership do
      Ash.destroy!(membership, actor: current_user)
    end

    {:noreply, reload_user(socket)}
  end

  defp reload_user(socket) do
    current_user = socket.assigns.current_user
    user_id = socket.assigns.user.id

    case load_user(user_id, current_user) do
      {:ok, user} when not is_nil(user) ->
        available_groups = load_available_groups(user, current_user)

        assign(socket,
          user: user,
          available_groups: available_groups
        )

      _ ->
        socket
        |> put_flash(:error, "User not found.")
        |> push_navigate(to: ~p"/users")
    end
  end

  defp load_user(id, actor) do
    User
    |> Ash.Query.filter(id == ^id)
    |> Ash.Query.load([:bots, :user_groups])
    |> Ash.read_one(actor: actor)
  end

  defp load_available_groups(user, actor) do
    member_group_ids = Enum.map(user.user_groups, & &1.id)

    UserGroup
    |> Ash.Query.sort(name: :asc)
    |> Ash.read!(actor: actor)
    |> Enum.reject(&(&1.id in member_group_ids))
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user} active_page={:users}>
      <div class="max-w-3xl mx-auto">
        <div class="mb-6">
          <.link
            navigate={~p"/users"}
            class="text-sm text-base-content/60 hover:text-base-content transition-colors"
          >
            <.icon name="hero-arrow-left" class="w-4 h-4 inline-block mr-1" /> Back to Users
          </.link>
        </div>

        <div class="flex items-center justify-between mb-6">
          <h1 class="text-2xl font-bold tracking-tight">
            {@user.name || to_string(@user.email)}
          </h1>
          <div class="flex items-center gap-2">
            <.link navigate={~p"/users/#{@user.id}/edit"}>
              <.button variant="outline" size="sm">
                <.icon name="hero-pencil-square" class="w-4 h-4 mr-1" /> Edit
              </.button>
            </.link>
            <%= if @user.id != @current_user.id do %>
              <.button
                variant="outline"
                size="sm"
                color="danger"
                phx-click="delete"
                data-confirm="Are you sure you want to delete this user?"
              >
                <.icon name="hero-trash" class="w-4 h-4 mr-1" /> Delete
              </.button>
            <% end %>
          </div>
        </div>

        <div class="card bg-base-200 shadow-sm mb-6">
          <div class="card-body">
            <h2 class="text-lg font-semibold mb-4">Details</h2>
            <dl class="grid grid-cols-1 sm:grid-cols-2 gap-x-6 gap-y-4">
              <div>
                <dt class="text-sm text-base-content/60">Email</dt>
                <dd class="mt-1 font-medium">{@user.email}</dd>
              </div>
              <div>
                <dt class="text-sm text-base-content/60">Name</dt>
                <dd class="mt-1 font-medium">{@user.name || "—"}</dd>
              </div>
              <div>
                <dt class="text-sm text-base-content/60">Timezone</dt>
                <dd class="mt-1 font-medium">{@user.timezone}</dd>
              </div>
            </dl>
          </div>
        </div>

        <div class="card bg-base-200 shadow-sm mb-6">
          <div class="card-body">
            <div class="flex items-center gap-2 mb-4">
              <h2 class="text-lg font-semibold">Bots</h2>
              <span class="badge badge-sm">{length(@user.bots)}</span>
            </div>
            <%= if @user.bots == [] do %>
              <p class="text-sm text-base-content/50">No bots created yet.</p>
            <% else %>
              <ul class="space-y-1">
                <li :for={bot <- @user.bots} class="text-sm">
                  <.icon name="hero-cpu-chip" class="w-4 h-4 inline-block mr-1 text-base-content/50" />
                  {bot.name}
                </li>
              </ul>
            <% end %>
          </div>
        </div>

        <div class="card bg-base-200 shadow-sm">
          <div class="card-body">
            <div class="flex items-center gap-2 mb-4">
              <h2 class="text-lg font-semibold">Groups</h2>
              <span class="badge badge-sm">{length(@user.user_groups)}</span>
            </div>

            <%= if @available_groups != [] do %>
              <.form
                for={%{}}
                phx-submit="add_group"
                class="flex items-end gap-3 mb-4"
              >
                <div class="flex-1">
                  <label class="text-sm font-medium mb-1 block">Add to group</label>
                  <select name="group_id" class="select select-bordered w-full">
                    <option :for={group <- @available_groups} value={group.id}>
                      {group.name}
                    </option>
                  </select>
                </div>
                <.button type="submit" variant="solid" color="primary" size="sm">
                  <.icon name="hero-plus" class="w-4 h-4 mr-1" /> Add
                </.button>
              </.form>
            <% end %>

            <%= if @user.user_groups == [] do %>
              <p class="text-sm text-base-content/50">Not a member of any groups.</p>
            <% else %>
              <.table>
                <.table_head>
                  <:col class="w-full">Group</:col>
                  <:col></:col>
                </.table_head>
                <.table_body>
                  <.table_row :for={group <- @user.user_groups}>
                    <:cell class="w-full">
                      <.link
                        navigate={~p"/user-groups/#{group.id}"}
                        class="font-medium hover:underline"
                      >
                        {group.name}
                      </.link>
                    </:cell>
                    <:cell>
                      <.button
                        variant="ghost"
                        size="sm"
                        color="danger"
                        phx-click="remove_group"
                        phx-value-group_id={group.id}
                        data-confirm="Remove this user from the group?"
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
