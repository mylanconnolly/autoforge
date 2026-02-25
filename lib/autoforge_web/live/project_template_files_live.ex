defmodule AutoforgeWeb.ProjectTemplateFilesLive do
  use AutoforgeWeb, :live_view

  alias Autoforge.Projects.{ProjectTemplate, ProjectTemplateFile}

  require Ash.Query

  on_mount {AutoforgeWeb.LiveUserAuth, :live_user_required}

  @impl true
  def mount(%{"id" => template_id}, _session, socket) do
    user = socket.assigns.current_user

    template =
      ProjectTemplate
      |> Ash.Query.filter(id == ^template_id)
      |> Ash.read_one!(actor: user)

    if template do
      files = load_files(template_id, user)

      {:ok,
       assign(socket,
         page_title: "#{template.name} — Files",
         template: template,
         files: files,
         selected_file: nil,
         file_form: nil,
         renaming_id: nil
       )}
    else
      {:ok,
       socket
       |> put_flash(:error, "Template not found.")
       |> push_navigate(to: ~p"/project-templates")}
    end
  end

  @impl true
  def handle_event("select_file", %{"id" => id}, socket) do
    file = Enum.find(socket.assigns.files, &(&1.id == id))

    if file && !file.is_directory do
      form =
        file
        |> AshPhoenix.Form.for_update(:update, actor: socket.assigns.current_user)
        |> to_form()

      {:noreply, assign(socket, selected_file: file, file_form: form)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("add_file", params, socket) do
    user = socket.assigns.current_user
    parent_id = params["parent_id"]

    attrs = %{
      "name" => "new_file.txt",
      "content" => "",
      "is_directory" => false,
      "sort_order" => 0,
      "project_template_id" => socket.assigns.template.id
    }

    attrs = if parent_id, do: Map.put(attrs, "parent_id", parent_id), else: attrs

    case ProjectTemplateFile
         |> AshPhoenix.Form.for_create(:create, actor: user)
         |> AshPhoenix.Form.submit(params: attrs) do
      {:ok, file} ->
        files = load_files(socket.assigns.template.id, user)

        form =
          file
          |> AshPhoenix.Form.for_update(:update, actor: user)
          |> to_form()

        {:noreply, assign(socket, files: files, selected_file: file, file_form: form)}

      {:error, _form} ->
        {:noreply, put_flash(socket, :error, "Failed to create file.")}
    end
  end

  def handle_event("add_folder", params, socket) do
    user = socket.assigns.current_user
    parent_id = params["parent_id"]

    attrs = %{
      "name" => "new_folder",
      "is_directory" => true,
      "sort_order" => 0,
      "project_template_id" => socket.assigns.template.id
    }

    attrs = if parent_id, do: Map.put(attrs, "parent_id", parent_id), else: attrs

    case ProjectTemplateFile
         |> AshPhoenix.Form.for_create(:create, actor: user)
         |> AshPhoenix.Form.submit(params: attrs) do
      {:ok, folder} ->
        files = load_files(socket.assigns.template.id, user)
        {:noreply, assign(socket, files: files, renaming_id: folder.id)}

      {:error, _form} ->
        {:noreply, put_flash(socket, :error, "Failed to create folder.")}
    end
  end

  def handle_event("delete_file", %{"id" => id}, socket) do
    user = socket.assigns.current_user
    file = Enum.find(socket.assigns.files, &(&1.id == id))

    if file do
      Ash.destroy!(file, actor: user)
    end

    files = load_files(socket.assigns.template.id, user)

    selected_file =
      if socket.assigns.selected_file && socket.assigns.selected_file.id == id do
        nil
      else
        socket.assigns.selected_file
      end

    {:noreply, assign(socket, files: files, selected_file: selected_file, file_form: nil)}
  end

  def handle_event("start_rename", %{"id" => id}, socket) do
    {:noreply, assign(socket, renaming_id: id)}
  end

  def handle_event("save_rename", %{"id" => id, "name" => name}, socket) do
    user = socket.assigns.current_user
    file = Enum.find(socket.assigns.files, &(&1.id == id))
    name = String.trim(name)

    if file && name != "" do
      Ash.update!(file, %{name: name}, action: :update, actor: user)
    end

    files = load_files(socket.assigns.template.id, user)

    selected_file =
      if socket.assigns.selected_file && socket.assigns.selected_file.id == id do
        Enum.find(files, &(&1.id == id))
      else
        socket.assigns.selected_file
      end

    {:noreply, assign(socket, files: files, selected_file: selected_file, renaming_id: nil)}
  end

  def handle_event("cancel_rename", _params, socket) do
    {:noreply, assign(socket, renaming_id: nil)}
  end

  def handle_event("validate_file", %{"form" => params}, socket) do
    form =
      socket.assigns.file_form.source
      |> AshPhoenix.Form.validate(params)
      |> to_form()

    {:noreply, assign(socket, file_form: form)}
  end

  def handle_event("save_file", %{"form" => params}, socket) do
    case AshPhoenix.Form.submit(socket.assigns.file_form.source, params: params) do
      {:ok, file} ->
        files = load_files(socket.assigns.template.id, socket.assigns.current_user)

        form =
          file
          |> AshPhoenix.Form.for_update(:update, actor: socket.assigns.current_user)
          |> to_form()

        {:noreply,
         socket
         |> assign(files: files, selected_file: file, file_form: form)
         |> put_flash(:info, "File saved.")}

      {:error, form} ->
        {:noreply, assign(socket, file_form: to_form(form))}
    end
  end

  defp load_files(template_id, user) do
    ProjectTemplateFile
    |> Ash.Query.filter(project_template_id == ^template_id)
    |> Ash.Query.sort(is_directory: :desc, sort_order: :asc, name: :asc)
    |> Ash.read!(actor: user)
  end

  defp build_tree(files) do
    root_files = Enum.filter(files, &is_nil(&1.parent_id))
    Enum.map(root_files, fn file -> build_node(file, files) end)
  end

  defp build_node(file, all_files) do
    children =
      all_files
      |> Enum.filter(&(&1.parent_id == file.id))
      |> Enum.sort_by(fn f -> {!f.is_directory, f.sort_order, f.name} end)
      |> Enum.map(fn child -> build_node(child, all_files) end)

    %{file: file, children: children}
  end

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :tree, build_tree(assigns.files))

    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user} active_page={:templates}>
      <div class="max-w-6xl mx-auto">
        <div class="mb-6">
          <.link
            navigate={~p"/project-templates/#{@template.id}/edit"}
            class="text-sm text-base-content/60 hover:text-base-content transition-colors"
          >
            <.icon name="hero-arrow-left" class="w-4 h-4 inline-block mr-1" /> Back to Template
          </.link>
          <h1 class="text-2xl font-bold tracking-tight mt-2">{@template.name} — Files</h1>
          <p class="mt-2 text-base-content/70">
            Manage the template file tree. Files support Liquid template syntax.
          </p>
        </div>

        <div class="flex gap-4 h-[calc(100vh-220px)]">
          <%!-- File Tree Panel --%>
          <div class="w-72 flex-shrink-0 card bg-base-200 shadow-sm overflow-hidden flex flex-col">
            <div class="p-3 border-b border-base-300 flex items-center justify-between">
              <span class="text-sm font-medium">Files</span>
              <div class="flex items-center gap-1">
                <button
                  phx-click="add_file"
                  class="p-1 rounded hover:bg-base-300 transition-colors"
                  title="Add file"
                >
                  <.icon name="hero-document-plus" class="w-4 h-4" />
                </button>
                <button
                  phx-click="add_folder"
                  class="p-1 rounded hover:bg-base-300 transition-colors"
                  title="Add folder"
                >
                  <.icon name="hero-folder-plus" class="w-4 h-4" />
                </button>
              </div>
            </div>
            <div class="flex-1 overflow-y-auto p-2">
              <%= if @tree == [] do %>
                <p class="text-sm text-base-content/50 text-center py-4">No files yet</p>
              <% else %>
                <.tree_node
                  :for={node <- @tree}
                  node={node}
                  selected_id={@selected_file && @selected_file.id}
                  renaming_id={@renaming_id}
                  depth={0}
                />
              <% end %>
            </div>
          </div>

          <%!-- File Editor Panel --%>
          <div class="flex-1 card bg-base-200 shadow-sm overflow-hidden flex flex-col">
            <%= if @selected_file && @file_form do %>
              <.form
                for={@file_form}
                phx-change="validate_file"
                phx-submit="save_file"
                class="flex flex-col h-full"
              >
                <div class="p-3 border-b border-base-300 flex items-center gap-3">
                  <.input
                    field={@file_form[:name]}
                    placeholder="filename.ext"
                    class="bg-base-100 border-base-300 rounded-lg px-3 py-1.5 text-sm font-mono flex-1"
                  />
                  <.button type="submit" variant="solid" color="primary" size="sm">
                    Save
                  </.button>
                </div>
                <div class="px-3 pt-2 pb-1 flex flex-wrap items-center gap-1.5 text-xs text-base-content/50">
                  <span>Variables:</span>
                  <code
                    :for={
                      var <- ~w(project_name db_host db_port db_name db_test_name db_user db_password)
                    }
                    class="px-1.5 py-0.5 rounded bg-base-300 text-base-content/70 font-mono"
                  >
                    {"{{ #{var} }}"}
                  </code>
                </div>
                <div class="flex-1 px-3 pb-3 min-h-0">
                  <.textarea
                    field={@file_form[:content]}
                    placeholder="File content..."
                    rows={30}
                    class="font-mono text-sm bg-base-300 border-base-300 rounded-lg px-3 py-2 w-full h-full resize-none overflow-y-auto"
                  />
                </div>
              </.form>
            <% else %>
              <div class="flex-1 flex items-center justify-center">
                <div class="text-center">
                  <.icon
                    name="hero-document-text"
                    class="w-10 h-10 text-base-content/30 mx-auto mb-2"
                  />
                  <p class="text-sm text-base-content/50">Select a file to edit</p>
                </div>
              </div>
            <% end %>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  attr :node, :map, required: true
  attr :selected_id, :string, default: nil
  attr :renaming_id, :string, default: nil
  attr :depth, :integer, default: 0

  defp tree_node(assigns) do
    ~H"""
    <div>
      <div
        class={[
          "flex items-center gap-1.5 px-2 py-1 rounded text-sm cursor-pointer transition-colors group",
          if(@node.file.id == @selected_id,
            do: "bg-primary/15 text-base-content",
            else: "hover:bg-base-300 text-base-content/80"
          )
        ]}
        style={"padding-left: #{@depth * 16 + 8}px"}
        phx-click={unless @node.file.is_directory, do: "select_file"}
        phx-value-id={@node.file.id}
      >
        <.icon
          name={if @node.file.is_directory, do: "hero-folder", else: "hero-document"}
          class={[
            "w-4 h-4 flex-shrink-0",
            if(@node.file.is_directory, do: "text-warning", else: "text-base-content/50")
          ]}
        />
        <%= if @node.file.id == @renaming_id do %>
          <form
            phx-submit="save_rename"
            phx-value-id={@node.file.id}
            class="flex-1 flex items-center gap-1"
          >
            <input
              type="text"
              name="name"
              value={@node.file.name}
              id={"rename-input-#{@node.file.id}"}
              phx-hook="FocusAndSelect"
              phx-keydown="cancel_rename"
              phx-key="Escape"
              class="flex-1 px-1.5 py-0.5 text-sm rounded bg-base-100 border border-primary/50 focus:outline-none focus:border-primary"
            />
          </form>
        <% else %>
          <span class="truncate flex-1">{@node.file.name}</span>
          <.dropdown placement="bottom-end">
            <:toggle>
              <button class="p-0.5 rounded hover:bg-base-300 transition-colors hidden group-hover:block">
                <.icon name="hero-ellipsis-horizontal" class="w-4 h-4" />
              </button>
            </:toggle>
            <.dropdown_button
              :if={@node.file.is_directory}
              phx-click="add_file"
              phx-value-parent_id={@node.file.id}
            >
              <.icon name="hero-document-plus" class="w-4 h-4 mr-2" /> New File
            </.dropdown_button>
            <.dropdown_button
              :if={@node.file.is_directory}
              phx-click="add_folder"
              phx-value-parent_id={@node.file.id}
            >
              <.icon name="hero-folder-plus" class="w-4 h-4 mr-2" /> New Folder
            </.dropdown_button>
            <.dropdown_button phx-click="start_rename" phx-value-id={@node.file.id}>
              <.icon name="hero-pencil-square" class="w-4 h-4 mr-2" /> Rename
            </.dropdown_button>
            <.dropdown_separator />
            <.dropdown_button
              phx-click="delete_file"
              phx-value-id={@node.file.id}
              data-confirm="Delete this item?"
              class="text-error"
            >
              <.icon name="hero-trash" class="w-4 h-4 mr-2" /> Delete
            </.dropdown_button>
          </.dropdown>
        <% end %>
      </div>
      <div :if={@node.file.is_directory}>
        <.tree_node
          :for={child <- @node.children}
          node={child}
          selected_id={@selected_id}
          renaming_id={@renaming_id}
          depth={@depth + 1}
        />
      </div>
    </div>
    """
  end
end
