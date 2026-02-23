defmodule AutoforgeWeb.UserShowLive do
  use AutoforgeWeb, :live_view

  alias Autoforge.Accounts.User

  require Ash.Query

  on_mount {AutoforgeWeb.LiveUserAuth, :live_user_required}

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    current_user = socket.assigns.current_user

    case User
         |> Ash.Query.filter(id == ^id)
         |> Ash.Query.load([:bots])
         |> Ash.read_one(actor: current_user) do
      {:ok, nil} ->
        {:ok,
         socket
         |> put_flash(:error, "User not found.")
         |> push_navigate(to: ~p"/users")}

      {:ok, user} ->
        {:ok,
         assign(socket,
           page_title: user.name || to_string(user.email),
           user: user
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

        <div class="card bg-base-200 shadow-sm">
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
      </div>
    </Layouts.app>
    """
  end
end
