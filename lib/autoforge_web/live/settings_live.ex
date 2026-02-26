defmodule AutoforgeWeb.SettingsLive do
  use AutoforgeWeb, :live_view

  on_mount {AutoforgeWeb.LiveUserAuth, :live_user_required}

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "Settings")}
  end

  attr :title, :string, required: true
  attr :subtitle, :string, default: nil
  attr :open, :boolean, default: false
  slot :inner_block, required: true

  defp settings_section(assigns) do
    ~H"""
    <details class="group mt-8" {if @open, do: [open: "open"], else: []}>
      <summary class="flex items-center justify-between cursor-pointer list-none select-none">
        <div>
          <h2 class="text-xl font-semibold tracking-tight">{@title}</h2>
          <p :if={@subtitle} class="mt-1 text-sm text-base-content/70">{@subtitle}</p>
        </div>
        <.icon
          name="hero-chevron-right"
          class="w-5 h-5 text-base-content/40 transition-transform group-open:rotate-90"
        />
      </summary>
      {render_slot(@inner_block)}
    </details>
    """
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user} active_page={:settings}>
      <div class="max-w-2xl mx-auto">
        <div class="mb-6">
          <h1 class="text-2xl font-bold tracking-tight">Settings</h1>
          <p class="mt-2 text-base-content/70">
            Manage global application settings.
          </p>
        </div>

        <.settings_section
          title="LLM Provider Keys"
          subtitle="Manage API keys for LLM providers."
          open
        >
          <.live_component
            module={AutoforgeWeb.LlmProviderKeysComponent}
            id="llm-keys"
            current_user={@current_user}
          />
        </.settings_section>

        <.settings_section
          title="Tailscale Integration"
          subtitle="Expose project dev servers via HTTPS on your tailnet."
        >
          <.live_component
            module={AutoforgeWeb.TailscaleConfigComponent}
            id="tailscale-config"
            current_user={@current_user}
          />
        </.settings_section>

        <.settings_section
          title="Google Service Accounts"
          subtitle="Enable bots to use Google Workspace tools via domain-wide delegation."
        >
          <.live_component
            module={AutoforgeWeb.GoogleServiceAccountComponent}
            id="google-service-account"
            current_user={@current_user}
          />
        </.settings_section>

        <.settings_section
          title="GCS Storage"
          subtitle="Configure Google Cloud Storage buckets for file uploads and attachments."
        >
          <.live_component
            module={AutoforgeWeb.GcsStorageConfigComponent}
            id="gcs-storage-config"
            current_user={@current_user}
          />
        </.settings_section>

        <.settings_section
          title="Connecteam API Keys"
          subtitle="Manage API keys for Connecteam scheduling, jobs, and onboarding tools."
        >
          <.live_component
            module={AutoforgeWeb.ConnecteamApiKeyComponent}
            id="connecteam-api-keys"
            current_user={@current_user}
          />
        </.settings_section>
      </div>
    </Layouts.app>
    """
  end
end
