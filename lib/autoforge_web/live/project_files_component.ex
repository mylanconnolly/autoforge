defmodule AutoforgeWeb.ProjectFilesComponent do
  use AutoforgeWeb, :live_component

  alias Autoforge.Projects.{ProjectFile, ProjectFiles}

  require Ash.Query

  @impl true
  def mount(socket) do
    {:ok,
     assign(socket,
       files: [],
       sidebar_open: false,
       preview_file: nil,
       preview_content: nil
     )}
  end

  @impl true
  def update(assigns, socket) do
    socket = assign(socket, assigns)

    socket =
      if socket.assigns[:uploads] == nil || !Map.has_key?(socket.assigns.uploads, :files) do
        allow_upload(socket, :files,
          accept: :any,
          max_entries: 10,
          max_file_size: 50_000_000,
          chunk_size: 256_000
        )
      else
        socket
      end

    files = load_files(assigns.project.id)
    {:ok, assign(socket, files: files)}
  end

  @impl true
  def handle_event("toggle_sidebar", _params, socket) do
    {:noreply, assign(socket, sidebar_open: !socket.assigns.sidebar_open)}
  end

  def handle_event("validate", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("save", _params, socket) do
    project = socket.assigns.project
    actor = socket.assigns.current_user

    consume_uploaded_entries(socket, :files, fn %{path: path}, entry ->
      content = File.read!(path)

      case ProjectFiles.upload(
             project,
             entry.client_name,
             content,
             entry.client_type,
             actor: actor
           ) do
        {:ok, file} -> {:ok, file}
        {:error, reason} -> {:postpone, reason}
      end
    end)

    files = load_files(project.id)
    {:noreply, assign(socket, files: files)}
  end

  def handle_event("delete", %{"id" => id}, socket) do
    actor = socket.assigns.current_user

    file =
      ProjectFile
      |> Ash.Query.filter(id == ^id)
      |> Ash.read_one!(actor: actor)

    if file do
      ProjectFiles.delete(file, actor: actor)
    end

    files = load_files(socket.assigns.project.id)
    {:noreply, assign(socket, files: files)}
  end

  def handle_event("preview", %{"id" => id}, socket) do
    actor = socket.assigns.current_user

    file =
      ProjectFile
      |> Ash.Query.filter(id == ^id)
      |> Ash.read_one!(actor: actor)

    preview_content =
      if file && text_previewable?(file.content_type, file.filename) do
        case ProjectFiles.download(file) do
          {:ok, content} -> content
          _ -> nil
        end
      end

    {:noreply, assign(socket, preview_file: file, preview_content: preview_content)}
  end

  def handle_event("close_preview", _params, socket) do
    {:noreply, assign(socket, preview_file: nil, preview_content: nil)}
  end

  def handle_event("cancel-upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :files, ref)}
  end

  defp load_files(project_id) do
    ProjectFile
    |> Ash.Query.filter(project_id == ^project_id)
    |> Ash.Query.sort(inserted_at: :desc)
    |> Ash.read!(authorize?: false)
  end

  defp text_previewable?(content_type, filename) do
    cond do
      String.starts_with?(content_type, "text/") -> true
      content_type == "application/json" -> true
      content_type == "application/xml" -> true
      String.ends_with?(filename, ".md") -> true
      String.ends_with?(filename, ".ex") -> true
      String.ends_with?(filename, ".exs") -> true
      String.ends_with?(filename, ".js") -> true
      String.ends_with?(filename, ".ts") -> true
      String.ends_with?(filename, ".css") -> true
      String.ends_with?(filename, ".html") -> true
      String.ends_with?(filename, ".yml") -> true
      String.ends_with?(filename, ".yaml") -> true
      String.ends_with?(filename, ".toml") -> true
      String.ends_with?(filename, ".sh") -> true
      String.ends_with?(filename, ".sql") -> true
      true -> false
    end
  end

  defp image_type?(content_type), do: String.starts_with?(content_type, "image/")

  defp pdf_type?(content_type), do: content_type == "application/pdf"

  defp format_file_size(bytes) when bytes < 1_024, do: "#{bytes} B"
  defp format_file_size(bytes) when bytes < 1_048_576, do: "#{Float.round(bytes / 1_024, 1)} KB"
  defp format_file_size(bytes), do: "#{Float.round(bytes / 1_048_576, 1)} MB"

  defp file_icon(content_type, filename) do
    cond do
      image_type?(content_type) -> "hero-photo"
      pdf_type?(content_type) -> "hero-document"
      text_previewable?(content_type, filename) -> "hero-code-bracket"
      true -> "hero-paper-clip"
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="absolute inset-0 pointer-events-none z-20">
      <%!-- Toggle button --%>
      <button
        phx-click="toggle_sidebar"
        phx-target={@myself}
        class={[
          "pointer-events-auto absolute right-0 top-1/2 -translate-y-1/2 z-30",
          "flex items-center gap-1 px-1.5 py-3 rounded-l-lg",
          "bg-base-200/90 backdrop-blur border border-r-0 border-base-300",
          "text-base-content/60 hover:text-base-content hover:bg-base-200",
          "transition-all duration-200 cursor-pointer shadow-sm",
          if(@sidebar_open, do: "translate-x-full opacity-0", else: "translate-x-0 opacity-100")
        ]}
        title="Toggle files sidebar"
      >
        <.icon name="hero-folder" class="w-4 h-4" />
        <span
          :if={length(@files) > 0}
          class="absolute -top-1.5 -left-1.5 flex items-center justify-center w-4 h-4 text-[10px] font-bold bg-primary text-primary-content rounded-full"
        >
          {length(@files)}
        </span>
      </button>

      <%!-- Sidebar panel --%>
      <div class={[
        "pointer-events-auto absolute right-0 top-0 bottom-0 w-80",
        "bg-base-100 border-l border-base-300 shadow-xl",
        "flex flex-col transition-transform duration-300 ease-in-out",
        unless(@sidebar_open, do: "translate-x-full")
      ]}>
        <%!-- Header --%>
        <div class="flex items-center justify-between px-4 py-3 border-b border-base-300 flex-shrink-0">
          <div class="flex items-center gap-2">
            <.icon name="hero-folder" class="w-4 h-4 text-base-content/60" />
            <span class="text-sm font-semibold">Files</span>
            <span
              :if={length(@files) > 0}
              class="badge badge-sm badge-neutral"
            >
              {length(@files)}
            </span>
          </div>
          <button
            phx-click="toggle_sidebar"
            phx-target={@myself}
            class="p-1 rounded hover:bg-base-200 text-base-content/50 hover:text-base-content transition-colors cursor-pointer"
          >
            <.icon name="hero-x-mark" class="w-4 h-4" />
          </button>
        </div>

        <%!-- Upload area --%>
        <div class="px-4 py-3 border-b border-base-300 flex-shrink-0">
          <form phx-change="validate" phx-submit="save" phx-target={@myself}>
            <div
              id="drop-zone"
              phx-hook="DropZone"
              phx-drop-target={@uploads.files.ref}
              class="relative border-2 border-dashed border-base-300 rounded-lg p-4 text-center hover:border-primary/50 transition-colors cursor-pointer group"
            >
              <label class="cursor-pointer flex flex-col items-center gap-1.5">
                <.icon
                  name="hero-cloud-arrow-up"
                  class="w-6 h-6 text-base-content/30 group-hover:text-primary/50 transition-colors"
                />
                <span class="text-xs text-base-content/50">
                  Drop files here or click to browse
                </span>
                <.live_file_input upload={@uploads.files} class="hidden" />
              </label>
            </div>

            <%!-- Upload entries --%>
            <div :if={@uploads.files.entries != []} class="mt-3 space-y-2">
              <div
                :for={entry <- @uploads.files.entries}
                class="flex items-center gap-2 text-xs"
              >
                <div class="flex-1 min-w-0">
                  <div class="truncate text-base-content/80">{entry.client_name}</div>
                  <div class="w-full bg-base-200 rounded-full h-1 mt-1">
                    <div
                      class="bg-primary h-1 rounded-full transition-all duration-300"
                      style={"width: #{entry.progress}%"}
                    />
                  </div>
                </div>
                <button
                  type="button"
                  phx-click="cancel-upload"
                  phx-value-ref={entry.ref}
                  phx-target={@myself}
                  class="p-0.5 rounded hover:bg-base-200 text-base-content/40 hover:text-error transition-colors flex-shrink-0 cursor-pointer"
                >
                  <.icon name="hero-x-mark" class="w-3 h-3" />
                </button>
              </div>
              <.button type="submit" size="xs" class="w-full mt-1">
                Upload {length(@uploads.files.entries)} file{if length(@uploads.files.entries) > 1,
                  do: "s"}
              </.button>
            </div>

            <%!-- Upload errors --%>
            <div :for={err <- upload_errors(@uploads.files)} class="mt-2 text-xs text-error">
              {upload_error_to_string(err)}
            </div>
          </form>
        </div>

        <%!-- File list --%>
        <div class="flex-1 min-h-0 overflow-y-auto">
          <div :if={@files == []} class="flex items-center justify-center h-full text-base-content/30">
            <div class="text-center">
              <.icon name="hero-folder-open" class="w-8 h-8 mx-auto mb-2" />
              <p class="text-xs">No files uploaded</p>
            </div>
          </div>

          <div :for={file <- @files} class="group">
            <div class="flex items-center gap-2.5 px-4 py-2.5 hover:bg-base-200/50 transition-colors">
              <.icon
                name={file_icon(file.content_type, file.filename)}
                class="w-4 h-4 text-base-content/40 flex-shrink-0"
              />
              <div class="flex-1 min-w-0">
                <button
                  phx-click="preview"
                  phx-value-id={file.id}
                  phx-target={@myself}
                  class="block text-xs font-medium text-base-content hover:text-primary truncate w-full text-left transition-colors cursor-pointer"
                  title={file.filename}
                >
                  {file.filename}
                </button>
                <span class="text-[10px] text-base-content/40">{format_file_size(file.size)}</span>
              </div>
              <div class="flex items-center gap-1 flex-shrink-0 opacity-0 group-hover:opacity-100 transition-opacity">
                <button
                  id={"copy-path-#{file.id}"}
                  phx-hook="CopyToClipboard"
                  data-clipboard-text={"/uploads/#{file.filename}"}
                  data-copied-html={"<span class='text-success'><svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 20 20' fill='currentColor' class='w-3.5 h-3.5'><path fill-rule='evenodd' d='M16.704 4.153a.75.75 0 01.143 1.052l-8 10.5a.75.75 0 01-1.127.075l-4.5-4.5a.75.75 0 011.06-1.06l3.894 3.893 7.48-9.817a.75.75 0 011.05-.143z' clip-rule='evenodd' /></svg></span>"}
                  class="p-1 rounded hover:bg-base-300 text-base-content/40 hover:text-base-content transition-colors cursor-pointer"
                  title="Copy sandbox path"
                >
                  <.icon name="hero-clipboard-document" class="w-3.5 h-3.5" />
                </button>
                <a
                  href={~p"/projects/#{file.project_id}/files/#{file.id}"}
                  download={file.filename}
                  class="p-1 rounded hover:bg-base-300 text-base-content/40 hover:text-base-content transition-colors"
                  title="Download"
                >
                  <.icon name="hero-arrow-down-tray" class="w-3.5 h-3.5" />
                </a>
                <button
                  phx-click="delete"
                  phx-value-id={file.id}
                  phx-target={@myself}
                  data-confirm="Delete this file?"
                  class="p-1 rounded hover:bg-error/10 text-base-content/40 hover:text-error transition-colors cursor-pointer"
                  title="Delete"
                >
                  <.icon name="hero-trash" class="w-3.5 h-3.5" />
                </button>
              </div>
            </div>
          </div>
        </div>
      </div>

      <%!-- Preview modal --%>
      <.modal
        :if={@preview_file}
        id="file-preview-modal"
        open
        on_close={JS.push("close_preview", target: @myself)}
        class="w-[700px] max-h-[80vh]"
      >
        <div class="flex flex-col max-h-[80vh]">
          <%!-- Preview header --%>
          <div class="flex items-center justify-between px-6 py-4 border-b border-base-200 flex-shrink-0">
            <div class="flex items-center gap-2 min-w-0">
              <.icon
                name={file_icon(@preview_file.content_type, @preview_file.filename)}
                class="w-5 h-5 text-base-content/50 flex-shrink-0"
              />
              <div class="min-w-0">
                <h3 class="text-sm font-semibold truncate">{@preview_file.filename}</h3>
                <p class="text-xs text-base-content/50">
                  {format_file_size(@preview_file.size)} &middot; {@preview_file.content_type}
                </p>
              </div>
            </div>
            <a
              href={~p"/projects/#{@preview_file.project_id}/files/#{@preview_file.id}"}
              download={@preview_file.filename}
              class="btn btn-sm btn-ghost gap-1"
            >
              <.icon name="hero-arrow-down-tray" class="w-4 h-4" /> Download
            </a>
          </div>

          <%!-- Preview content --%>
          <div class="flex-1 min-h-0 overflow-auto p-6">
            <%!-- Image preview --%>
            <div
              :if={image_type?(@preview_file.content_type)}
              class="flex items-center justify-center"
            >
              <img
                src={~p"/projects/#{@preview_file.project_id}/files/#{@preview_file.id}"}
                alt={@preview_file.filename}
                class="max-w-full max-h-[60vh] object-contain rounded"
              />
            </div>

            <%!-- PDF preview --%>
            <div :if={pdf_type?(@preview_file.content_type)} class="h-[60vh]">
              <iframe
                src={~p"/projects/#{@preview_file.project_id}/files/#{@preview_file.id}"}
                class="w-full h-full rounded border border-base-200"
              />
            </div>

            <%!-- Text/code preview --%>
            <div
              :if={
                @preview_content &&
                  text_previewable?(@preview_file.content_type, @preview_file.filename)
              }
              class="bg-base-200/50 rounded-lg"
            >
              <pre class="p-4 text-xs font-mono text-base-content/80 overflow-auto max-h-[60vh] whitespace-pre-wrap break-words"><code>{@preview_content}</code></pre>
            </div>

            <%!-- Unsupported type --%>
            <div
              :if={
                !image_type?(@preview_file.content_type) &&
                  !pdf_type?(@preview_file.content_type) &&
                  !text_previewable?(@preview_file.content_type, @preview_file.filename)
              }
              class="flex flex-col items-center justify-center py-12 text-base-content/40"
            >
              <.icon name="hero-document" class="w-12 h-12 mb-3" />
              <p class="text-sm">Preview not available for this file type</p>
              <a
                href={~p"/projects/#{@preview_file.project_id}/files/#{@preview_file.id}"}
                download={@preview_file.filename}
                class="btn btn-sm btn-primary mt-4"
              >
                <.icon name="hero-arrow-down-tray" class="w-4 h-4" /> Download File
              </a>
            </div>
          </div>
        </div>
      </.modal>
    </div>
    """
  end

  defp upload_error_to_string(:too_large), do: "File is too large (max 50 MB)"
  defp upload_error_to_string(:too_many_files), do: "Too many files (max 10 at once)"
  defp upload_error_to_string(:not_accepted), do: "File type not accepted"
  defp upload_error_to_string(err), do: "Upload error: #{inspect(err)}"
end
