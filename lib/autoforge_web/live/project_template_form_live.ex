defmodule AutoforgeWeb.ProjectTemplateFormLive do
  use AutoforgeWeb, :live_view

  alias Autoforge.Projects.{CodeServerExtension, OpenVsx, ProjectTemplate}

  require Ash.Query

  on_mount {AutoforgeWeb.LiveUserAuth, :live_user_required}

  @impl true
  def mount(params, _session, socket) do
    user = socket.assigns.current_user

    case params do
      %{"id" => id} ->
        template =
          ProjectTemplate
          |> Ash.Query.filter(id == ^id)
          |> Ash.read_one!(actor: user)

        if template do
          form =
            template
            |> AshPhoenix.Form.for_update(:update, actor: user)
            |> to_form()

          extensions = template.code_server_extensions || []
          Enum.each(extensions, &fetch_extension_detail/1)

          {:ok,
           assign(socket,
             page_title: "Edit Template",
             form: form,
             editing?: true,
             template_id: id,
             selected_extensions: extensions,
             extension_search_results: [],
             extension_search_loading: false,
             extension_details: %{}
           )}
        else
          {:ok,
           socket
           |> put_flash(:error, "Template not found.")
           |> push_navigate(to: ~p"/project-templates")}
        end

      _ ->
        form =
          ProjectTemplate
          |> AshPhoenix.Form.for_create(:create, actor: user)
          |> to_form()

        {:ok,
         assign(socket,
           page_title: "New Template",
           form: form,
           editing?: false,
           template_id: nil,
           selected_extensions: [],
           extension_search_results: [],
           extension_search_loading: false,
           extension_details: %{}
         )}
    end
  end

  @impl true
  def handle_event("validate", %{"form" => params}, socket) do
    form =
      socket.assigns.form.source
      |> AshPhoenix.Form.validate(params)
      |> to_form()

    {:noreply, assign(socket, form: form)}
  end

  def handle_event("save", %{"form" => params}, socket) do
    ext_maps =
      Enum.map(socket.assigns.selected_extensions, fn ext ->
        %{"id" => ext.id, "display_name" => ext.display_name}
      end)

    params = Map.put(params, "code_server_extensions", ext_maps)

    case AshPhoenix.Form.submit(socket.assigns.form.source, params: params) do
      {:ok, template} ->
        action = if socket.assigns.editing?, do: "updated", else: "created"

        {:noreply,
         socket
         |> put_flash(:info, "Template #{action} successfully.")
         |> push_navigate(to: ~p"/project-templates/#{template.id}/files")}

      {:error, form} ->
        {:noreply, assign(socket, form: to_form(form))}
    end
  end

  def handle_event("search_extensions", %{"value" => query}, socket) do
    query = String.trim(query)

    if String.length(query) < 2 do
      {:noreply, assign(socket, extension_search_results: [], extension_search_loading: false)}
    else
      selected_ids = MapSet.new(socket.assigns.selected_extensions, & &1.id)

      case OpenVsx.search(query) do
        {:ok, results} ->
          filtered = Enum.reject(results, fn r -> MapSet.member?(selected_ids, r["id"]) end)

          {:noreply,
           assign(socket, extension_search_results: filtered, extension_search_loading: false)}

        {:error, _reason} ->
          {:noreply,
           assign(socket, extension_search_results: [], extension_search_loading: false)}
      end
    end
  end

  def handle_event("add_extension", %{"id" => id, "display-name" => display_name}, socket) do
    ext = CodeServerExtension.new!(%{id: id, display_name: display_name})
    fetch_extension_detail(ext)

    selected = socket.assigns.selected_extensions ++ [ext]
    results = Enum.reject(socket.assigns.extension_search_results, fn r -> r["id"] == id end)

    {:noreply, assign(socket, selected_extensions: selected, extension_search_results: results)}
  end

  def handle_event("remove_extension", %{"id" => id}, socket) do
    selected = Enum.reject(socket.assigns.selected_extensions, fn ext -> ext.id == id end)
    {:noreply, assign(socket, selected_extensions: selected)}
  end

  @impl true
  def handle_info({ref, {:extension_details, id, {:ok, details}}}, socket)
      when is_reference(ref) do
    Process.demonitor(ref, [:flush])

    {:noreply,
     assign(socket, extension_details: Map.put(socket.assigns.extension_details, id, details))}
  end

  def handle_info({ref, {:extension_details, _id, {:error, _reason}}}, socket)
      when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, socket}
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, socket) do
    {:noreply, socket}
  end

  defp fetch_extension_detail(ext) do
    Task.async(fn -> {:extension_details, ext.id, OpenVsx.get_details(ext.id)} end)
  end

  @template_variables [
    {"project_name", "The project name as entered by the user"},
    {"db_host", "Hostname of the PostgreSQL container"},
    {"db_port", "PostgreSQL port (always 5432)"},
    {"db_name", "Name of the primary database"},
    {"db_test_name", "Name of the test database"},
    {"db_user", "Database username (always postgres)"},
    {"db_password", "Auto-generated database password"},
    {"app_url", "Full Tailscale URL with https:// scheme"},
    {"phx_host", "Tailscale hostname without scheme (for PHX_HOST)"}
  ]

  defp template_variables(assigns) do
    assigns = assign(assigns, :variables, @template_variables)

    ~H"""
    <div
      id={"var-group-#{System.unique_integer([:positive])}"}
      phx-hook="PopoverGroup"
      class="mt-1.5 flex flex-wrap items-center gap-1.5 text-xs text-base-content/50"
    >
      <span>Variables:</span>
      <.popover :for={{var, desc} <- @variables} open_on_hover placement="top" class="max-w-xs">
        <code
          id={"var-#{var}-#{System.unique_integer([:positive])}"}
          phx-hook="CopyToClipboard"
          data-clipboard-text={"{{ #{var} }}"}
          data-copied-html="<span class='text-success text-[10px]'>Copied!</span>"
          class="px-1.5 py-0.5 rounded bg-base-300 text-base-content/70 font-mono cursor-pointer hover:bg-primary/15 hover:text-primary transition-colors"
        >
          {"{{ #{var} }}"}
        </code>
        <:content>
          <p class="text-xs">
            <span class="font-semibold text-base-content">{var}</span>
            <span class="text-base-content/60"> —        {desc}</span>
          </p>
          <p class="text-[10px] text-base-content/40 mt-1">Click to copy</p>
        </:content>
      </.popover>
    </div>
    """
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user} active_page={:templates}>
      <div>
        <div class="mb-6">
          <.link
            navigate={~p"/project-templates"}
            class="text-sm text-base-content/60 hover:text-base-content transition-colors"
          >
            <.icon name="hero-arrow-left" class="w-4 h-4 inline-block mr-1" /> Back to Templates
          </.link>
          <h1 class="text-2xl font-bold tracking-tight mt-2">
            {if @editing?, do: "Edit Template", else: "New Template"}
          </h1>
          <p class="mt-2 text-base-content/70">
            {if @editing?,
              do: "Update your template configuration.",
              else: "Configure a new project template."}
          </p>
        </div>

        <div class="card bg-base-200 shadow-sm">
          <div class="card-body">
            <.form for={@form} phx-change="validate" phx-submit="save" class="space-y-4">
              <.input
                field={@form[:name]}
                label="Name"
                placeholder="Node.js Starter"
              />

              <.textarea
                field={@form[:description]}
                label="Description"
                placeholder="A starter template for Node.js projects..."
                rows={3}
              />

              <.input
                field={@form[:base_image]}
                label="Base Image"
                placeholder="node:20-alpine"
                help_text="Docker image used for the application container (e.g. elixir:1.18-alpine, node:20-alpine)"
              />

              <.input
                field={@form[:db_image]}
                label="Database Image"
                placeholder="postgres:18-alpine"
                help_text="Docker image used for the database container (e.g. postgres:18-alpine, mysql:8)"
              />

              <div>
                <.textarea
                  field={@form[:bootstrap_script]}
                  label="Bootstrap Script"
                  placeholder="#!/bin/sh"
                  rows={8}
                  class="font-mono text-sm bg-base-300 border-base-300 rounded-lg px-3 py-2 w-full max-h-80 overflow-y-auto"
                />
                <.template_variables />
              </div>

              <div>
                <.textarea
                  field={@form[:startup_script]}
                  label="Startup Script"
                  placeholder="curl -fsSL https://claude.ai/install.sh | bash"
                  rows={5}
                  class="font-mono text-sm bg-base-300 border-base-300 rounded-lg px-3 py-2 w-full max-h-80 overflow-y-auto"
                />
                <p class="mt-1.5 text-xs text-base-content/50">
                  Runs as the
                  <code class="px-1 py-0.5 rounded bg-base-300 text-base-content/70 font-mono">
                    app
                  </code>
                  user on every container start. Use for user-level tooling (e.g. CLI installs).
                </p>
                <.template_variables />
              </div>

              <div>
                <.textarea
                  field={@form[:dev_server_script]}
                  label="Dev Server Script"
                  placeholder="mix ecto.setup\nmix phx.server"
                  rows={5}
                  class="font-mono text-sm bg-base-300 border-base-300 rounded-lg px-3 py-2 w-full max-h-80 overflow-y-auto"
                />
                <p class="mt-1.5 text-xs text-base-content/50">
                  Multi-line script to start the dev server. Each line runs in sequence.
                  Leave blank to disable the server button.
                </p>
                <.template_variables />
              </div>

              <div>
                <label class="block text-sm font-medium mb-1">Code Server Extensions</label>
                <p class="text-xs text-base-content/50 mb-3">
                  Extensions from the Open VSX registry to pre-install in the code editor.
                </p>

                <div
                  :if={@selected_extensions != []}
                  id="ext-chips"
                  phx-hook="PopoverGroup"
                  class="flex flex-wrap gap-2 mb-3"
                >
                  <.popover
                    :for={ext <- @selected_extensions}
                    open_on_hover
                    placement="top"
                    class="max-w-sm"
                  >
                    <span class="inline-flex items-center gap-1.5 px-2.5 py-1 bg-base-300 rounded-md text-sm cursor-default">
                      {ext.display_name}
                      <button
                        type="button"
                        phx-click="remove_extension"
                        phx-value-id={ext.id}
                        class="text-base-content/40 hover:text-error transition-colors"
                      >
                        <.icon name="hero-x-mark" class="w-3.5 h-3.5" />
                      </button>
                    </span>
                    <:content>
                      <.extension_popover_content
                        ext={ext}
                        details={Map.get(@extension_details, ext.id)}
                      />
                    </:content>
                  </.popover>
                </div>

                <div class="relative">
                  <div
                    :if={@extension_search_results != []}
                    class="absolute z-10 bottom-full mb-1 w-full bg-base-200 border border-base-300 rounded-lg shadow-lg max-h-64 overflow-y-auto"
                  >
                    <button
                      :for={result <- @extension_search_results}
                      type="button"
                      phx-click="add_extension"
                      phx-value-id={result["id"]}
                      phx-value-display-name={result["display_name"]}
                      class="w-full text-left px-3 py-2 hover:bg-base-300 transition-colors border-b border-base-300 last:border-b-0"
                    >
                      <div class="flex items-center justify-between">
                        <span class="font-medium text-sm">{result["display_name"]}</span>
                        <span class="text-xs text-base-content/40">
                          {format_download_count(result["download_count"])}
                        </span>
                      </div>
                      <div class="text-xs text-base-content/50">{result["id"]}</div>
                      <div
                        :if={result["description"] != ""}
                        class="text-xs text-base-content/40 mt-0.5 line-clamp-1"
                      >
                        {result["description"]}
                      </div>
                    </button>
                  </div>

                  <.input
                    name="extension_search"
                    value=""
                    placeholder="Search extensions..."
                    phx-keyup="search_extensions"
                    phx-debounce="300"
                    autocomplete="off"
                  />
                </div>
              </div>

              <div class="flex items-center gap-3 pt-2">
                <.button type="submit" variant="solid" color="primary">
                  {if @editing?, do: "Save Changes", else: "Create Template"}
                </.button>
                <.link navigate={~p"/project-templates"}>
                  <.button type="button" variant="ghost">
                    Cancel
                  </.button>
                </.link>
              </div>
            </.form>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp extension_popover_content(assigns) do
    ~H"""
    <div :if={@details == nil} class="flex items-center gap-2 text-xs text-base-content/50">
      <.icon name="hero-arrow-path" class="w-3.5 h-3.5 animate-spin" /> Loading...
    </div>
    <div :if={@details != nil} class="space-y-1.5">
      <p class="text-sm font-semibold text-base-content">{@details["display_name"]}</p>
      <p class="text-xs text-base-content/50 font-mono">{@ext.id}</p>
      <p :if={@details["description"] != ""} class="text-xs text-base-content/70">
        {@details["description"]}
      </p>
      <div class="flex flex-wrap gap-x-3 gap-y-1 text-[11px] text-base-content/50 pt-1">
        <span :if={@details["publisher"]}>
          <.icon name="hero-user" class="w-3 h-3 inline-block -mt-0.5" /> {@details["publisher"]}
        </span>
        <span :if={@details["version"]}>
          v{@details["version"]}
        </span>
        <span>
          <.icon name="hero-arrow-down-tray" class="w-3 h-3 inline-block -mt-0.5" /> {format_download_count(
            @details["download_count"]
          )}
        </span>
        <span :if={@details["license"]}>
          {@details["license"]}
        </span>
      </div>
      <div :if={@details["categories"] != []} class="flex flex-wrap gap-1 pt-0.5">
        <span
          :for={cat <- @details["categories"]}
          class="px-1.5 py-0.5 bg-base-300 rounded text-[10px] text-base-content/50"
        >
          {cat}
        </span>
      </div>
    </div>
    """
  end

  defp format_download_count(count) when count >= 1_000_000 do
    "#{Float.round(count / 1_000_000, 1)}M"
  end

  defp format_download_count(count) when count >= 1_000 do
    "#{Float.round(count / 1_000, 1)}K"
  end

  defp format_download_count(count), do: to_string(count)
end
