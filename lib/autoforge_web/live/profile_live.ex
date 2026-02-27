defmodule AutoforgeWeb.ProfileLive do
  use AutoforgeWeb, :live_view

  on_mount {AutoforgeWeb.LiveUserAuth, :live_user_required}

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user

    form =
      user
      |> AshPhoenix.Form.for_update(:update_profile,
        actor: user,
        forms: [auto?: true]
      )
      |> to_form()

    timezone_options =
      TzExtra.time_zone_ids()
      |> Enum.map(&{&1, &1})

    api_keys = load_api_keys(user)

    {:ok,
     assign(socket,
       page_title: "Profile",
       form: form,
       timezone_options: timezone_options,
       token_set?: user.github_token != nil,
       ssh_key_set?: user.ssh_public_key != nil,
       ssh_public_key: user.ssh_public_key,
       show_ssh_instructions?: false,
       api_keys: api_keys,
       new_api_key_label: "",
       new_api_key_expires_in: "30",
       newly_created_key: nil,
       show_mcp_instructions?: false,
       mcp_url: AutoforgeWeb.Endpoint.url() <> "/mcp"
     )}
  end

  @impl true
  def handle_event("validate", %{"form" => params}, socket) do
    form =
      socket.assigns.form.source
      |> AshPhoenix.Form.validate(maybe_drop_empty_token(params))
      |> to_form()

    {:noreply, assign(socket, form: form)}
  end

  def handle_event("save", %{"form" => params}, socket) do
    case AshPhoenix.Form.submit(socket.assigns.form.source,
           params: maybe_drop_empty_token(params)
         ) do
      {:ok, user} ->
        form =
          user
          |> AshPhoenix.Form.for_update(:update_profile,
            actor: user,
            forms: [auto?: true]
          )
          |> to_form()

        socket =
          socket
          |> put_flash(:info, "Profile updated successfully.")
          |> assign(form: form, token_set?: user.github_token != nil)

        {:noreply, socket}

      {:error, form} ->
        {:noreply, assign(socket, form: to_form(form))}
    end
  end

  def handle_event("generate_ssh_key", _params, socket) do
    user = socket.assigns.current_user

    case Ash.update(user, %{}, action: :regenerate_ssh_key, actor: user) do
      {:ok, user} ->
        {:noreply,
         socket
         |> assign(
           current_user: user,
           ssh_key_set?: true,
           ssh_public_key: user.ssh_public_key
         )
         |> put_flash(:info, "SSH key generated successfully.")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to generate SSH key.")}
    end
  end

  def handle_event("regenerate_ssh_key", _params, socket) do
    user = socket.assigns.current_user

    case Ash.update(user, %{}, action: :regenerate_ssh_key, actor: user) do
      {:ok, user} ->
        {:noreply,
         socket
         |> assign(
           current_user: user,
           ssh_key_set?: true,
           ssh_public_key: user.ssh_public_key
         )
         |> put_flash(:info, "SSH key regenerated successfully.")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to regenerate SSH key.")}
    end
  end

  def handle_event("toggle_ssh_instructions", _params, socket) do
    {:noreply, assign(socket, show_ssh_instructions?: !socket.assigns.show_ssh_instructions?)}
  end

  def handle_event("toggle_mcp_instructions", _params, socket) do
    {:noreply, assign(socket, show_mcp_instructions?: !socket.assigns.show_mcp_instructions?)}
  end

  def handle_event("update_api_key_form", params, socket) do
    {:noreply,
     assign(socket,
       new_api_key_label: params["label"] || "",
       new_api_key_expires_in: params["expires_in"] || "30"
     )}
  end

  def handle_event("create_api_key", params, socket) do
    user = socket.assigns.current_user
    label = String.trim(params["label"] || "")
    days = String.to_integer(params["expires_in"] || "30")
    expires_at = DateTime.add(DateTime.utc_now(), days, :day)

    case Autoforge.Accounts.ApiKey
         |> Ash.Changeset.for_create(
           :create,
           %{user_id: user.id, label: label, expires_at: expires_at},
           actor: user
         )
         |> Ash.create() do
      {:ok, api_key} ->
        plaintext = api_key.__metadata__.plaintext_api_key

        {:noreply,
         socket
         |> assign(
           api_keys: load_api_keys(user),
           newly_created_key: plaintext,
           new_api_key_label: "",
           new_api_key_expires_in: "30"
         )
         |> put_flash(:info, "API key created. Copy it now — it won't be shown again.")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Failed to create API key.")}
    end
  end

  def handle_event("dismiss_new_key", _params, socket) do
    {:noreply, assign(socket, newly_created_key: nil)}
  end

  def handle_event("delete_api_key", %{"id" => id}, socket) do
    user = socket.assigns.current_user

    case Ash.get(Autoforge.Accounts.ApiKey, id, actor: user) do
      {:ok, api_key} ->
        Ash.destroy!(api_key, actor: user)

        {:noreply,
         socket
         |> assign(api_keys: load_api_keys(user))
         |> put_flash(:info, "API key revoked.")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "API key not found.")}
    end
  end

  defp load_api_keys(user) do
    require Ash.Query

    Autoforge.Accounts.ApiKey
    |> Ash.Query.filter(user_id == ^user.id)
    |> Ash.Query.sort(inserted_at: :desc)
    |> Ash.read!(actor: user)
  end

  defp mcp_json_config(mcp_url) do
    %{
      "mcpServers" => %{
        "autoforge" => %{
          "type" => "streamablehttp",
          "url" => mcp_url,
          "headers" => %{
            "Authorization" => "Bearer YOUR_API_KEY"
          }
        }
      }
    }
    |> Jason.encode!(pretty: true)
  end

  defp maybe_drop_empty_token(params) do
    case params do
      %{"github_token" => ""} -> Map.delete(params, "github_token")
      _ -> params
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user} active_page={:profile}>
      <div>
        <div class="mb-6">
          <h1 class="text-2xl font-bold tracking-tight">Profile Settings</h1>
          <p class="mt-2 text-base-content/70">
            Manage your display name and timezone preferences.
          </p>
        </div>

        <div class="card bg-base-200 shadow-sm">
          <div class="card-body">
            <.form for={@form} phx-change="validate" phx-submit="save" class="space-y-4">
              <.input field={@form[:name]} label="Display Name" placeholder="Enter your name" />

              <.autocomplete
                field={@form[:timezone]}
                label="Timezone"
                options={@timezone_options}
                placeholder="Search for a timezone..."
                search_mode="contains"
                clearable
              />

              <div class="border-t border-base-content/10 pt-4 mt-2">
                <h2 class="text-lg font-semibold mb-1">Integrations</h2>
                <p class="text-sm text-base-content/60 mb-3">
                  Connect external services for enhanced functionality.
                </p>

                <.input
                  field={@form[:github_token]}
                  type="password"
                  label="GitHub Token"
                  placeholder="ghp_xxxxxxxxxxxxxxxxxxxx"
                  autocomplete="off"
                  value=""
                />
                <p class="text-xs text-base-content/50 mt-1">
                  <%= if @token_set? do %>
                    <span class="inline-flex items-center gap-1 text-success">
                      <.icon name="hero-check-circle" class="w-3.5 h-3.5" /> Token configured
                    </span>
                    — leave blank to keep your current token.
                  <% else %>
                    Enter a GitHub fine-grained personal access token.
                  <% end %>
                </p>
              </div>

              <div class="border-t border-base-content/10 pt-4 mt-2">
                <h3 class="text-sm font-semibold mb-1">SSH Key</h3>
                <p class="text-xs text-base-content/60 mb-3">
                  Used for git operations (clone, push) and commit signing inside project containers.
                </p>

                <%= if @ssh_key_set? do %>
                  <div class="space-y-3">
                    <div>
                      <label class="text-xs font-medium text-base-content/70 mb-1 block">
                        Public Key
                      </label>
                      <div class="relative group">
                        <pre class="bg-base-300 rounded-lg p-3 pr-10 text-xs font-mono text-base-content/90 overflow-x-auto whitespace-pre-wrap break-all"><%= @ssh_public_key %></pre>
                        <button
                          type="button"
                          id="copy-ssh-key"
                          phx-hook="CopyToClipboard"
                          data-clipboard-text={@ssh_public_key}
                          data-copied-html="<span class='inline-flex items-center gap-1'><svg xmlns='http://www.w3.org/2000/svg' class='w-4 h-4' viewBox='0 0 20 20' fill='currentColor'><path fill-rule='evenodd' d='M16.704 4.153a.75.75 0 01.143 1.052l-8 10.5a.75.75 0 01-1.127.075l-4.5-4.5a.75.75 0 011.06-1.06l3.894 3.893 7.48-9.817a.75.75 0 011.05-.143z' clip-rule='evenodd'/></svg> Copied</span>"
                          class="absolute top-2 right-2 p-1.5 rounded-md bg-base-100/80 hover:bg-base-100 text-base-content/50 hover:text-base-content transition-all opacity-0 group-hover:opacity-100 cursor-pointer"
                        >
                          <.icon name="hero-clipboard-document" class="w-4 h-4" />
                        </button>
                      </div>
                    </div>

                    <div class="flex items-center gap-2">
                      <button
                        type="button"
                        phx-click="regenerate_ssh_key"
                        data-confirm="This will replace your current SSH key. Existing containers will keep the old key until reprovisioned. Continue?"
                        class="inline-flex items-center gap-1.5 px-3 py-1.5 text-xs font-medium rounded-lg bg-base-300 hover:bg-base-content/20 text-base-content/80 hover:text-base-content transition-colors cursor-pointer"
                      >
                        <.icon name="hero-arrow-path" class="w-3.5 h-3.5" /> Regenerate Key
                      </button>
                    </div>

                    <div>
                      <button
                        type="button"
                        phx-click="toggle_ssh_instructions"
                        class="inline-flex items-center gap-1 text-xs text-primary hover:text-primary/80 transition-colors cursor-pointer"
                      >
                        <.icon
                          name={
                            if @show_ssh_instructions?,
                              do: "hero-chevron-up",
                              else: "hero-chevron-down"
                          }
                          class="w-3.5 h-3.5"
                        />
                        {if @show_ssh_instructions?, do: "Hide", else: "Show"} GitHub setup instructions
                      </button>

                      <%= if @show_ssh_instructions? do %>
                        <div class="mt-2 p-3 bg-base-300/50 rounded-lg text-xs text-base-content/80 space-y-2">
                          <p class="font-semibold">To use this key with GitHub:</p>
                          <ol class="list-decimal list-inside space-y-1.5 ml-1">
                            <li>
                              Copy the public key above
                            </li>
                            <li>
                              Go to
                              <span class="font-mono text-primary">
                                GitHub &rarr; Settings &rarr; SSH and GPG keys
                              </span>
                            </li>
                            <li>
                              Click <span class="font-semibold">New SSH key</span>
                            </li>
                            <li>
                              For <span class="font-semibold">authentication</span>: set Key type to "Authentication Key" and paste your key
                            </li>
                            <li>
                              For <span class="font-semibold">commit signing</span>: add the same key again with Key type set to "Signing Key"
                            </li>
                          </ol>
                          <p class="text-base-content/60 mt-2">
                            Containers are automatically configured for SSH auth and git commit signing.
                          </p>
                        </div>
                      <% end %>
                    </div>
                  </div>
                <% else %>
                  <button
                    type="button"
                    phx-click="generate_ssh_key"
                    class="inline-flex items-center gap-1.5 px-3 py-1.5 text-xs font-medium rounded-lg bg-primary/10 hover:bg-primary/20 text-primary transition-colors cursor-pointer"
                  >
                    <.icon name="hero-key" class="w-3.5 h-3.5" /> Generate SSH Key
                  </button>
                <% end %>
              </div>

              <div class="pt-2">
                <.button type="submit" variant="solid" color="primary">
                  Save Changes
                </.button>
              </div>
            </.form>
          </div>
        </div>

        <div class="card bg-base-200 shadow-sm mt-6">
          <div class="card-body">
            <h2 class="text-lg font-semibold mb-1">API Keys</h2>
            <p class="text-sm text-base-content/60 mb-4">
              Create API keys for programmatic access via the MCP server.
            </p>

            <%= if @newly_created_key do %>
              <div class="mb-4 p-4 rounded-lg bg-success/10 border border-success/30">
                <div class="flex items-start justify-between gap-2">
                  <div class="min-w-0 flex-1">
                    <p class="text-sm font-semibold text-success mb-1">
                      <.icon name="hero-exclamation-triangle" class="w-4 h-4 inline" />
                      Copy your API key now — it won't be shown again
                    </p>
                    <div class="relative group">
                      <pre class="bg-base-300 rounded-lg p-3 pr-10 text-xs font-mono text-base-content/90 overflow-x-auto whitespace-pre-wrap break-all"><%= @newly_created_key %></pre>
                      <button
                        type="button"
                        id="copy-api-key"
                        phx-hook="CopyToClipboard"
                        data-clipboard-text={@newly_created_key}
                        data-copied-html="<span class='inline-flex items-center gap-1'><svg xmlns='http://www.w3.org/2000/svg' class='w-4 h-4' viewBox='0 0 20 20' fill='currentColor'><path fill-rule='evenodd' d='M16.704 4.153a.75.75 0 01.143 1.052l-8 10.5a.75.75 0 01-1.127.075l-4.5-4.5a.75.75 0 011.06-1.06l3.894 3.893 7.48-9.817a.75.75 0 011.05-.143z' clip-rule='evenodd'/></svg> Copied</span>"
                        class="absolute top-2 right-2 p-1.5 rounded-md bg-base-100/80 hover:bg-base-100 text-base-content/50 hover:text-base-content transition-all opacity-0 group-hover:opacity-100 cursor-pointer"
                      >
                        <.icon name="hero-clipboard-document" class="w-4 h-4" />
                      </button>
                    </div>
                  </div>
                  <button
                    type="button"
                    phx-click="dismiss_new_key"
                    class="p-1 text-base-content/40 hover:text-base-content transition-colors cursor-pointer"
                  >
                    <.icon name="hero-x-mark" class="w-4 h-4" />
                  </button>
                </div>
              </div>
            <% end %>

            <form
              phx-change="update_api_key_form"
              phx-submit="create_api_key"
              class="flex items-end gap-3 mb-4"
            >
              <div class="flex-1">
                <label class="text-xs font-medium text-base-content/70 mb-1 block">Label</label>
                <input
                  type="text"
                  name="label"
                  value={@new_api_key_label}
                  placeholder="e.g. Claude Code"
                  required
                  class="w-full px-3 py-2 text-sm rounded-lg bg-base-300 border border-base-content/10 focus:border-primary focus:outline-none transition-colors"
                />
              </div>
              <div class="w-32">
                <label class="text-xs font-medium text-base-content/70 mb-1 block">Expires in</label>
                <select
                  name="expires_in"
                  class="w-full px-3 py-2 text-sm rounded-lg bg-base-300 border border-base-content/10 focus:border-primary focus:outline-none transition-colors"
                >
                  <option value="7" selected={@new_api_key_expires_in == "7"}>7 days</option>
                  <option value="30" selected={@new_api_key_expires_in == "30"}>30 days</option>
                  <option value="90" selected={@new_api_key_expires_in == "90"}>90 days</option>
                  <option value="365" selected={@new_api_key_expires_in == "365"}>1 year</option>
                </select>
              </div>
              <.button type="submit" variant="solid" color="primary" class="whitespace-nowrap">
                <.icon name="hero-plus" class="w-4 h-4 mr-1" /> Create Key
              </.button>
            </form>

            <%= if @api_keys == [] do %>
              <p class="text-sm text-base-content/50 text-center py-4">
                No API keys yet. Create one to use with the MCP server.
              </p>
            <% else %>
              <div class="overflow-x-auto">
                <table class="w-full text-sm">
                  <thead>
                    <tr class="border-b border-base-content/10 text-left text-xs text-base-content/50">
                      <th class="pb-2 font-medium">Label</th>
                      <th class="pb-2 font-medium">Created</th>
                      <th class="pb-2 font-medium">Expires</th>
                      <th class="pb-2 font-medium sr-only">Actions</th>
                    </tr>
                  </thead>
                  <tbody>
                    <tr :for={key <- @api_keys} class="border-b border-base-content/5 last:border-0">
                      <td class="py-2.5 font-medium">{key.label}</td>
                      <td class="py-2.5 text-base-content/60">
                        {Calendar.strftime(key.inserted_at, "%b %d, %Y")}
                      </td>
                      <td class="py-2.5 text-base-content/60">
                        {Calendar.strftime(key.expires_at, "%b %d, %Y")}
                      </td>
                      <td class="py-2.5 text-right">
                        <button
                          type="button"
                          phx-click="delete_api_key"
                          phx-value-id={key.id}
                          data-confirm="Revoke this API key? Any services using it will lose access."
                          class="inline-flex items-center gap-1 px-2 py-1 text-xs rounded-md text-error/70 hover:text-error hover:bg-error/10 transition-colors cursor-pointer"
                        >
                          <.icon name="hero-trash" class="w-3.5 h-3.5" /> Revoke
                        </button>
                      </td>
                    </tr>
                  </tbody>
                </table>
              </div>
            <% end %>

            <div class="mt-4 pt-4 border-t border-base-content/10">
              <button
                type="button"
                phx-click="toggle_mcp_instructions"
                class="inline-flex items-center gap-1 text-xs text-primary hover:text-primary/80 transition-colors cursor-pointer"
              >
                <.icon
                  name={
                    if @show_mcp_instructions?,
                      do: "hero-chevron-up",
                      else: "hero-chevron-down"
                  }
                  class="w-3.5 h-3.5"
                />
                {if @show_mcp_instructions?, do: "Hide", else: "Show"} MCP server setup instructions
              </button>

              <%= if @show_mcp_instructions? do %>
                <div class="mt-3 space-y-4 text-sm">
                  <p class="text-base-content/70">
                    Use your API key to connect Claude to Autoforge's MCP server. The server URL is:
                  </p>
                  <div class="relative group">
                    <pre class="bg-base-300 rounded-lg p-3 pr-10 text-xs font-mono text-base-content/90 overflow-x-auto"><%= @mcp_url %></pre>
                    <button
                      type="button"
                      id="copy-mcp-url"
                      phx-hook="CopyToClipboard"
                      data-clipboard-text={@mcp_url}
                      data-copied-html="<span class='inline-flex items-center gap-1'><svg xmlns='http://www.w3.org/2000/svg' class='w-4 h-4' viewBox='0 0 20 20' fill='currentColor'><path fill-rule='evenodd' d='M16.704 4.153a.75.75 0 01.143 1.052l-8 10.5a.75.75 0 01-1.127.075l-4.5-4.5a.75.75 0 011.06-1.06l3.894 3.893 7.48-9.817a.75.75 0 011.05-.143z' clip-rule='evenodd'/></svg> Copied</span>"
                      class="absolute top-2 right-2 p-1.5 rounded-md bg-base-100/80 hover:bg-base-100 text-base-content/50 hover:text-base-content transition-all opacity-0 group-hover:opacity-100 cursor-pointer"
                    >
                      <.icon name="hero-clipboard-document" class="w-4 h-4" />
                    </button>
                  </div>

                  <%!-- Claude Code --%>
                  <div class="p-4 bg-base-300/50 rounded-lg space-y-3">
                    <h3 class="font-semibold text-sm">Claude Code</h3>
                    <p class="text-xs text-base-content/70">
                      Add the following to your project's
                      <span class="font-mono text-primary">.mcp.json</span>
                      file (create it in the project root if it doesn't exist):
                    </p>
                    <div class="relative group">
                      <pre class="bg-base-300 rounded-lg p-3 pr-10 text-xs font-mono text-base-content/90 overflow-x-auto"><%= mcp_json_config(@mcp_url) %></pre>
                      <button
                        type="button"
                        id="copy-claude-code-config"
                        phx-hook="CopyToClipboard"
                        data-clipboard-text={mcp_json_config(@mcp_url)}
                        data-copied-html="<span class='inline-flex items-center gap-1'><svg xmlns='http://www.w3.org/2000/svg' class='w-4 h-4' viewBox='0 0 20 20' fill='currentColor'><path fill-rule='evenodd' d='M16.704 4.153a.75.75 0 01.143 1.052l-8 10.5a.75.75 0 01-1.127.075l-4.5-4.5a.75.75 0 011.06-1.06l3.894 3.893 7.48-9.817a.75.75 0 011.05-.143z' clip-rule='evenodd'/></svg> Copied</span>"
                        class="absolute top-2 right-2 p-1.5 rounded-md bg-base-100/80 hover:bg-base-100 text-base-content/50 hover:text-base-content transition-all opacity-0 group-hover:opacity-100 cursor-pointer"
                      >
                        <.icon name="hero-clipboard-document" class="w-4 h-4" />
                      </button>
                    </div>
                    <p class="text-xs text-base-content/60">
                      This works the same on macOS, Windows, and Linux &mdash; including dev sandboxes.
                      Replace <span class="font-mono">YOUR_API_KEY</span>
                      with the key you copied above.
                    </p>
                  </div>

                  <%!-- Claude Desktop --%>
                  <div class="p-4 bg-base-300/50 rounded-lg space-y-3">
                    <h3 class="font-semibold text-sm">Claude Desktop</h3>
                    <p class="text-xs text-base-content/70">
                      Add the following to your Claude Desktop config file:
                    </p>
                    <div class="relative group">
                      <pre class="bg-base-300 rounded-lg p-3 pr-10 text-xs font-mono text-base-content/90 overflow-x-auto"><%= mcp_json_config(@mcp_url) %></pre>
                      <button
                        type="button"
                        id="copy-claude-desktop-config"
                        phx-hook="CopyToClipboard"
                        data-clipboard-text={mcp_json_config(@mcp_url)}
                        data-copied-html="<span class='inline-flex items-center gap-1'><svg xmlns='http://www.w3.org/2000/svg' class='w-4 h-4' viewBox='0 0 20 20' fill='currentColor'><path fill-rule='evenodd' d='M16.704 4.153a.75.75 0 01.143 1.052l-8 10.5a.75.75 0 01-1.127.075l-4.5-4.5a.75.75 0 011.06-1.06l3.894 3.893 7.48-9.817a.75.75 0 011.05-.143z' clip-rule='evenodd'/></svg> Copied</span>"
                        class="absolute top-2 right-2 p-1.5 rounded-md bg-base-100/80 hover:bg-base-100 text-base-content/50 hover:text-base-content transition-all opacity-0 group-hover:opacity-100 cursor-pointer"
                      >
                        <.icon name="hero-clipboard-document" class="w-4 h-4" />
                      </button>
                    </div>
                    <div class="text-xs text-base-content/60 space-y-1.5">
                      <p class="font-medium text-base-content/70">Config file location:</p>
                      <ul class="space-y-1 ml-1">
                        <li>
                          <span class="font-semibold">macOS:</span>
                          <span class="font-mono text-primary break-all">
                            ~/Library/Application Support/Claude/claude_desktop_config.json
                          </span>
                        </li>
                        <li>
                          <span class="font-semibold">Windows:</span>
                          <span class="font-mono text-primary break-all">
                            %APPDATA%\Claude\claude_desktop_config.json
                          </span>
                        </li>
                      </ul>
                    </div>
                  </div>
                </div>
              <% end %>
            </div>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
