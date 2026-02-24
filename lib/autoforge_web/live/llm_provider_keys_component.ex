defmodule AutoforgeWeb.LlmProviderKeysComponent do
  use AutoforgeWeb, :live_component

  alias Autoforge.Accounts.LlmProviderKey

  require Ash.Query

  @impl true
  def update(assigns, socket) do
    socket = assign(socket, :current_user, assigns.current_user)
    socket = load_keys(socket)
    socket = assign(socket, form: nil, editing_key: nil)

    {:ok, socket}
  end

  @impl true
  def handle_event("new", _params, socket) do
    form =
      LlmProviderKey
      |> AshPhoenix.Form.for_create(:create, actor: socket.assigns.current_user)
      |> to_form()

    {:noreply, assign(socket, form: form, editing_key: nil)}
  end

  def handle_event("edit", %{"id" => id}, socket) do
    key = Enum.find(socket.assigns.keys, &(&1.id == id))

    form =
      key
      |> AshPhoenix.Form.for_update(:update, actor: socket.assigns.current_user)
      |> to_form()

    {:noreply, assign(socket, form: form, editing_key: key)}
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
      {:ok, _key} ->
        socket =
          socket
          |> load_keys()
          |> assign(form: nil, editing_key: nil)

        {:noreply, socket}

      {:error, form} ->
        {:noreply, assign(socket, form: to_form(form))}
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    key = Enum.find(socket.assigns.keys, &(&1.id == id))

    if key do
      Ash.destroy!(key, actor: socket.assigns.current_user)
    end

    socket =
      socket
      |> load_keys()
      |> assign(form: nil, editing_key: nil)

    {:noreply, socket}
  end

  def handle_event("cancel", _params, socket) do
    {:noreply, assign(socket, form: nil, editing_key: nil)}
  end

  defp load_keys(socket) do
    user = socket.assigns.current_user

    keys =
      LlmProviderKey
      |> Ash.Query.sort(provider: :asc)
      |> Ash.read!(actor: user)

    available_providers =
      LLMDB.providers()
      |> Enum.sort_by(& &1.name)
      |> Enum.map(&{&1.name, &1.id})

    assign(socket, keys: keys, available_providers: available_providers)
  end

  defp provider_name(provider_id) do
    case LLMDB.provider(provider_id) do
      {:ok, provider} -> provider.name
      _ -> to_string(provider_id)
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <div class="flex items-center justify-between mb-4">
        <div>
          <h2 class="text-xl font-semibold tracking-tight">LLM Provider Keys</h2>
          <p class="mt-1 text-sm text-base-content/70">
            Manage API keys for LLM providers.
          </p>
        </div>
        <.button
          :if={@form == nil}
          phx-click="new"
          phx-target={@myself}
          variant="solid"
          color="primary"
          size="sm"
        >
          <.icon name="hero-plus" class="w-4 h-4 mr-1" /> Add Key
        </.button>
      </div>

      <%= if @form do %>
        <div class="card bg-base-100 border border-base-300 mb-4">
          <div class="card-body">
            <h3 class="text-lg font-medium mb-3">
              {if @editing_key, do: "Edit Key", else: "Add New Key"}
            </h3>
            <.form
              for={@form}
              phx-change="validate"
              phx-submit="save"
              phx-target={@myself}
              class="space-y-4"
            >
              <.select
                :if={@editing_key == nil}
                field={@form[:provider]}
                label="Provider"
                placeholder="Select a provider..."
                options={@available_providers}
                searchable
                search_input_placeholder="Search providers..."
              />

              <.input
                field={@form[:name]}
                label="Label"
                placeholder="e.g. My OpenAI Key"
              />

              <.input
                field={@form[:value]}
                label="API Key"
                type="password"
                placeholder="sk-..."
              />

              <div class="flex items-center gap-3 pt-2">
                <.button type="submit" variant="solid" color="primary" size="sm">
                  {if @editing_key, do: "Update Key", else: "Save Key"}
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

      <%= if @keys == [] and @form == nil do %>
        <div class="card bg-base-200">
          <div class="card-body items-center text-center py-10">
            <.icon name="hero-key" class="w-10 h-10 text-base-content/30 mb-2" />
            <p class="text-base-content/70">No API keys configured yet.</p>
            <p class="text-sm text-base-content/50">
              Add a key to start using LLM providers.
            </p>
          </div>
        </div>
      <% else %>
        <.table :if={@keys != []}>
          <.table_head>
            <:col>Provider</:col>
            <:col>Label</:col>
            <:col>Added</:col>
            <:col></:col>
          </.table_head>
          <.table_body>
            <.table_row :for={key <- @keys}>
              <:cell>
                <span class="font-medium">{provider_name(key.provider)}</span>
              </:cell>
              <:cell>{key.name}</:cell>
              <:cell class="text-base-content/70 text-sm">
                <.local_time value={key.inserted_at} user={@current_user} />
              </:cell>
              <:cell>
                <.dropdown placement="bottom-end">
                  <:toggle>
                    <button class="p-1 rounded-lg hover:bg-base-300 transition-colors">
                      <.icon name="hero-ellipsis-horizontal" class="w-5 h-5" />
                    </button>
                  </:toggle>
                  <.dropdown_button phx-click="edit" phx-value-id={key.id} phx-target={@myself}>
                    <.icon name="hero-pencil-square" class="w-4 h-4 mr-2" /> Edit
                  </.dropdown_button>
                  <.dropdown_separator />
                  <.dropdown_button
                    phx-click="delete"
                    phx-value-id={key.id}
                    phx-target={@myself}
                    data-confirm="Are you sure you want to delete this key?"
                    class="text-error"
                  >
                    <.icon name="hero-trash" class="w-4 h-4 mr-2" /> Delete
                  </.dropdown_button>
                </.dropdown>
              </:cell>
            </.table_row>
          </.table_body>
        </.table>
      <% end %>
    </div>
    """
  end
end
