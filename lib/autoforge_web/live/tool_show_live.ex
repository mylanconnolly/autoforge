defmodule AutoforgeWeb.ToolShowLive do
  use AutoforgeWeb, :live_view

  alias Autoforge.Ai.Tool
  alias Autoforge.Config.GoogleServiceAccountConfig
  alias Autoforge.Config.ConnecteamApiKeyConfig

  require Ash.Query

  on_mount {AutoforgeWeb.LiveUserAuth, :live_user_required}

  @google_workspace_prefixes ~w(gmail_ calendar_ drive_ directory_)
  @connecteam_prefix "connecteam_"

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    current_user = socket.assigns.current_user

    case load_tool(id, current_user) do
      {:ok, nil} ->
        {:ok,
         socket
         |> put_flash(:error, "Tool not found.")
         |> push_navigate(to: ~p"/tools")}

      {:ok, tool} ->
        service_accounts = load_service_accounts(current_user)
        connecteam_configs = load_connecteam_configs(current_user)
        {config_type, config_id} = extract_config(tool)

        {:ok,
         assign(socket,
           page_title: tool.name,
           tool: tool,
           is_gw: google_workspace_tool?(tool),
           is_ct: connecteam_tool?(tool),
           service_accounts: service_accounts,
           connecteam_configs: connecteam_configs,
           form_sa_id: if(config_type == :google_workspace, do: config_id),
           form_ct_id: if(config_type == :connecteam, do: config_id),
           editing: config_id == nil
         )}

      {:error, _} ->
        {:ok,
         socket
         |> put_flash(:error, "Tool not found.")
         |> push_navigate(to: ~p"/tools")}
    end
  end

  @impl true
  def handle_event("save_config", %{"service_account_id" => sa_id}, socket) do
    current_user = socket.assigns.current_user
    tool = socket.assigns.tool

    config = %{
      "type" => "google_workspace",
      "google_service_account_config_id" => sa_id
    }

    case tool
         |> Ash.Changeset.for_update(:update, %{config: config}, actor: current_user)
         |> Ash.update() do
      {:ok, updated_tool} ->
        {_type, config_id} = extract_config(updated_tool)

        {:noreply,
         socket
         |> assign(tool: updated_tool, form_sa_id: config_id, editing: false)
         |> put_flash(:info, "Configuration saved.")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Failed to save configuration.")}
    end
  end

  def handle_event("save_connecteam_config", %{"connecteam_api_key_id" => ct_id}, socket) do
    current_user = socket.assigns.current_user
    tool = socket.assigns.tool

    config = %{
      "type" => "connecteam",
      "connecteam_api_key_config_id" => ct_id
    }

    case tool
         |> Ash.Changeset.for_update(:update, %{config: config}, actor: current_user)
         |> Ash.update() do
      {:ok, updated_tool} ->
        {_type, config_id} = extract_config(updated_tool)

        {:noreply,
         socket
         |> assign(tool: updated_tool, form_ct_id: config_id, editing: false)
         |> put_flash(:info, "Configuration saved.")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Failed to save configuration.")}
    end
  end

  def handle_event("edit_config", _params, socket) do
    {:noreply, assign(socket, editing: true)}
  end

  def handle_event("clear_config", _params, socket) do
    current_user = socket.assigns.current_user
    tool = socket.assigns.tool

    case tool
         |> Ash.Changeset.for_update(:update, %{config: nil}, actor: current_user)
         |> Ash.update() do
      {:ok, updated_tool} ->
        {:noreply,
         socket
         |> assign(tool: updated_tool, form_sa_id: nil, form_ct_id: nil, editing: true)
         |> put_flash(:info, "Configuration cleared.")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Failed to clear configuration.")}
    end
  end

  defp load_tool(id, actor) do
    Tool
    |> Ash.Query.filter(id == ^id)
    |> Ash.read_one(actor: actor)
  end

  defp load_service_accounts(actor) do
    GoogleServiceAccountConfig
    |> Ash.Query.filter(enabled == true)
    |> Ash.Query.sort(label: :asc)
    |> Ash.read!(actor: actor)
  end

  defp load_connecteam_configs(actor) do
    ConnecteamApiKeyConfig
    |> Ash.Query.filter(enabled == true)
    |> Ash.Query.sort(label: :asc)
    |> Ash.read!(actor: actor)
  end

  defp google_workspace_tool?(tool) do
    Enum.any?(@google_workspace_prefixes, &String.starts_with?(tool.name, &1))
  end

  defp connecteam_tool?(tool) do
    String.starts_with?(tool.name, @connecteam_prefix)
  end

  defp extract_config(tool) do
    case tool.config do
      %Ash.Union{type: :google_workspace, value: %{google_service_account_config_id: id}} ->
        {:google_workspace, id}

      %Ash.Union{type: :connecteam, value: %{connecteam_api_key_config_id: id}} ->
        {:connecteam, id}

      _ ->
        {nil, nil}
    end
  end

  defp find_service_account(service_accounts, id) do
    Enum.find(service_accounts, &(&1.id == id))
  end

  defp find_connecteam_config(connecteam_configs, id) do
    Enum.find(connecteam_configs, &(&1.id == id))
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user} active_page={:tools}>
      <div class="max-w-3xl mx-auto">
        <div class="mb-6">
          <.link
            navigate={~p"/tools"}
            class="text-sm text-base-content/60 hover:text-base-content transition-colors"
          >
            <.icon name="hero-arrow-left" class="w-4 h-4 inline-block mr-1" /> Back to Tools
          </.link>
        </div>

        <div class="mb-6">
          <h1 class="text-2xl font-bold tracking-tight">{@tool.name}</h1>
        </div>

        <div class="card bg-base-200 shadow-sm mb-6">
          <div class="card-body">
            <h2 class="text-lg font-semibold mb-4">Details</h2>
            <dl class="grid grid-cols-1 sm:grid-cols-2 gap-x-6 gap-y-4">
              <div>
                <dt class="text-sm text-base-content/60">Name</dt>
                <dd class="mt-1 font-medium">{@tool.name}</dd>
              </div>
              <div class="sm:col-span-2">
                <dt class="text-sm text-base-content/60">Description</dt>
                <dd class="mt-1">{@tool.description || "—"}</dd>
              </div>
            </dl>
          </div>
        </div>

        <div :if={@is_gw} class="card bg-base-200 shadow-sm">
          <div class="card-body">
            <div class="flex items-center justify-between mb-4">
              <h2 class="text-lg font-semibold">Google Workspace Configuration</h2>
              <div :if={@form_sa_id && !@editing} class="flex items-center gap-2">
                <.button variant="outline" size="sm" phx-click="edit_config">
                  <.icon name="hero-pencil-square" class="w-4 h-4 mr-1" /> Edit
                </.button>
                <.button
                  variant="outline"
                  size="sm"
                  color="danger"
                  phx-click="clear_config"
                  data-confirm="Clear this tool's configuration?"
                >
                  <.icon name="hero-trash" class="w-4 h-4 mr-1" /> Clear
                </.button>
              </div>
            </div>

            <p class="text-sm text-base-content/60 mb-4">
              Select the service account used for Google API access. Calls will be
              delegated as the user who sends the message.
            </p>

            <%= if @form_sa_id && !@editing do %>
              <dl>
                <dt class="text-sm text-base-content/60">Service Account</dt>
                <dd class="mt-1 font-medium">
                  <% sa = find_service_account(@service_accounts, @form_sa_id) %>
                  <%= if sa do %>
                    {sa.label}
                    <span class="text-xs text-base-content/50 ml-1">{sa.client_email}</span>
                  <% else %>
                    <span class="text-base-content/50">{@form_sa_id}</span>
                  <% end %>
                </dd>
              </dl>
            <% else %>
              <%= if @service_accounts == [] do %>
                <p class="text-sm text-base-content/50">
                  No service accounts configured. Add one in
                  <.link navigate={~p"/settings"} class="underline hover:text-base-content">
                    Settings
                  </.link>
                  first.
                </p>
              <% else %>
                <.form for={%{}} phx-submit="save_config" class="space-y-4">
                  <div>
                    <label class="text-sm font-medium mb-1 block">Service Account</label>
                    <select name="service_account_id" class="select select-bordered w-full">
                      <option
                        :for={sa <- @service_accounts}
                        value={sa.id}
                        selected={sa.id == @form_sa_id}
                      >
                        {sa.label} ({sa.client_email})
                      </option>
                    </select>
                  </div>
                  <div class="flex items-center gap-2">
                    <.button type="submit" variant="solid" color="primary" size="sm">
                      <.icon name="hero-check" class="w-4 h-4 mr-1" /> Save Configuration
                    </.button>
                    <.button
                      :if={@form_sa_id}
                      type="button"
                      variant="outline"
                      size="sm"
                      phx-click="edit_config"
                      phx-value-cancel="true"
                    >
                      Cancel
                    </.button>
                  </div>
                </.form>
              <% end %>
            <% end %>
          </div>
        </div>

        <div :if={@is_ct} class="card bg-base-200 shadow-sm">
          <div class="card-body">
            <div class="flex items-center justify-between mb-4">
              <h2 class="text-lg font-semibold">Connecteam Configuration</h2>
              <div :if={@form_ct_id && !@editing} class="flex items-center gap-2">
                <.button variant="outline" size="sm" phx-click="edit_config">
                  <.icon name="hero-pencil-square" class="w-4 h-4 mr-1" /> Edit
                </.button>
                <.button
                  variant="outline"
                  size="sm"
                  color="danger"
                  phx-click="clear_config"
                  data-confirm="Clear this tool's configuration?"
                >
                  <.icon name="hero-trash" class="w-4 h-4 mr-1" /> Clear
                </.button>
              </div>
            </div>

            <p class="text-sm text-base-content/60 mb-4">
              Select the API key used for Connecteam API access.
            </p>

            <%= if @form_ct_id && !@editing do %>
              <dl>
                <dt class="text-sm text-base-content/60">API Key</dt>
                <dd class="mt-1 font-medium">
                  <% ct = find_connecteam_config(@connecteam_configs, @form_ct_id) %>
                  <%= if ct do %>
                    {ct.label}
                    <span class="badge badge-sm badge-outline ml-2">
                      {if ct.region == :australia, do: "Australia", else: "Global"}
                    </span>
                  <% else %>
                    <span class="text-base-content/50">{@form_ct_id}</span>
                  <% end %>
                </dd>
              </dl>
            <% else %>
              <%= if @connecteam_configs == [] do %>
                <p class="text-sm text-base-content/50">
                  No Connecteam API keys configured. Add one in
                  <.link navigate={~p"/settings"} class="underline hover:text-base-content">
                    Settings
                  </.link>
                  first.
                </p>
              <% else %>
                <.form for={%{}} phx-submit="save_connecteam_config" class="space-y-4">
                  <div>
                    <label class="text-sm font-medium mb-1 block">API Key</label>
                    <select name="connecteam_api_key_id" class="select select-bordered w-full">
                      <option
                        :for={ct <- @connecteam_configs}
                        value={ct.id}
                        selected={ct.id == @form_ct_id}
                      >
                        {ct.label} ({if ct.region == :australia, do: "Australia", else: "Global"})
                      </option>
                    </select>
                  </div>
                  <div class="flex items-center gap-2">
                    <.button type="submit" variant="solid" color="primary" size="sm">
                      <.icon name="hero-check" class="w-4 h-4 mr-1" /> Save Configuration
                    </.button>
                    <.button
                      :if={@form_ct_id}
                      type="button"
                      variant="outline"
                      size="sm"
                      phx-click="edit_config"
                      phx-value-cancel="true"
                    >
                      Cancel
                    </.button>
                  </div>
                </.form>
              <% end %>
            <% end %>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
