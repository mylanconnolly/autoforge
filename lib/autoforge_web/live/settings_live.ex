defmodule AutoforgeWeb.SettingsLive do
  use AutoforgeWeb, :live_view

  on_mount {AutoforgeWeb.LiveUserAuth, :live_user_required}

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "Settings")}
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

        <.live_component
          module={AutoforgeWeb.LlmProviderKeysComponent}
          id="llm-keys"
          current_user={@current_user}
        />
      </div>
    </Layouts.app>
    """
  end
end
