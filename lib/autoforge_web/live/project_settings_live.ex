defmodule AutoforgeWeb.ProjectSettingsLive do
  use AutoforgeWeb, :live_view

  alias Autoforge.GitHub.RepoSetup
  alias Autoforge.Projects.Project

  require Ash.Query

  on_mount {AutoforgeWeb.LiveUserAuth, :live_user_required}

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    user = socket.assigns.current_user

    project =
      Project
      |> Ash.Query.filter(id == ^id)
      |> Ash.read_one!(actor: user)

    if project do
      github_token = user.github_token
      has_token = github_token != nil and github_token != ""
      has_repo = project.github_repo_owner != nil and project.github_repo_name != nil

      {:ok,
       assign(socket,
         page_title: "#{project.name} — Settings",
         project: project,
         github_token_available: has_token,
         github_repo_linked: has_repo,
         github_mode: if(has_repo, do: :linked, else: :none),
         github_new_repo_name: "",
         github_new_repo_org: "",
         github_new_repo_private: true,
         github_link_owner: "",
         github_link_repo: "",
         github_loading: false
       )}
    else
      {:ok,
       socket
       |> put_flash(:error, "Project not found.")
       |> push_navigate(to: ~p"/projects")}
    end
  end

  @impl true
  def handle_event("github_set_mode", %{"mode" => mode}, socket) do
    {:noreply, assign(socket, github_mode: String.to_existing_atom(mode))}
  end

  def handle_event("github_update_fields", params, socket) do
    assigns =
      []
      |> then(fn a ->
        if params["new_repo_name"],
          do: [{:github_new_repo_name, params["new_repo_name"]} | a],
          else: a
      end)
      |> then(fn a ->
        if params["new_repo_org"],
          do: [{:github_new_repo_org, params["new_repo_org"]} | a],
          else: a
      end)
      |> then(fn a ->
        if params["link_owner"], do: [{:github_link_owner, params["link_owner"]} | a], else: a
      end)
      |> then(fn a ->
        if params["link_repo"], do: [{:github_link_repo, params["link_repo"]} | a], else: a
      end)

    {:noreply, assign(socket, assigns)}
  end

  def handle_event("github_toggle_private", _params, socket) do
    {:noreply, assign(socket, github_new_repo_private: !socket.assigns.github_new_repo_private)}
  end

  def handle_event("github_create_repo", _params, socket) do
    socket = assign(socket, github_loading: true)
    user = socket.assigns.current_user
    project = socket.assigns.project
    repo_name = String.trim(socket.assigns.github_new_repo_name)
    org = String.trim(socket.assigns.github_new_repo_org)
    org_arg = if org != "", do: org

    case RepoSetup.create_and_link(
           project,
           user.github_token,
           repo_name,
           org_arg,
           private: socket.assigns.github_new_repo_private
         ) do
      {:ok, %{owner: owner, repo: repo}} ->
        project = reload_project(project.id, user)

        {:noreply,
         socket
         |> assign(
           project: project,
           github_repo_linked: true,
           github_mode: :linked,
           github_loading: false
         )
         |> put_flash(:info, "Created and linked #{owner}/#{repo}")}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(github_loading: false)
         |> put_flash(:error, "Failed to create repo: #{reason}")}
    end
  end

  def handle_event("github_link_existing", _params, socket) do
    socket = assign(socket, github_loading: true)
    user = socket.assigns.current_user
    project = socket.assigns.project
    owner = String.trim(socket.assigns.github_link_owner)
    repo = String.trim(socket.assigns.github_link_repo)

    case RepoSetup.link_existing(project, user.github_token, owner, repo) do
      {:ok, _} ->
        project = reload_project(project.id, user)

        {:noreply,
         socket
         |> assign(
           project: project,
           github_repo_linked: true,
           github_mode: :linked,
           github_loading: false
         )
         |> put_flash(:info, "Linked #{owner}/#{repo}")}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(github_loading: false)
         |> put_flash(:error, "Failed to link repo: #{reason}")}
    end
  end

  def handle_event("github_unlink", _params, socket) do
    project = socket.assigns.project

    case project
         |> Ash.Changeset.for_update(:unlink_github_repo, %{}, authorize?: false)
         |> Ash.update() do
      {:ok, project} ->
        {:noreply,
         socket
         |> assign(
           project: project,
           github_repo_linked: false,
           github_mode: :none
         )
         |> put_flash(:info, "GitHub repository unlinked.")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to unlink repository.")}
    end
  end

  def handle_event("github_push", _params, socket) do
    socket = assign(socket, github_loading: true)

    case RepoSetup.initial_push(socket.assigns.project.container_id) do
      :ok ->
        {:noreply,
         socket
         |> assign(github_loading: false)
         |> put_flash(:info, "Pushed to remote.")}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(github_loading: false)
         |> put_flash(:error, "Push failed: #{reason}")}
    end
  end

  defp reload_project(project_id, user) do
    Project
    |> Ash.Query.filter(id == ^project_id)
    |> Ash.read_one!(actor: user)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user} active_page={:projects}>
      <div>
        <div class="mb-6">
          <.link
            navigate={~p"/projects/#{@project.id}"}
            class="inline-flex items-center gap-1 text-sm text-base-content/50 hover:text-base-content transition-colors mb-3"
          >
            <.icon name="hero-arrow-left" class="w-4 h-4" /> Back to project
          </.link>
          <h1 class="text-2xl font-bold tracking-tight">{@project.name} — Settings</h1>
          <p class="mt-2 text-base-content/70">
            Configure project-specific settings.
          </p>
        </div>

        <%!-- GitHub Repository Section --%>
        <div class="card bg-base-200 shadow-sm mb-6">
          <div class="card-body">
            <h2 class="card-title text-lg">
              <.icon name="hero-code-bracket" class="w-5 h-5" /> GitHub Repository
            </h2>

            <%= if !@github_token_available do %>
              <p class="text-sm text-base-content/60 mt-2">
                Set your GitHub token in
                <.link navigate={~p"/profile"} class="text-primary hover:underline">
                  Profile settings
                </.link>
                to connect a repository.
              </p>
            <% else %>
              <%= if @github_mode == :linked do %>
                <div class="mt-3 space-y-3">
                  <div class="flex items-center gap-2">
                    <.icon name="hero-check-circle" class="w-5 h-5 text-success" />
                    <.link
                      href={"https://github.com/#{@project.github_repo_owner}/#{@project.github_repo_name}"}
                      target="_blank"
                      class="text-primary hover:underline font-medium"
                    >
                      {@project.github_repo_owner}/{@project.github_repo_name}
                    </.link>
                  </div>

                  <div class="flex items-center gap-2">
                    <.button
                      variant="outline"
                      size="sm"
                      phx-click="github_push"
                      disabled={@github_loading}
                    >
                      <.icon name="hero-arrow-up-tray" class="w-4 h-4 mr-1" /> Push to Remote
                    </.button>
                    <.button
                      variant="ghost"
                      size="sm"
                      phx-click="github_unlink"
                      data-confirm="Unlink this GitHub repository? The remote will not be removed from the container."
                      class="text-error"
                    >
                      <.icon name="hero-x-mark" class="w-4 h-4 mr-1" /> Unlink
                    </.button>
                  </div>
                </div>
              <% else %>
                <div class="mt-3 space-y-4">
                  <div class="flex gap-2">
                    <.button
                      variant={if @github_mode == :create, do: "solid", else: "outline"}
                      size="sm"
                      phx-click="github_set_mode"
                      phx-value-mode="create"
                    >
                      Create New Repo
                    </.button>
                    <.button
                      variant={if @github_mode == :link, do: "solid", else: "outline"}
                      size="sm"
                      phx-click="github_set_mode"
                      phx-value-mode="link"
                    >
                      Link Existing Repo
                    </.button>
                  </div>

                  <%!-- Create New Repo Form --%>
                  <form
                    :if={@github_mode == :create}
                    phx-change="github_update_fields"
                    phx-submit="github_create_repo"
                    class="space-y-3"
                  >
                    <div>
                      <label class="text-sm font-medium text-base-content/70">Repository Name</label>
                      <input
                        type="text"
                        name="new_repo_name"
                        value={@github_new_repo_name}
                        placeholder="my-project"
                        class="input input-bordered input-sm w-full mt-1"
                      />
                    </div>

                    <div>
                      <label class="text-sm font-medium text-base-content/70">
                        Organization (optional)
                      </label>
                      <input
                        type="text"
                        name="new_repo_org"
                        value={@github_new_repo_org}
                        placeholder="Leave blank for personal account"
                        class="input input-bordered input-sm w-full mt-1"
                      />
                    </div>

                    <div class="flex items-center gap-2">
                      <input
                        type="checkbox"
                        id="settings-github-private"
                        checked={@github_new_repo_private}
                        phx-click="github_toggle_private"
                        class="checkbox checkbox-sm checkbox-primary"
                      />
                      <label for="settings-github-private" class="text-sm cursor-pointer">
                        Private repository
                      </label>
                    </div>

                    <.button
                      type="submit"
                      variant="solid"
                      color="primary"
                      size="sm"
                      disabled={@github_loading || String.trim(@github_new_repo_name) == ""}
                    >
                      <span
                        :if={@github_loading}
                        class="loading loading-spinner loading-xs mr-1"
                      /> Create & Link Repository
                    </.button>
                  </form>

                  <%!-- Link Existing Repo Form --%>
                  <form
                    :if={@github_mode == :link}
                    phx-change="github_update_fields"
                    phx-submit="github_link_existing"
                    class="space-y-3"
                  >
                    <div>
                      <label class="text-sm font-medium text-base-content/70">Owner</label>
                      <input
                        type="text"
                        name="link_owner"
                        value={@github_link_owner}
                        placeholder="username or org"
                        class="input input-bordered input-sm w-full mt-1"
                      />
                    </div>

                    <div>
                      <label class="text-sm font-medium text-base-content/70">Repository Name</label>
                      <input
                        type="text"
                        name="link_repo"
                        value={@github_link_repo}
                        placeholder="repo-name"
                        class="input input-bordered input-sm w-full mt-1"
                      />
                    </div>

                    <.button
                      type="submit"
                      variant="solid"
                      color="primary"
                      size="sm"
                      disabled={
                        @github_loading || String.trim(@github_link_owner) == "" ||
                          String.trim(@github_link_repo) == ""
                      }
                    >
                      <span
                        :if={@github_loading}
                        class="loading loading-spinner loading-xs mr-1"
                      /> Link Repository
                    </.button>
                  </form>
                </div>
              <% end %>
            <% end %>
          </div>
        </div>

        <.live_component
          module={AutoforgeWeb.ProjectEnvVarsComponent}
          id="env-vars"
          project={@project}
          project_id={@project.id}
          current_user={@current_user}
        />
      </div>
    </Layouts.app>
    """
  end
end
