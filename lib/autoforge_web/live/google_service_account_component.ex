defmodule AutoforgeWeb.GoogleServiceAccountComponent do
  use AutoforgeWeb, :live_component

  alias Autoforge.Config.GoogleServiceAccountConfig

  @impl true
  def update(assigns, socket) do
    socket =
      socket
      |> assign(:current_user, assigns.current_user)
      |> load_config()
      |> assign(form: nil, editing: false)

    {:ok, socket}
  end

  @impl true
  def handle_event("new", _params, socket) do
    form =
      GoogleServiceAccountConfig
      |> AshPhoenix.Form.for_create(:create, actor: socket.assigns.current_user)
      |> to_form()

    {:noreply, assign(socket, form: form, editing: true)}
  end

  def handle_event("edit", _params, socket) do
    form =
      socket.assigns.config
      |> AshPhoenix.Form.for_update(:update, actor: socket.assigns.current_user)
      |> to_form()

    {:noreply, assign(socket, form: form, editing: true)}
  end

  def handle_event("validate", %{"form" => params}, socket) do
    form =
      socket.assigns.form.source
      |> AshPhoenix.Form.validate(params)
      |> to_form()

    {:noreply, assign(socket, form: form)}
  end

  def handle_event("save", %{"form" => params}, socket) do
    case AshPhoenix.Form.submit(socket.assigns.form.source, params: params) do
      {:ok, _config} ->
        socket =
          socket
          |> load_config()
          |> assign(form: nil, editing: false)

        {:noreply, socket}

      {:error, form} ->
        {:noreply, assign(socket, form: to_form(form))}
    end
  end

  def handle_event("delete", _params, socket) do
    if socket.assigns.config do
      Ash.destroy!(socket.assigns.config, actor: socket.assigns.current_user)
    end

    socket =
      socket
      |> load_config()
      |> assign(form: nil, editing: false)

    {:noreply, socket}
  end

  def handle_event("cancel", _params, socket) do
    {:noreply, assign(socket, form: nil, editing: false)}
  end

  defp load_config(socket) do
    config =
      case Ash.read(GoogleServiceAccountConfig, actor: socket.assigns.current_user) do
        {:ok, [config | _]} -> config
        _ -> nil
      end

    assign(socket, config: config)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mt-8">
      <div class="flex items-center justify-between mb-4">
        <div>
          <h2 class="text-xl font-semibold tracking-tight">Google Service Account</h2>
          <p class="mt-1 text-sm text-base-content/70">
            Enable bots to use Google Workspace tools via domain-wide delegation.
          </p>
        </div>
        <.button
          :if={@form == nil && @config == nil}
          phx-click="new"
          phx-target={@myself}
          variant="solid"
          color="primary"
          size="sm"
        >
          <.icon name="hero-plus" class="w-4 h-4 mr-1" /> Configure
        </.button>
      </div>

      <%= if @form do %>
        <div class="card bg-base-100 border border-base-300 mb-4">
          <div class="card-body">
            <h3 class="text-lg font-medium mb-3">
              {if @config, do: "Edit Google Service Account", else: "Configure Google Service Account"}
            </h3>
            <.form
              for={@form}
              phx-change="validate"
              phx-submit="save"
              phx-target={@myself}
              class="space-y-4"
            >
              <.textarea
                field={@form[:service_account_json]}
                label="Service Account JSON Key"
                placeholder="Paste the contents of your service account JSON key file..."
                rows={10}
                class="font-mono text-xs"
              />

              <div class="flex items-center gap-3 pt-2">
                <.button type="submit" variant="solid" color="primary" size="sm">
                  {if @config, do: "Update", else: "Save"}
                </.button>
                <.button
                  type="button"
                  phx-click="cancel"
                  phx-target={@myself}
                  variant="ghost"
                  size="sm"
                >
                  Cancel
                </.button>
              </div>
            </.form>
          </div>
        </div>
      <% end %>

      <%= if @config && !@editing do %>
        <div class="card bg-base-100 border border-base-300">
          <div class="card-body">
            <div class="flex items-center justify-between mb-4">
              <div class="flex items-center gap-2">
                <span class={"badge badge-sm #{if @config.enabled, do: "badge-success", else: "badge-warning"}"}>
                  {if @config.enabled, do: "Enabled", else: "Disabled"}
                </span>
              </div>
              <.dropdown placement="bottom-end">
                <:toggle>
                  <button class="p-1 rounded-lg hover:bg-base-300 transition-colors">
                    <.icon name="hero-ellipsis-horizontal" class="w-5 h-5" />
                  </button>
                </:toggle>
                <.dropdown_button phx-click="edit" phx-target={@myself}>
                  <.icon name="hero-pencil-square" class="w-4 h-4 mr-2" /> Edit
                </.dropdown_button>
                <.dropdown_separator />
                <.dropdown_button
                  phx-click="delete"
                  phx-target={@myself}
                  data-confirm="Are you sure you want to remove this service account configuration?"
                  class="text-error"
                >
                  <.icon name="hero-trash" class="w-4 h-4 mr-2" /> Delete
                </.dropdown_button>
              </.dropdown>
            </div>

            <dl class="space-y-3 text-sm">
              <div class="flex justify-between">
                <dt class="text-base-content/70">Client Email</dt>
                <dd class="font-mono">{@config.client_email}</dd>
              </div>
              <div class="flex justify-between">
                <dt class="text-base-content/70">Project ID</dt>
                <dd class="font-mono">{@config.project_id}</dd>
              </div>
            </dl>
          </div>
        </div>
      <% end %>

      <%= if @config == nil && @form == nil do %>
        <div class="card bg-base-200">
          <div class="card-body items-center text-center py-10">
            <.icon name="hero-key" class="w-10 h-10 text-base-content/30 mb-2" />
            <p class="text-base-content/70">Google Service Account not configured.</p>
            <p class="text-sm text-base-content/50">
              Add a service account JSON key to enable Google Workspace integrations.
            </p>
          </div>
        </div>
      <% end %>
    </div>
    """
  end
end
