defmodule Autoforge.Ai.ToolRegistry do
  @moduledoc """
  Maps tool name strings to `ReqLLM.Tool` structs with executable callbacks.

  Tools are code-defined; the database `tools` table exists only for
  join/UI purposes. This module is the source of truth for what each
  tool actually does at runtime.
  """

  @max_body_bytes 50_000
  @max_meta_redirects 3

  @doc "Returns all registered tools as a map of name => ReqLLM.Tool."
  @spec all() :: %{String.t() => ReqLLM.Tool.t()}
  def all, do: tools()

  @doc "Returns a single ReqLLM.Tool by name, or nil."
  @spec get(String.t()) :: ReqLLM.Tool.t() | nil
  def get(name), do: Map.get(tools(), name)

  @doc "Returns a list of ReqLLM.Tool structs for the given names."
  @spec get_many([String.t()]) :: [ReqLLM.Tool.t()]
  def get_many(names) do
    registry = tools()

    names
    |> Enum.map(&Map.get(registry, &1))
    |> Enum.reject(&is_nil/1)
  end

  defp tools do
    %{
      "get_time" =>
        ReqLLM.Tool.new!(
          name: "get_time",
          description: "Get the current UTC time in ISO8601 format.",
          parameter_schema: [],
          callback: fn _args ->
            {:ok, DateTime.utc_now() |> DateTime.to_iso8601()}
          end
        ),
      "get_url" =>
        ReqLLM.Tool.new!(
          name: "get_url",
          description: "Fetch the contents of a URL via HTTP GET.",
          parameter_schema: [
            url: [type: :string, required: true, doc: "The URL to fetch"]
          ],
          callback: fn %{url: url} ->
            fetch_url(url, @max_meta_redirects)
          end
        ),
      "delegate_task" =>
        ReqLLM.Tool.new!(
          name: "delegate_task",
          description: """
          Delegate a task or question to another bot you have access to. \
          The bot will process the request (with full tool access) and return its response. \
          Use this whenever another bot's expertise would help — whether you need code written, \
          a question answered, an architecture reviewed, a test designed, or any other task \
          that falls within another bot's specialty. \
          When a user asks you to consult, ask, or involve another bot by name, use this tool.\
          """,
          parameter_schema: [
            bot_name: [
              type: :string,
              required: true,
              doc: "Name of the bot to delegate to"
            ],
            task: [
              type: :string,
              required: true,
              doc: "Clear description of what the bot should do"
            ]
          ],
          callback: fn _args ->
            {:error, "delegate_task requires conversation context — this is a bug"}
          end
        ),

      # ── GitHub Tools ──────────────────────────────────────────────────────

      "github_get_repo" =>
        ReqLLM.Tool.new!(
          name: "github_get_repo",
          description: "Get information about a GitHub repository.",
          parameter_schema: [
            owner: [type: :string, required: true, doc: "Repository owner (user or org)"],
            repo: [type: :string, required: true, doc: "Repository name"]
          ],
          callback: &github_not_available/1
        ),
      "github_list_issues" =>
        ReqLLM.Tool.new!(
          name: "github_list_issues",
          description: "List issues in a GitHub repository. Returns open issues by default.",
          parameter_schema: [
            owner: [type: :string, required: true, doc: "Repository owner"],
            repo: [type: :string, required: true, doc: "Repository name"],
            state: [type: :string, doc: "Filter by state: open, closed, or all (default: open)"]
          ],
          callback: &github_not_available/1
        ),
      "github_create_issue" =>
        ReqLLM.Tool.new!(
          name: "github_create_issue",
          description: "Create a new issue in a GitHub repository.",
          parameter_schema: [
            owner: [type: :string, required: true, doc: "Repository owner"],
            repo: [type: :string, required: true, doc: "Repository name"],
            title: [type: :string, required: true, doc: "Issue title"],
            body: [type: :string, required: true, doc: "Issue body (Markdown)"]
          ],
          callback: &github_not_available/1
        ),
      "github_get_issue" =>
        ReqLLM.Tool.new!(
          name: "github_get_issue",
          description: "Get details of a specific GitHub issue by number.",
          parameter_schema: [
            owner: [type: :string, required: true, doc: "Repository owner"],
            repo: [type: :string, required: true, doc: "Repository name"],
            number: [type: :integer, required: true, doc: "Issue number"]
          ],
          callback: &github_not_available/1
        ),
      "github_comment_on_issue" =>
        ReqLLM.Tool.new!(
          name: "github_comment_on_issue",
          description: "Add a comment to a GitHub issue or pull request.",
          parameter_schema: [
            owner: [type: :string, required: true, doc: "Repository owner"],
            repo: [type: :string, required: true, doc: "Repository name"],
            number: [type: :integer, required: true, doc: "Issue or PR number"],
            body: [type: :string, required: true, doc: "Comment body (Markdown)"]
          ],
          callback: &github_not_available/1
        ),
      "github_list_pull_requests" =>
        ReqLLM.Tool.new!(
          name: "github_list_pull_requests",
          description: "List pull requests in a GitHub repository. Returns open PRs by default.",
          parameter_schema: [
            owner: [type: :string, required: true, doc: "Repository owner"],
            repo: [type: :string, required: true, doc: "Repository name"],
            state: [type: :string, doc: "Filter by state: open, closed, or all (default: open)"]
          ],
          callback: &github_not_available/1
        ),
      "github_create_pull_request" =>
        ReqLLM.Tool.new!(
          name: "github_create_pull_request",
          description: "Create a new pull request in a GitHub repository.",
          parameter_schema: [
            owner: [type: :string, required: true, doc: "Repository owner"],
            repo: [type: :string, required: true, doc: "Repository name"],
            title: [type: :string, required: true, doc: "PR title"],
            body: [type: :string, required: true, doc: "PR description (Markdown)"],
            head: [type: :string, required: true, doc: "Branch containing changes"],
            base: [type: :string, required: true, doc: "Branch to merge into"]
          ],
          callback: &github_not_available/1
        ),
      "github_get_pull_request" =>
        ReqLLM.Tool.new!(
          name: "github_get_pull_request",
          description: "Get details of a specific pull request by number.",
          parameter_schema: [
            owner: [type: :string, required: true, doc: "Repository owner"],
            repo: [type: :string, required: true, doc: "Repository name"],
            number: [type: :integer, required: true, doc: "PR number"]
          ],
          callback: &github_not_available/1
        ),
      "github_merge_pull_request" =>
        ReqLLM.Tool.new!(
          name: "github_merge_pull_request",
          description: "Merge a pull request in a GitHub repository.",
          parameter_schema: [
            owner: [type: :string, required: true, doc: "Repository owner"],
            repo: [type: :string, required: true, doc: "Repository name"],
            number: [type: :integer, required: true, doc: "PR number"]
          ],
          callback: &github_not_available/1
        ),
      "github_get_file" =>
        ReqLLM.Tool.new!(
          name: "github_get_file",
          description:
            "Get the content of a file from a GitHub repository. Returns the decoded file content.",
          parameter_schema: [
            owner: [type: :string, required: true, doc: "Repository owner"],
            repo: [type: :string, required: true, doc: "Repository name"],
            path: [type: :string, required: true, doc: "File path within the repository"]
          ],
          callback: &github_not_available/1
        ),
      "github_list_workflow_runs" =>
        ReqLLM.Tool.new!(
          name: "github_list_workflow_runs",
          description: "List recent GitHub Actions workflow runs for a repository.",
          parameter_schema: [
            owner: [type: :string, required: true, doc: "Repository owner"],
            repo: [type: :string, required: true, doc: "Repository name"]
          ],
          callback: &github_not_available/1
        ),
      "github_get_workflow_run_logs" =>
        ReqLLM.Tool.new!(
          name: "github_get_workflow_run_logs",
          description: "Download logs for a specific GitHub Actions workflow run.",
          parameter_schema: [
            owner: [type: :string, required: true, doc: "Repository owner"],
            repo: [type: :string, required: true, doc: "Repository name"],
            run_id: [type: :integer, required: true, doc: "Workflow run ID"]
          ],
          callback: &github_not_available/1
        ),

      # ── Gmail Tools ──────────────────────────────────────────────────────

      "gmail_list_messages" =>
        ReqLLM.Tool.new!(
          name: "gmail_list_messages",
          description:
            "List Gmail messages matching a search query. Returns message IDs and thread IDs. Use gmail_get_message to fetch full content.",
          parameter_schema: [
            query: [
              type: :string,
              doc: "Gmail search query (same syntax as the Gmail search box)"
            ],
            max_results: [
              type: :integer,
              doc: "Maximum number of messages to return (default: 10)"
            ]
          ],
          callback: &google_workspace_not_available/1
        ),
      "gmail_get_message" =>
        ReqLLM.Tool.new!(
          name: "gmail_get_message",
          description:
            "Get the full content of a Gmail message by ID, including headers, body, and labels.",
          parameter_schema: [
            message_id: [type: :string, required: true, doc: "The message ID to retrieve"]
          ],
          callback: &google_workspace_not_available/1
        ),
      "gmail_send_message" =>
        ReqLLM.Tool.new!(
          name: "gmail_send_message",
          description: "Send an email via Gmail.",
          parameter_schema: [
            to: [type: :string, required: true, doc: "Recipient email address"],
            subject: [type: :string, required: true, doc: "Email subject line"],
            body: [type: :string, required: true, doc: "Email body (plain text)"],
            cc: [type: :string, doc: "CC email address"],
            bcc: [type: :string, doc: "BCC email address"]
          ],
          callback: &google_workspace_not_available/1
        ),
      "gmail_modify_labels" =>
        ReqLLM.Tool.new!(
          name: "gmail_modify_labels",
          description:
            "Add or remove labels on a Gmail message. Use gmail_list_labels to find available label IDs.",
          parameter_schema: [
            message_id: [type: :string, required: true, doc: "The message ID to modify"],
            add_label_ids: [type: {:list, :string}, doc: "Label IDs to add"],
            remove_label_ids: [type: {:list, :string}, doc: "Label IDs to remove"]
          ],
          callback: &google_workspace_not_available/1
        ),
      "gmail_list_labels" =>
        ReqLLM.Tool.new!(
          name: "gmail_list_labels",
          description: "List all Gmail labels for the delegated user's mailbox.",
          parameter_schema: [],
          callback: &google_workspace_not_available/1
        ),

      # ── Calendar Tools ───────────────────────────────────────────────────

      "calendar_list_calendars" =>
        ReqLLM.Tool.new!(
          name: "calendar_list_calendars",
          description: "List all calendars the delegated user has access to.",
          parameter_schema: [],
          callback: &google_workspace_not_available/1
        ),
      "calendar_list_events" =>
        ReqLLM.Tool.new!(
          name: "calendar_list_events",
          description:
            "List events from a Google Calendar. Defaults to the primary calendar if no calendar_id is given.",
          parameter_schema: [
            calendar_id: [type: :string, doc: "Calendar ID (default: \"primary\")"],
            time_min: [type: :string, doc: "Start of time range (ISO8601 datetime)"],
            time_max: [type: :string, doc: "End of time range (ISO8601 datetime)"],
            max_results: [type: :integer, doc: "Maximum number of events to return"]
          ],
          callback: &google_workspace_not_available/1
        ),
      "calendar_get_event" =>
        ReqLLM.Tool.new!(
          name: "calendar_get_event",
          description: "Get details of a specific calendar event.",
          parameter_schema: [
            calendar_id: [type: :string, doc: "Calendar ID (default: \"primary\")"],
            event_id: [type: :string, required: true, doc: "The event ID to retrieve"]
          ],
          callback: &google_workspace_not_available/1
        ),
      "calendar_create_event" =>
        ReqLLM.Tool.new!(
          name: "calendar_create_event",
          description: "Create a new event on a Google Calendar.",
          parameter_schema: [
            calendar_id: [type: :string, doc: "Calendar ID (default: \"primary\")"],
            summary: [type: :string, required: true, doc: "Event title"],
            start_time: [type: :string, required: true, doc: "Start time (ISO8601 datetime)"],
            end_time: [type: :string, required: true, doc: "End time (ISO8601 datetime)"],
            description: [type: :string, doc: "Event description"],
            location: [type: :string, doc: "Event location"],
            attendees: [type: {:list, :string}, doc: "List of attendee email addresses"]
          ],
          callback: &google_workspace_not_available/1
        ),
      "calendar_update_event" =>
        ReqLLM.Tool.new!(
          name: "calendar_update_event",
          description: "Update an existing calendar event. Only provided fields will be changed.",
          parameter_schema: [
            calendar_id: [type: :string, doc: "Calendar ID (default: \"primary\")"],
            event_id: [type: :string, required: true, doc: "The event ID to update"],
            summary: [type: :string, doc: "Event title"],
            start_time: [type: :string, doc: "Start time (ISO8601 datetime)"],
            end_time: [type: :string, doc: "End time (ISO8601 datetime)"],
            description: [type: :string, doc: "Event description"],
            location: [type: :string, doc: "Event location"],
            attendees: [type: {:list, :string}, doc: "List of attendee email addresses"]
          ],
          callback: &google_workspace_not_available/1
        ),
      "calendar_delete_event" =>
        ReqLLM.Tool.new!(
          name: "calendar_delete_event",
          description: "Delete a calendar event.",
          parameter_schema: [
            calendar_id: [type: :string, doc: "Calendar ID (default: \"primary\")"],
            event_id: [type: :string, required: true, doc: "The event ID to delete"]
          ],
          callback: &google_workspace_not_available/1
        ),
      "calendar_freebusy_query" =>
        ReqLLM.Tool.new!(
          name: "calendar_freebusy_query",
          description:
            "Query free/busy information for one or more calendars within a time range.",
          parameter_schema: [
            time_min: [
              type: :string,
              required: true,
              doc: "Start of time range (ISO8601 datetime)"
            ],
            time_max: [type: :string, required: true, doc: "End of time range (ISO8601 datetime)"],
            calendar_ids: [
              type: {:list, :string},
              required: true,
              doc: "List of calendar IDs to check"
            ]
          ],
          callback: &google_workspace_not_available/1
        ),

      # ── Drive Tools ──────────────────────────────────────────────────────

      "drive_list_files" =>
        ReqLLM.Tool.new!(
          name: "drive_list_files",
          description:
            "List files in Google Drive. Supports Drive query syntax for filtering (e.g., \"name contains 'report'\").",
          parameter_schema: [
            query: [type: :string, doc: "Drive search query (Google Drive query syntax)"],
            page_size: [type: :integer, doc: "Maximum number of files to return"],
            include_shared_drives: [
              type: :boolean,
              doc: "Whether to include shared drive files (default: true)"
            ]
          ],
          callback: &google_workspace_not_available/1
        ),
      "drive_get_file" =>
        ReqLLM.Tool.new!(
          name: "drive_get_file",
          description:
            "Get metadata for a Google Drive file (name, size, MIME type, permissions, etc.).",
          parameter_schema: [
            file_id: [type: :string, required: true, doc: "The file ID to retrieve"]
          ],
          callback: &google_workspace_not_available/1
        ),
      "drive_download_file" =>
        ReqLLM.Tool.new!(
          name: "drive_download_file",
          description:
            "Download the content of a Google Drive file. Large files will be truncated to ~50KB.",
          parameter_schema: [
            file_id: [type: :string, required: true, doc: "The file ID to download"]
          ],
          callback: &google_workspace_not_available/1
        ),
      "drive_upload_file" =>
        ReqLLM.Tool.new!(
          name: "drive_upload_file",
          description: "Upload a file to Google Drive.",
          parameter_schema: [
            name: [type: :string, required: true, doc: "File name"],
            content: [type: :string, required: true, doc: "File content"],
            mime_type: [type: :string, required: true, doc: "MIME type (e.g., \"text/plain\")"],
            parent_id: [type: :string, doc: "Parent folder ID to upload into"]
          ],
          callback: &google_workspace_not_available/1
        ),
      "drive_update_file" =>
        ReqLLM.Tool.new!(
          name: "drive_update_file",
          description: "Update a Google Drive file's metadata (rename, move between folders).",
          parameter_schema: [
            file_id: [type: :string, required: true, doc: "The file ID to update"],
            name: [type: :string, doc: "New file name"],
            add_parents: [type: :string, doc: "Comma-separated parent folder IDs to add"],
            remove_parents: [type: :string, doc: "Comma-separated parent folder IDs to remove"]
          ],
          callback: &google_workspace_not_available/1
        ),
      "drive_copy_file" =>
        ReqLLM.Tool.new!(
          name: "drive_copy_file",
          description: "Create a copy of a Google Drive file.",
          parameter_schema: [
            file_id: [type: :string, required: true, doc: "The file ID to copy"],
            name: [type: :string, doc: "Name for the copy"],
            parent_id: [type: :string, doc: "Parent folder ID for the copy"]
          ],
          callback: &google_workspace_not_available/1
        ),
      "drive_list_shared_drives" =>
        ReqLLM.Tool.new!(
          name: "drive_list_shared_drives",
          description: "List shared drives the delegated user has access to.",
          parameter_schema: [],
          callback: &google_workspace_not_available/1
        ),

      # ── Directory Tools ──────────────────────────────────────────────────

      "directory_list_users" =>
        ReqLLM.Tool.new!(
          name: "directory_list_users",
          description: "List users in a Google Workspace domain.",
          parameter_schema: [
            domain: [type: :string, required: true, doc: "The domain to list users for"],
            query: [type: :string, doc: "Search query for filtering users"],
            max_results: [type: :integer, doc: "Maximum number of users to return"]
          ],
          callback: &google_workspace_not_available/1
        ),
      "directory_get_user" =>
        ReqLLM.Tool.new!(
          name: "directory_get_user",
          description:
            "Get details of a specific user in the Google Workspace directory by email or user ID.",
          parameter_schema: [
            user_key: [
              type: :string,
              required: true,
              doc: "User's email address, alias, or unique user ID"
            ]
          ],
          callback: &google_workspace_not_available/1
        ),

      # ── Connecteam Tools ──────────────────────────────────────────────────

      "connecteam_list_users" =>
        ReqLLM.Tool.new!(
          name: "connecteam_list_users",
          description: "List users in the Connecteam account.",
          parameter_schema: [
            limit: [type: :integer, doc: "Maximum number of users to return"],
            offset: [type: :integer, doc: "Offset for pagination"]
          ],
          callback: &connecteam_not_available/1
        ),
      "connecteam_create_user" =>
        ReqLLM.Tool.new!(
          name: "connecteam_create_user",
          description: "Create a new user in Connecteam.",
          parameter_schema: [
            email: [type: :string, required: true, doc: "User email address"],
            first_name: [type: :string, required: true, doc: "User first name"],
            last_name: [type: :string, required: true, doc: "User last name"],
            phone: [type: :string, doc: "User phone number"],
            role: [type: :string, doc: "User role"]
          ],
          callback: &connecteam_not_available/1
        ),
      "connecteam_list_schedulers" =>
        ReqLLM.Tool.new!(
          name: "connecteam_list_schedulers",
          description: "List all schedulers in the Connecteam account.",
          parameter_schema: [],
          callback: &connecteam_not_available/1
        ),
      "connecteam_list_shifts" =>
        ReqLLM.Tool.new!(
          name: "connecteam_list_shifts",
          description: "List shifts for a specific scheduler.",
          parameter_schema: [
            scheduler_id: [type: :string, required: true, doc: "Scheduler ID"],
            start_date: [type: :string, doc: "Start date filter (ISO8601)"],
            end_date: [type: :string, doc: "End date filter (ISO8601)"],
            limit: [type: :integer, doc: "Maximum number of shifts to return"],
            offset: [type: :integer, doc: "Offset for pagination"]
          ],
          callback: &connecteam_not_available/1
        ),
      "connecteam_get_shift" =>
        ReqLLM.Tool.new!(
          name: "connecteam_get_shift",
          description: "Get details of a specific shift.",
          parameter_schema: [
            scheduler_id: [type: :string, required: true, doc: "Scheduler ID"],
            shift_id: [type: :string, required: true, doc: "Shift ID"]
          ],
          callback: &connecteam_not_available/1
        ),
      "connecteam_create_shift" =>
        ReqLLM.Tool.new!(
          name: "connecteam_create_shift",
          description: "Create a new shift in a scheduler.",
          parameter_schema: [
            scheduler_id: [type: :string, required: true, doc: "Scheduler ID"],
            title: [type: :string, required: true, doc: "Shift title"],
            start_time: [type: :string, required: true, doc: "Start time (ISO8601 datetime)"],
            end_time: [type: :string, required: true, doc: "End time (ISO8601 datetime)"],
            user_ids: [type: {:list, :string}, doc: "List of user IDs to assign to the shift"]
          ],
          callback: &connecteam_not_available/1
        ),
      "connecteam_delete_shift" =>
        ReqLLM.Tool.new!(
          name: "connecteam_delete_shift",
          description: "Delete a shift from a scheduler.",
          parameter_schema: [
            scheduler_id: [type: :string, required: true, doc: "Scheduler ID"],
            shift_id: [type: :string, required: true, doc: "Shift ID"]
          ],
          callback: &connecteam_not_available/1
        ),
      "connecteam_get_shift_layers" =>
        ReqLLM.Tool.new!(
          name: "connecteam_get_shift_layers",
          description: "Get shift layers for a scheduler.",
          parameter_schema: [
            scheduler_id: [type: :string, required: true, doc: "Scheduler ID"]
          ],
          callback: &connecteam_not_available/1
        ),
      "connecteam_list_jobs" =>
        ReqLLM.Tool.new!(
          name: "connecteam_list_jobs",
          description: "List jobs in the Connecteam account.",
          parameter_schema: [
            limit: [type: :integer, doc: "Maximum number of jobs to return"],
            offset: [type: :integer, doc: "Offset for pagination"]
          ],
          callback: &connecteam_not_available/1
        ),
      "connecteam_list_onboarding_packs" =>
        ReqLLM.Tool.new!(
          name: "connecteam_list_onboarding_packs",
          description: "List onboarding packs in the Connecteam account.",
          parameter_schema: [
            limit: [type: :integer, doc: "Maximum number of packs to return"],
            offset: [type: :integer, doc: "Offset for pagination"]
          ],
          callback: &connecteam_not_available/1
        ),
      "connecteam_get_pack_assignments" =>
        ReqLLM.Tool.new!(
          name: "connecteam_get_pack_assignments",
          description: "Get user assignments for a specific onboarding pack.",
          parameter_schema: [
            pack_id: [type: :string, required: true, doc: "Onboarding pack ID"],
            limit: [type: :integer, doc: "Maximum number of assignments to return"],
            offset: [type: :integer, doc: "Offset for pagination"]
          ],
          callback: &connecteam_not_available/1
        ),
      "connecteam_assign_users_to_pack" =>
        ReqLLM.Tool.new!(
          name: "connecteam_assign_users_to_pack",
          description: "Assign users to an onboarding pack.",
          parameter_schema: [
            pack_id: [type: :string, required: true, doc: "Onboarding pack ID"],
            user_ids: [
              type: {:list, :string},
              required: true,
              doc: "List of user IDs to assign"
            ]
          ],
          callback: &connecteam_not_available/1
        )
    }
  end

  defp github_not_available(_args) do
    {:error, "GitHub token not available — ask the user to set one in their profile"}
  end

  defp google_workspace_not_available(_args) do
    {:error,
     "Google Workspace not configured — assign a tool config with a service account and delegate email"}
  end

  defp connecteam_not_available(_args) do
    {:error, "Connecteam not configured — assign a tool config with an API key in tool settings"}
  end

  defp fetch_url(url, redirects_remaining) do
    case Req.get(url, max_retries: 2, retry_delay: 500, receive_timeout: 15_000) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        text = to_string(body)

        case extract_meta_refresh(text, url) do
          {:redirect, target} when redirects_remaining > 0 ->
            fetch_url(target, redirects_remaining - 1)

          _ ->
            if byte_size(text) > @max_body_bytes do
              {:ok, binary_part(text, 0, @max_body_bytes) <> "\n[truncated]"}
            else
              {:ok, text}
            end
        end

      {:ok, %Req.Response{status: status}} ->
        {:ok, "HTTP #{status}"}

      {:error, reason} ->
        {:ok, "Error fetching URL: #{inspect(reason)}"}
    end
  end

  defp extract_meta_refresh(html, base_url) do
    case Regex.run(
           ~r/<meta\s[^>]*http-equiv\s*=\s*["']refresh["'][^>]*content\s*=\s*["']\d+;\s*url=([^"']+)["']/i,
           html
         ) do
      [_, relative_url] ->
        base_uri = URI.parse(base_url)

        base_uri =
          if String.ends_with?(base_uri.path || "/", "/"),
            do: base_uri,
            else: %{base_uri | path: base_uri.path <> "/"}

        target = URI.merge(base_uri, relative_url) |> to_string()
        {:redirect, target}

      nil ->
        :none
    end
  end
end
