defmodule AutoforgeWeb.ProjectTemplateFormLive do
  use AutoforgeWeb, :live_view

  alias Autoforge.Projects.ProjectTemplate

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

          {:ok,
           assign(socket,
             page_title: "Edit Template",
             form: form,
             editing?: true,
             template_id: id
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
           template_id: nil
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
    <div class="mt-1.5 flex flex-wrap items-center gap-1.5 text-xs text-base-content/50">
      <span>Variables:</span>
      <.popover :for={{var, desc} <- @variables} open_on_hover placement="top" class="max-w-xs">
        <code
          id={"var-#{var}-#{System.unique_integer([:positive])}"}
          phx-hook="CopyToClipboard"
          data-clipboard-text={"{{ #{var} }}"}
          data-copied-html={"<span class='text-success text-[10px]'>Copied!</span>"}
          class="px-1.5 py-0.5 rounded bg-base-300 text-base-content/70 font-mono cursor-pointer hover:bg-primary/15 hover:text-primary transition-colors"
        >
          {"{{ #{var} }}"}
        </code>
        <:content>
          <p class="text-xs">
            <span class="font-semibold text-base-content">{var}</span>
            <span class="text-base-content/60"> — {desc}</span>
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
      <div class="max-w-2xl mx-auto">
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
end
