defmodule AutoforgeWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use AutoforgeWeb, :html

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @doc """
  Renders your app layout with a narrow icon sidebar on the left
  and a scrollable main content area on the right.

  ## Examples

      <Layouts.app flash={@flash} current_user={@current_user} active_page={:dashboard}>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://hexdocs.pm/phoenix/scopes.html)"

  attr :current_user, :map,
    default: nil,
    doc: "the currently authenticated user"

  attr :active_page, :atom,
    default: nil,
    doc: "the currently active page for nav highlighting"

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <div class="flex h-screen overflow-hidden">
      <aside class="w-16 flex-shrink-0 flex flex-col items-center bg-base-200 border-r border-base-300 py-4">
        <.link navigate="/" class="flex items-center justify-center w-10 h-10 text-primary">
          <.icon name="hero-bolt" class="size-7" />
        </.link>

        <nav class="mt-8 flex flex-col items-center gap-2 flex-1">
          <.sidebar_nav_item
            icon="hero-squares-2x2"
            label="Dashboard"
            href={~p"/dashboard"}
            active={@active_page == :dashboard}
          />
          <.sidebar_nav_item
            icon="hero-cpu-chip"
            label="Bots"
            href={~p"/bots"}
            active={@active_page == :bots}
          />
        </nav>

        <div class="flex flex-col items-center gap-3">
          <.sidebar_theme_toggle />

          <.dropdown :if={@current_user} placement="right-end" class="w-48">
            <:toggle>
              <div class="flex items-center justify-center w-10 h-10 rounded-full bg-primary text-primary-content text-sm font-bold cursor-pointer">
                {user_initial(@current_user)}
              </div>
            </:toggle>

            <.dropdown_custom class="flex flex-col">
              <span class="text-sm font-medium truncate">
                {@current_user.name || @current_user.email}
              </span>
              <span :if={@current_user.name} class="text-xs text-base-content/60 truncate">
                {@current_user.email}
              </span>
            </.dropdown_custom>

            <.dropdown_separator />

            <.dropdown_link navigate={~p"/profile"}>
              <.icon name="hero-user" class="icon" /> Profile
            </.dropdown_link>

            <.dropdown_separator />

            <.dropdown_link href={~p"/sign-out"}>
              <.icon name="hero-arrow-right-on-rectangle" class="icon" /> Sign Out
            </.dropdown_link>
          </.dropdown>
        </div>
      </aside>

      <main class="flex-1 overflow-y-auto">
        <div class="px-4 py-8 sm:px-6 lg:px-8">
          {render_slot(@inner_block)}
        </div>

        <.flash_group flash={@flash} />
      </main>
    </div>
    """
  end

  attr :icon, :string, required: true
  attr :label, :string, required: true
  attr :href, :string, required: true
  attr :active, :boolean, default: false

  defp sidebar_nav_item(assigns) do
    ~H"""
    <.tooltip value={@label} placement="right">
      <.link
        navigate={@href}
        class={[
          "flex items-center justify-center w-10 h-10 rounded-lg transition-colors",
          if(@active,
            do: "bg-primary text-primary-content",
            else: "text-base-content/60 hover:text-base-content hover:bg-base-300"
          )
        ]}
      >
        <.icon name={@icon} class="size-5" />
      </.link>
    </.tooltip>
    """
  end

  defp sidebar_theme_toggle(assigns) do
    ~H"""
    <.tooltip value="Toggle theme" placement="right">
      <button
        phx-click={JS.dispatch("phx:cycle-theme")}
        class="flex items-center justify-center w-10 h-10 rounded-lg text-base-content/60 hover:text-base-content hover:bg-base-300 transition-colors cursor-pointer"
      >
        <.icon
          name="hero-computer-desktop"
          class="size-5 block [[data-theme=light]_&]:hidden [[data-theme=dark]_&]:hidden"
        />
        <.icon name="hero-sun" class="size-5 hidden [[data-theme=light]_&]:block" />
        <.icon name="hero-moon" class="size-5 hidden [[data-theme=dark]_&]:block" />
      </button>
    </.tooltip>
    """
  end

  defp user_initial(user) do
    (user.name || to_string(user.email))
    |> String.first()
    |> String.upcase()
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("We can't find the internet")}
        phx-disconnected={show(".phx-client-error #client-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong!")}
        phx-disconnected={show(".phx-server-error #server-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end

  @doc """
  Provides dark vs light theme toggle based on themes defined in app.css.

  See <head> in root.html.heex which applies the theme before page load.
  """
  def theme_toggle(assigns) do
    ~H"""
    <div class="card relative flex flex-row items-center border-2 border-base-300 bg-base-300 rounded-full">
      <div class="absolute w-1/3 h-full rounded-full border-1 border-base-200 bg-base-100 brightness-200 left-0 [[data-theme=light]_&]:left-1/3 [[data-theme=dark]_&]:left-2/3 transition-[left]" />

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="system"
      >
        <.icon name="hero-computer-desktop-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="light"
      >
        <.icon name="hero-sun-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="dark"
      >
        <.icon name="hero-moon-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>
    </div>
    """
  end
end
