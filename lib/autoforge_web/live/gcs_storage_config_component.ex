defmodule AutoforgeWeb.GcsStorageConfigComponent do
  use AutoforgeWeb, :live_component

  alias Autoforge.Config.GcsStorageConfig
  alias Autoforge.Config.GoogleServiceAccountConfig

  require Ash.Query

  @impl true
  def update(assigns, socket) do
    socket =
      socket
      |> assign(:current_user, assigns.current_user)
      |> load_configs()
      |> load_service_accounts()
      |> assign(form: nil, editing_config: nil)

    {:ok, socket}
  end

  @impl true
  def handle_event("new", _params, socket) do
    form =
      GcsStorageConfig
      |> AshPhoenix.Form.for_create(:create, actor: socket.assigns.current_user)
      |> to_form()

    {:noreply, assign(socket, form: form, editing_config: nil)}
  end

  def handle_event("edit", %{"id" => id}, socket) do
    config = Enum.find(socket.assigns.configs, &(&1.id == id))

    form =
      config
      |> AshPhoenix.Form.for_update(:update, actor: socket.assigns.current_user)
      |> to_form()

    {:noreply, assign(socket, form: form, editing_config: config)}
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
          |> load_configs()
          |> assign(form: nil, editing_config: nil)

        {:noreply, socket}

      {:error, form} ->
        {:noreply, assign(socket, form: to_form(form))}
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    config = Enum.find(socket.assigns.configs, &(&1.id == id))

    if config do
      Ash.destroy!(config, actor: socket.assigns.current_user)
    end

    socket =
      socket
      |> load_configs()
      |> assign(form: nil, editing_config: nil)

    {:noreply, socket}
  end

  def handle_event("cancel", _params, socket) do
    {:noreply, assign(socket, form: nil, editing_config: nil)}
  end

  defp load_configs(socket) do
    configs =
      GcsStorageConfig
      |> Ash.Query.sort(label: :asc)
      |> Ash.Query.load(:service_account_config)
      |> Ash.read!(actor: socket.assigns.current_user)

    assign(socket, configs: configs)
  end

  defp load_service_accounts(socket) do
    accounts =
      GoogleServiceAccountConfig
      |> Ash.Query.sort(label: :asc)
      |> Ash.read!(actor: socket.assigns.current_user)

    assign(socket, service_accounts: accounts)
  end

  defp service_account_options(service_accounts) do
    Enum.map(service_accounts, &{&1.label, &1.id})
  end

  defp service_account_label(config) do
    case config.service_account_config do
      %{label: label} -> label
      _ -> "Unknown"
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <div class="flex justify-end mb-4">
        <.button
          :if={@form == nil}
          phx-click="new"
          phx-target={@myself}
          variant="solid"
          color="primary"
          size="sm"
        >
          <.icon name="hero-plus" class="w-4 h-4 mr-1" /> Add Bucket
        </.button>
      </div>

      <%= if @form do %>
        <div class="card bg-base-100 border border-base-300 mb-4">
          <div class="card-body">
            <h3 class="text-lg font-medium mb-3">
              {if @editing_config, do: "Edit Storage Config", else: "Add Storage Config"}
            </h3>
            <.form
              for={@form}
              phx-change="validate"
              phx-submit="save"
              phx-target={@myself}
              class="space-y-4"
            >
              <.input
                field={@form[:label]}
                label="Label"
                placeholder="e.g. Project Files, Conversation Uploads..."
              />

              <.input
                field={@form[:bucket_name]}
                label="Bucket Name"
                placeholder="e.g. my-project-bucket"
              />

              <.input
                field={@form[:path_prefix]}
                label="Path Prefix"
                placeholder="e.g. autoforge/"
              />

              <.select
                field={@form[:service_account_config_id]}
                label="Service Account"
                placeholder="Select a service account..."
                options={service_account_options(@service_accounts)}
              />

              <div class="flex items-center gap-3 pt-2">
                <.button type="submit" variant="solid" color="primary" size="sm">
                  {if @editing_config, do: "Update", else: "Save"}
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

      <%= if @configs != [] do %>
        <div class="space-y-3">
          <div :for={config <- @configs} class="card bg-base-100 border border-base-300">
            <div class="card-body">
              <div class="flex items-center justify-between mb-3">
                <div class="flex items-center gap-2">
                  <span class="font-semibold">{config.label}</span>
                  <span class={"badge badge-sm #{if config.enabled, do: "badge-success", else: "badge-warning"}"}>
                    {if config.enabled, do: "Enabled", else: "Disabled"}
                  </span>
                </div>
                <.dropdown placement="bottom-end">
                  <:toggle>
                    <button class="p-1 rounded-lg hover:bg-base-300 transition-colors">
                      <.icon name="hero-ellipsis-horizontal" class="w-5 h-5" />
                    </button>
                  </:toggle>
                  <.dropdown_button phx-click="edit" phx-value-id={config.id} phx-target={@myself}>
                    <.icon name="hero-pencil-square" class="w-4 h-4 mr-2" /> Edit
                  </.dropdown_button>
                  <.dropdown_separator />
                  <.dropdown_button
                    phx-click="delete"
                    phx-value-id={config.id}
                    phx-target={@myself}
                    data-confirm="Are you sure you want to remove this storage config?"
                    class="text-error"
                  >
                    <.icon name="hero-trash" class="w-4 h-4 mr-2" /> Delete
                  </.dropdown_button>
                </.dropdown>
              </div>

              <dl class="space-y-2 text-sm">
                <div class="flex justify-between">
                  <dt class="text-base-content/70">Bucket</dt>
                  <dd class="font-mono">{config.bucket_name}</dd>
                </div>
                <div :if={config.path_prefix} class="flex justify-between">
                  <dt class="text-base-content/70">Path Prefix</dt>
                  <dd class="font-mono">{config.path_prefix}</dd>
                </div>
                <div class="flex justify-between">
                  <dt class="text-base-content/70">Service Account</dt>
                  <dd>{service_account_label(config)}</dd>
                </div>
              </dl>
            </div>
          </div>
        </div>
      <% end %>

      <%= if @configs == [] and @form == nil do %>
        <div class="card bg-base-200">
          <div class="card-body items-center text-center py-10">
            <.icon name="hero-cloud-arrow-up" class="w-10 h-10 text-base-content/30 mb-2" />
            <p class="text-base-content/70">No GCS storage buckets configured.</p>
            <p class="text-sm text-base-content/50">
              Add a bucket to enable file uploads and cloud storage.
            </p>
          </div>
        </div>
      <% end %>
    </div>
    """
  end
end
