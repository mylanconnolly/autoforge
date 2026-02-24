defmodule AutoforgeWeb.ProjectFormLive do
  use AutoforgeWeb, :live_view

  alias Autoforge.Projects.{Project, ProjectTemplate}

  require Ash.Query

  on_mount {AutoforgeWeb.LiveUserAuth, :live_user_required}

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user

    templates =
      ProjectTemplate
      |> Ash.Query.sort(name: :asc)
      |> Ash.read!(actor: user)

    template_options = Enum.map(templates, fn t -> {t.name, t.id} end)

    form =
      Project
      |> AshPhoenix.Form.for_create(:create, actor: user, forms: [auto?: true])
      |> to_form()

    {:ok,
     assign(socket,
       page_title: "New Project",
       form: form,
       template_options: template_options
     )}
  end

  @impl true
  def handle_event("validate", %{"form" => params}, socket) do
    form =
      socket.assigns.form.source
      |> AshPhoenix.Form.validate(params)
      |> to_form()

    {:noreply, assign(socket, form: form)}
  end

  def handle_event("add_env_var", _params, socket) do
    form =
      socket.assigns.form.source
      |> AshPhoenix.Form.add_form(:env_vars)
      |> to_form()

    {:noreply, assign(socket, form: form)}
  end

  def handle_event("remove_env_var", %{"path" => path}, socket) do
    form =
      socket.assigns.form.source
      |> AshPhoenix.Form.remove_form(path)
      |> to_form()

    {:noreply, assign(socket, form: form)}
  end

  def handle_event("save", %{"form" => params}, socket) do
    case AshPhoenix.Form.submit(socket.assigns.form.source, params: params) do
      {:ok, project} ->
        {:noreply,
         socket
         |> put_flash(:info, "Project created. Provisioning started...")
         |> push_navigate(to: ~p"/projects/#{project.id}")}

      {:error, form} ->
        {:noreply, assign(socket, form: to_form(form))}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user} active_page={:projects}>
      <div class="max-w-2xl mx-auto">
        <div class="mb-6">
          <.link
            navigate={~p"/projects"}
            class="text-sm text-base-content/60 hover:text-base-content transition-colors"
          >
            <.icon name="hero-arrow-left" class="w-4 h-4 inline-block mr-1" /> Back to Projects
          </.link>
          <h1 class="text-2xl font-bold tracking-tight mt-2">New Project</h1>
          <p class="mt-2 text-base-content/70">
            Create a new sandbox project from a template.
          </p>
        </div>

        <div class="card bg-base-200 shadow-sm">
          <div class="card-body">
            <.form for={@form} phx-change="validate" phx-submit="save" class="space-y-4">
              <.input
                field={@form[:name]}
                label="Project Name"
                placeholder="My Project"
              />

              <.select
                field={@form[:project_template_id]}
                label="Template"
                placeholder="Select a template..."
                options={@template_options}
                searchable
                search_input_placeholder="Search templates..."
              />

              <div class="space-y-3">
                <div class="flex items-center justify-between">
                  <div class="flex items-center gap-1.5">
                    <label class="text-sm font-semibold">Environment Variables</label>
                    <.popover open_on_hover placement="top" class="max-w-xs">
                      <.icon
                        name="hero-information-circle"
                        class="w-4 h-4 text-base-content/40 cursor-help"
                      />
                      <:content>
                        <p class="text-sm font-medium">Environment Variables</p>
                        <p class="text-sm text-base-content/70 mt-1">
                          Define secrets such as private package registry tokens
                          that will be injected into the project's environment
                          during provisioning and at runtime.
                        </p>
                      </:content>
                    </.popover>
                  </div>
                  <.button type="button" variant="ghost" size="sm" phx-click="add_env_var">
                    <.icon name="hero-plus" class="w-4 h-4 mr-1" /> Add Variable
                  </.button>
                </div>

                <.inputs_for :let={env_form} field={@form[:env_vars]}>
                  <div class="flex items-start gap-2">
                    <div class="flex-1">
                      <.input
                        field={env_form[:key]}
                        placeholder="MY_API_KEY"
                      />
                    </div>
                    <div class="flex-1">
                      <.input
                        field={env_form[:value]}
                        type="password"
                        placeholder="Enter value..."
                      />
                    </div>
                    <input type="hidden" name={env_form[:_form_type].name} value="create" />
                    <.button
                      type="button"
                      variant="ghost"
                      size="sm"
                      phx-click="remove_env_var"
                      phx-value-path={env_form.name}
                      class="mt-1 text-error"
                    >
                      <.icon name="hero-trash" class="w-4 h-4" />
                    </.button>
                  </div>
                </.inputs_for>

                <p
                  :if={Enum.empty?(@form[:env_vars].value || [])}
                  class="text-sm text-base-content/50 italic"
                >
                  No environment variables added yet.
                </p>
              </div>

              <div class="flex items-center gap-3 pt-2">
                <.button type="submit" variant="solid" color="primary">
                  Create Project
                </.button>
                <.link navigate={~p"/projects"}>
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
