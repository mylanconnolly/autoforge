defmodule AutoforgeWeb.ProjectEnvVarsComponent do
  use AutoforgeWeb, :live_component

  alias Autoforge.Projects.ProjectEnvVar

  require Ash.Query

  @impl true
  def update(assigns, socket) do
    socket =
      socket
      |> assign(:current_user, assigns.current_user)
      |> assign(:project_id, assigns.project_id)
      |> assign(:system_vars, build_system_vars(assigns.project))
      |> load_env_vars()
      |> assign(form: nil, editing_var: nil)

    {:ok, socket}
  end

  @impl true
  def handle_event("new", _params, socket) do
    project_id = socket.assigns.project_id

    form =
      ProjectEnvVar
      |> AshPhoenix.Form.for_create(:create,
        actor: socket.assigns.current_user,
        transform_params: fn params, _meta ->
          Map.put(params, "project_id", project_id)
        end
      )
      |> to_form()

    {:noreply, assign(socket, form: form, editing_var: nil)}
  end

  def handle_event("edit", %{"id" => id}, socket) do
    var = Enum.find(socket.assigns.env_vars, &(&1.id == id))

    form =
      var
      |> AshPhoenix.Form.for_update(:update, actor: socket.assigns.current_user)
      |> to_form()

    {:noreply, assign(socket, form: form, editing_var: var)}
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
      {:ok, _var} ->
        sync_env_to_container(socket.assigns.project_id)

        socket =
          socket
          |> load_env_vars()
          |> assign(form: nil, editing_var: nil)

        {:noreply, socket}

      {:error, form} ->
        {:noreply, assign(socket, form: to_form(form))}
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    var = Enum.find(socket.assigns.env_vars, &(&1.id == id))

    if var do
      Ash.destroy!(var, actor: socket.assigns.current_user)
      sync_env_to_container(socket.assigns.project_id)
    end

    socket =
      socket
      |> load_env_vars()
      |> assign(form: nil, editing_var: nil)

    {:noreply, socket}
  end

  def handle_event("cancel", _params, socket) do
    {:noreply, assign(socket, form: nil, editing_var: nil)}
  end

  defp load_env_vars(socket) do
    user = socket.assigns.current_user
    project_id = socket.assigns.project_id

    env_vars =
      ProjectEnvVar
      |> Ash.Query.filter(project_id == ^project_id)
      |> Ash.Query.sort(key: :asc)
      |> Ash.read!(actor: user)

    assign(socket, env_vars: env_vars)
  end

  defp build_system_vars(project) do
    db_host = "db-#{project.id}"

    [
      {"PORT", "4000", "Application listen port"},
      {"DATABASE_URL", "postgresql://postgres:***@#{db_host}:5432/#{project.db_name}",
       "Full PostgreSQL connection string"},
      {"DATABASE_TEST_URL", "postgresql://postgres:***@#{db_host}:5432/#{project.db_name}_test",
       "Test database connection string"},
      {"DB_HOST", db_host, "Database hostname"},
      {"DB_PORT", "5432", "Database port"},
      {"DB_NAME", project.db_name, "Database name"},
      {"DB_TEST_NAME", "#{project.db_name}_test", "Test database name"},
      {"DB_USER", "postgres", "Database username"},
      {"DB_PASSWORD", "***", "Database password"}
    ]
  end

  defp sync_env_to_container(project_id) do
    Task.Supervisor.start_child(Autoforge.TaskSupervisor, fn ->
      Autoforge.Projects.Sandbox.sync_env_vars(project_id)
    end)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <div class="mb-4">
        <div class="flex items-center justify-between">
          <h2 class="text-xl font-semibold tracking-tight">Environment Variables</h2>
          <.button
            :if={@form == nil}
            phx-click="new"
            phx-target={@myself}
            variant="solid"
            color="primary"
            size="sm"
          >
            <.icon name="hero-plus" class="w-4 h-4 mr-1" /> Add Variable
          </.button>
        </div>
        <p class="mt-1 text-sm text-base-content/70">
          Manage environment variables injected into your project containers.
          New terminals and dev server sessions will pick up changes automatically.
        </p>
      </div>

      <div class="card bg-base-100 border border-base-300 mb-4">
        <div class="card-body">
          <div class="flex items-center gap-2 mb-3">
            <h3 class="text-lg font-medium">System Variables</h3>
            <span class="badge badge-sm badge-neutral">Read-only</span>
          </div>
          <p class="text-sm text-base-content/60 mb-3">
            These variables are automatically injected into every container session.
          </p>
          <div class="overflow-x-auto">
            <table class="table table-sm">
              <thead>
                <tr class="text-base-content/60">
                  <th>Name</th>
                  <th>Value</th>
                  <th>Description</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={{key, value, desc} <- @system_vars} class="hover:bg-base-200/50">
                  <td>
                    <div class="flex items-center gap-1.5">
                      <code class="font-mono text-sm font-medium">{key}</code>
                      <button
                        phx-hook="CopyToClipboard"
                        id={"copy-sysvar-#{key}"}
                        data-clipboard-text={key}
                        data-copied-html="<span class='text-success text-xs'>Copied!</span>"
                        class="p-0.5 rounded hover:bg-base-300 transition-colors text-base-content/40 hover:text-base-content/70"
                        title={"Copy #{key}"}
                      >
                        <.icon name="hero-clipboard-document" class="w-3.5 h-3.5" />
                      </button>
                    </div>
                  </td>
                  <td>
                    <span class="font-mono text-xs text-base-content/60">{value}</span>
                  </td>
                  <td>
                    <span class="text-sm text-base-content/50">{desc}</span>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>
      </div>

      <%= if @form do %>
        <div class="card bg-base-100 border border-base-300 mb-4">
          <div class="card-body">
            <h3 class="text-lg font-medium mb-3">
              {if @editing_var, do: "Edit Variable", else: "Add New Variable"}
            </h3>
            <.form
              for={@form}
              phx-change="validate"
              phx-submit="save"
              phx-target={@myself}
              class="space-y-4"
            >
              <.input
                field={@form[:key]}
                label="Name"
                placeholder="e.g. MY_API_KEY"
              />

              <.input
                field={@form[:value]}
                label="Value"
                type="password"
                placeholder="Enter value..."
              />

              <div class="flex items-center gap-3 pt-2">
                <.button type="submit" variant="solid" color="primary" size="sm">
                  {if @editing_var, do: "Update Variable", else: "Save Variable"}
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

      <%= if @env_vars == [] and @form == nil do %>
        <div class="card bg-base-200">
          <div class="card-body items-center text-center py-10">
            <.icon name="hero-variable" class="w-10 h-10 text-base-content/30 mb-2" />
            <p class="text-base-content/70">No environment variables configured yet.</p>
            <p class="text-sm text-base-content/50">
              Add variables to inject API keys and other secrets into your project.
            </p>
          </div>
        </div>
      <% else %>
        <.table :if={@env_vars != []}>
          <.table_head>
            <:col>Name</:col>
            <:col>Added</:col>
            <:col></:col>
          </.table_head>
          <.table_body>
            <.table_row :for={var <- @env_vars}>
              <:cell>
                <span class="font-mono font-medium">{var.key}</span>
              </:cell>
              <:cell class="text-base-content/70 text-sm">
                <.local_time value={var.inserted_at} user={@current_user} />
              </:cell>
              <:cell>
                <.dropdown placement="bottom-end">
                  <:toggle>
                    <button class="p-1 rounded-lg hover:bg-base-300 transition-colors">
                      <.icon name="hero-ellipsis-horizontal" class="w-5 h-5" />
                    </button>
                  </:toggle>
                  <.dropdown_button phx-click="edit" phx-value-id={var.id} phx-target={@myself}>
                    <.icon name="hero-pencil-square" class="w-4 h-4 mr-2" /> Edit
                  </.dropdown_button>
                  <.dropdown_separator />
                  <.dropdown_button
                    phx-click="delete"
                    phx-value-id={var.id}
                    phx-target={@myself}
                    data-confirm="Are you sure you want to delete this variable?"
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
