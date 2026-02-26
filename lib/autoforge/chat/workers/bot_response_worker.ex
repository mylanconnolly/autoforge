defmodule Autoforge.Chat.Workers.BotResponseWorker do
  @moduledoc """
  Oban worker that generates a bot response via ReqLLM and creates
  the resulting message in the conversation.

  The worker:
  1. Loads conversation context (messages, bot, API key)
  2. Broadcasts a "thinking" indicator via PubSub
  3. Builds and truncates the message history to fit the context window
  4. Calls ReqLLM to generate a response
  5. Creates the bot's reply message (Ash PubSub auto-broadcasts it)
  6. Clears the "thinking" indicator
  """

  use Oban.Worker, queue: :ai, max_attempts: 3

  alias Autoforge.Accounts.UserGroupMembership
  alias Autoforge.Ai.{Bot, ToolResolver}
  alias Autoforge.Chat.{Conversation, Message, ToolInvocation}

  import ReqLLM.Context, only: [user: 1, assistant: 1]

  require Ash.Query
  require Logger

  @default_context_limit 8192
  @context_usage_ratio 0.8
  @bytes_per_token 4
  @max_tool_rounds 20

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"bot_id" => bot_id, "conversation_id" => conversation_id}}) do
    with {:ok, bot} <- load_bot(bot_id),
         {:ok, conversation} <- load_conversation(conversation_id) do
      api_key = bot.llm_provider_key.value
      broadcast_thinking(conversation_id, bot_id, true)

      try do
        generate_and_create_response(bot, conversation, api_key)
      after
        broadcast_thinking(conversation_id, bot_id, false)
      end
    end
  end

  defp load_bot(bot_id) do
    case Ash.get(Bot, bot_id, load: [:llm_provider_key, :tools], authorize?: false) do
      {:ok, nil} -> {:cancel, "bot not found: #{bot_id}"}
      {:ok, bot} -> {:ok, bot}
      {:error, reason} -> {:cancel, "failed to load bot: #{inspect(reason)}"}
    end
  end

  defp load_conversation(conversation_id) do
    conversation =
      Conversation
      |> Ash.Query.filter(id == ^conversation_id)
      |> Ash.Query.load([:bots, :participants, messages: [:user, :bot]])
      |> Ash.read_one!(authorize?: false)

    case conversation do
      nil -> {:cancel, "conversation not found: #{conversation_id}"}
      conv -> {:ok, conv}
    end
  end

  defp generate_and_create_response(bot, conversation, api_key) do
    messages =
      conversation.messages
      |> Enum.sort_by(& &1.inserted_at, {:asc, DateTime})

    multi_participant? = multi_participant?(conversation)
    system_prompt = build_system_prompt(bot, conversation, multi_participant?)
    llm_messages = build_messages(messages, bot, multi_participant?)
    truncated = truncate_messages(llm_messages, system_prompt, bot.model)

    participant_ids = Enum.map(conversation.participants, & &1.id)
    tools = ToolResolver.resolve(bot, participant_ids)
    tools = inject_delegate_context(tools, bot, conversation, participant_ids)
    tools = inject_github_context(tools, conversation)
    tools = inject_google_workspace_context(tools, conversation)
    tools = inject_connecteam_context(tools)

    base_opts =
      [api_key: api_key, system_prompt: system_prompt]
      |> maybe_put(:temperature, bot.temperature && Decimal.to_float(bot.temperature))
      |> maybe_put(:max_tokens, bot.max_tokens)
      |> maybe_put_anthropic_caching(bot.model)

    case run_tool_loop(bot.model, truncated, tools, base_opts, 0, []) do
      {:ok, response_text, invocations} ->
        message =
          Message
          |> Ash.Changeset.for_create(
            :create,
            %{
              body: response_text,
              role: :bot,
              bot_id: bot.id,
              conversation_id: conversation.id
            },
            authorize?: false
          )
          |> Ash.create!()

        if invocations != [] do
          Enum.each(invocations, fn inv ->
            ToolInvocation
            |> Ash.Changeset.for_create(:create, Map.put(inv, :message_id, message.id),
              authorize?: false
            )
            |> Ash.create!()
          end)

          Phoenix.PubSub.broadcast(
            Autoforge.PubSub,
            "conversation:#{conversation.id}",
            {:tool_invocations_saved, message.id}
          )
        end

        :ok

      {:error, %{status: status}} when status in [401, 403] ->
        {:cancel, "authentication failed (HTTP #{status})"}

      {:error, reason} ->
        Logger.warning("Bot response failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp run_tool_loop(model, messages, tools, opts, round, invocations) do
    call_opts =
      if tools != [] and round < @max_tool_rounds do
        Keyword.put(opts, :tools, tools)
      else
        opts
      end

    case ReqLLM.generate_text(model, messages, call_opts) do
      {:ok, response} ->
        classified = ReqLLM.Response.classify(response)

        if classified.type == :tool_calls and round < @max_tool_rounds do
          tool_calls = ReqLLM.Response.tool_calls(response)

          Logger.info(
            "Tool calls (round #{round + 1}): #{Enum.map_join(tool_calls, ", ", & &1.function.name)}"
          )

          {updated_context, new_invocations} =
            execute_tool_calls(response.context, tool_calls, tools)

          run_tool_loop(
            model,
            updated_context,
            tools,
            opts,
            round + 1,
            invocations ++ new_invocations
          )
        else
          {:ok, ReqLLM.Response.text(response) || "", invocations}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp execute_tool_calls(context, tool_calls, available_tools) do
    Enum.reduce(tool_calls, {context, []}, fn tool_call, {ctx, invocations} ->
      name = tool_call.function.name
      id = tool_call.id
      args = Jason.decode!(tool_call.function.arguments)

      {status, result_str, tool_result_msg} =
        case execute_tool(name, args, available_tools) do
          {:ok, result} ->
            {:ok, stringify_result(result), ReqLLM.Context.tool_result_message(name, id, result)}

          {:error, error} ->
            {:error, stringify_result(error),
             ReqLLM.Context.tool_result_message(name, id, %{error: to_string(error)})}
        end

      inv = %{
        tool_name: name,
        arguments: args,
        result: result_str,
        status: status
      }

      {ReqLLM.Context.append(ctx, tool_result_msg), [inv | invocations]}
    end)
  end

  defp execute_tool(name, args, available_tools) do
    case Enum.find(available_tools, &(&1.name == name)) do
      nil -> {:error, "unknown tool: #{name}"}
      tool -> ReqLLM.Tool.execute(tool, args)
    end
  end

  defp stringify_result(result) when is_binary(result), do: result
  defp stringify_result(result), do: inspect(result, limit: :infinity, printable_limit: 50_000)

  defp multi_participant?(conversation) do
    length(conversation.bots) > 1 || length(conversation.participants) > 1
  end

  defp build_system_prompt(bot, conversation, multi_participant?) do
    base = bot.system_prompt || "You are #{bot.name}."

    if multi_participant? do
      participant_names =
        Enum.map(conversation.participants, fn u -> u.name || to_string(u.email) end)

      bot_names = Enum.map(conversation.bots, & &1.name)

      context =
        "This is a multi-participant conversation. " <>
          "Participants: #{Enum.join(participant_names, ", ")}. " <>
          "Bots: #{Enum.join(bot_names, ", ")}. " <>
          "Messages from other participants are prefixed with their name."

      context <> "\n\n" <> base
    else
      base
    end
  end

  defp build_messages(messages, bot, multi_participant?) do
    Enum.map(messages, fn msg ->
      case msg.role do
        :user ->
          body =
            if multi_participant? do
              sender = (msg.user && (msg.user.name || to_string(msg.user.email))) || "User"
              "[#{sender}]: #{msg.body}"
            else
              msg.body
            end

          user(body)

        :bot ->
          if msg.bot_id == bot.id do
            assistant(msg.body)
          else
            other_name = (msg.bot && msg.bot.name) || "Bot"

            if multi_participant? do
              user("[#{other_name}]: #{msg.body}")
            else
              user("[#{other_name}]: #{msg.body}")
            end
          end
      end
    end)
  end

  defp truncate_messages(messages, system_prompt, model_spec) do
    context_limit = get_context_limit(model_spec)
    max_tokens = trunc(context_limit * @context_usage_ratio)
    system_tokens = estimate_tokens(system_prompt)
    available = max_tokens - system_tokens

    {kept, _used} =
      messages
      |> Enum.reverse()
      |> Enum.reduce({[], 0}, fn msg, {acc, used} ->
        msg_tokens = estimate_message_tokens(msg)

        if used + msg_tokens <= available do
          {[msg | acc], used + msg_tokens}
        else
          {acc, used}
        end
      end)

    kept
  end

  defp get_context_limit(model_spec) do
    case LLMDB.model(model_spec) do
      {:ok, model} -> model.limits[:context] || @default_context_limit
      _ -> @default_context_limit
    end
  end

  defp estimate_tokens(text) when is_binary(text), do: div(byte_size(text), @bytes_per_token)
  defp estimate_tokens(_), do: 0

  defp estimate_message_tokens(%{content: content}) when is_binary(content) do
    estimate_tokens(content)
  end

  defp estimate_message_tokens(%{content: parts}) when is_list(parts) do
    Enum.reduce(parts, 0, fn
      %{text: text}, acc -> acc + estimate_tokens(text)
      _, acc -> acc
    end)
  end

  defp estimate_message_tokens(_), do: 0

  # ── Delegation ──────────────────────────────────────────────────────────────

  defp inject_delegate_context(tools, calling_bot, conversation, participant_ids) do
    Enum.map(tools, fn
      %{name: "delegate_task"} = tool ->
        %{tool | callback: build_delegate_callback(calling_bot, conversation, participant_ids)}

      tool ->
        tool
    end)
  end

  defp build_delegate_callback(calling_bot, conversation, participant_ids) do
    fn %{bot_name: bot_name, task: task} ->
      run_delegation(bot_name, task, calling_bot, conversation, participant_ids)
    end
  end

  defp run_delegation(bot_name, task, calling_bot, conversation, participant_ids) do
    accessible_bots = accessible_bots_for_participants(participant_ids)

    target_bot =
      Enum.find(accessible_bots, fn b ->
        String.downcase(b.name) == String.downcase(bot_name)
      end)

    cond do
      is_nil(target_bot) ->
        available = Enum.map_join(accessible_bots, ", ", & &1.name)
        {:error, "No bot named '#{bot_name}' found. Available bots: #{available}"}

      target_bot.id == calling_bot.id ->
        {:error, "Cannot delegate to yourself."}

      true ->
        do_delegation(target_bot, task, calling_bot, conversation, participant_ids)
    end
  end

  defp accessible_bots_for_participants(participant_ids) do
    user_group_ids =
      UserGroupMembership
      |> Ash.Query.filter(user_id in ^participant_ids)
      |> Ash.read!(authorize?: false)
      |> Enum.map(& &1.user_group_id)
      |> Enum.uniq()

    Bot
    |> Ash.Query.filter(exists(user_groups, id in ^user_group_ids))
    |> Ash.Query.sort(name: :asc)
    |> Ash.read!(authorize?: false)
  end

  defp do_delegation(target_bot, task, calling_bot, conversation, participant_ids) do
    case load_bot(target_bot.id) do
      {:ok, target} ->
        # Reload conversation for fresh messages
        {:ok, fresh_conv} = load_conversation(conversation.id)

        messages =
          fresh_conv.messages
          |> Enum.sort_by(& &1.inserted_at, {:asc, DateTime})

        multi_participant? = multi_participant?(fresh_conv)
        system_prompt = build_system_prompt(target, fresh_conv, multi_participant?)
        llm_messages = build_messages(messages, target, multi_participant?)

        # Append the delegation instruction
        delegation_msg = user("[Task from #{calling_bot.name}]: #{task}")
        llm_messages = llm_messages ++ [delegation_msg]

        truncated = truncate_messages(llm_messages, system_prompt, target.model)

        # Resolve target bot's tools, excluding delegate_task to prevent recursion
        tools =
          ToolResolver.resolve(target, participant_ids)
          |> Enum.reject(&(&1.name == "delegate_task"))

        api_key = target.llm_provider_key.value

        base_opts =
          [api_key: api_key, system_prompt: system_prompt]
          |> maybe_put(:temperature, target.temperature && Decimal.to_float(target.temperature))
          |> maybe_put(:max_tokens, target.max_tokens)
          |> maybe_put_anthropic_caching(target.model)

        broadcast_thinking(conversation.id, target.id, true)

        try do
          case run_tool_loop(target.model, truncated, tools, base_opts, 0, []) do
            {:ok, response_text, _invocations} ->
              {:ok, response_text}

            {:error, reason} ->
              {:error, "Delegation to #{target.name} failed: #{inspect(reason)}"}
          end
        after
          broadcast_thinking(conversation.id, target.id, false)
        end

      {:cancel, reason} ->
        {:error, "Could not load bot #{target_bot.name}: #{reason}"}
    end
  end

  # ── GitHub Context ────────────────────────────────────────────────────────

  defp inject_github_context(tools, conversation) do
    case find_github_token(conversation.participants) do
      nil ->
        tools

      token ->
        Enum.map(tools, fn
          %{name: "github_" <> _} = tool ->
            %{tool | callback: build_github_callback(tool.name, token)}

          tool ->
            tool
        end)
    end
  end

  defp find_github_token(participants) do
    Enum.find_value(participants, & &1.github_token)
  end

  defp build_github_callback(tool_name, token) do
    fn args -> execute_github_tool(tool_name, args, token) end
  end

  defp execute_github_tool(tool_name, args, token) do
    alias Autoforge.GitHub.Client

    result =
      case tool_name do
        "github_get_repo" ->
          Client.get_repo(token, args.owner, args.repo)

        "github_list_issues" ->
          opts = if args[:state], do: [state: args.state], else: []
          Client.list_issues(token, args.owner, args.repo, opts)

        "github_create_issue" ->
          Client.create_issue(token, args.owner, args.repo, %{
            "title" => args.title,
            "body" => args.body
          })

        "github_get_issue" ->
          Client.get_issue(token, args.owner, args.repo, args.number)

        "github_comment_on_issue" ->
          Client.create_issue_comment(token, args.owner, args.repo, args.number, args.body)

        "github_list_pull_requests" ->
          opts = if args[:state], do: [state: args.state], else: []
          Client.list_pull_requests(token, args.owner, args.repo, opts)

        "github_create_pull_request" ->
          Client.create_pull_request(token, args.owner, args.repo, %{
            "title" => args.title,
            "body" => args.body,
            "head" => args.head,
            "base" => args.base
          })

        "github_get_pull_request" ->
          Client.get_pull_request(token, args.owner, args.repo, args.number)

        "github_merge_pull_request" ->
          Client.merge_pull_request(token, args.owner, args.repo, args.number)

        "github_get_file" ->
          Client.get_file_content(token, args.owner, args.repo, args.path)

        "github_list_workflow_runs" ->
          Client.list_workflow_runs(token, args.owner, args.repo)

        "github_get_workflow_run_logs" ->
          Client.download_workflow_run_logs(token, args.owner, args.repo, args.run_id)

        _ ->
          {:error, "Unknown GitHub tool: #{tool_name}"}
      end

    case result do
      {:ok, data} when is_map(data) or is_list(data) -> {:ok, Jason.encode!(data)}
      {:ok, data} when is_binary(data) -> {:ok, data}
      {:error, reason} -> {:error, to_string(reason)}
    end
  end

  # ── Google Workspace Context ──────────────────────────────────────────

  @google_workspace_prefixes ["gmail_", "calendar_", "drive_", "directory_"]

  @scope_map %{
    "gmail_" => ["https://www.googleapis.com/auth/gmail.modify"],
    "calendar_" => ["https://www.googleapis.com/auth/calendar"],
    "drive_" => ["https://www.googleapis.com/auth/drive"],
    "directory_" => ["https://www.googleapis.com/auth/admin.directory.user.readonly"]
  }

  defp inject_google_workspace_context(tools, conversation) do
    gw_tool_names =
      tools
      |> Enum.filter(fn tool ->
        Enum.any?(@google_workspace_prefixes, &String.starts_with?(tool.name, &1))
      end)
      |> Enum.map(& &1.name)

    if gw_tool_names == [] do
      tools
    else
      delegate_email = sender_email(conversation)

      if delegate_email do
        tool_configs = load_google_workspace_configs(gw_tool_names, delegate_email)

        Enum.map(tools, fn tool ->
          case Map.get(tool_configs, tool.name) do
            nil ->
              tool

            token ->
              %{tool | callback: build_google_workspace_callback(tool.name, token)}
          end
        end)
      else
        Logger.warning("No sender email found for Google Workspace tool delegation")
        tools
      end
    end
  end

  defp sender_email(conversation) do
    conversation.messages
    |> Enum.filter(&(&1.role == :user && &1.user != nil))
    |> Enum.sort_by(& &1.inserted_at, {:desc, DateTime})
    |> case do
      [latest | _] -> to_string(latest.user.email)
      [] -> nil
    end
  end

  defp load_google_workspace_configs(tool_names, delegate_email) do
    alias Autoforge.Ai.Tool, as: ToolResource
    alias Autoforge.Config.GoogleServiceAccountConfig
    alias Autoforge.Google.Auth

    db_tools =
      ToolResource
      |> Ash.Query.filter(name in ^tool_names)
      |> Ash.read!(authorize?: false)

    db_tools
    |> Enum.filter(fn t ->
      match?(%Ash.Union{type: :google_workspace}, t.config)
    end)
    |> Enum.reduce(%{}, fn tool, acc ->
      %Ash.Union{value: config} = tool.config
      sa_id = config.google_service_account_config_id
      prefix = google_workspace_prefix(tool.name)
      scopes = Map.get(@scope_map, prefix, [])

      case Ash.get(GoogleServiceAccountConfig, sa_id, authorize?: false) do
        {:ok, sa_config} ->
          case Auth.get_delegated_access_token(sa_config, scopes, delegate_email) do
            {:ok, token} ->
              Map.put(acc, tool.name, token)

            {:error, reason} ->
              Logger.warning("Failed to get Google token for #{tool.name}: #{inspect(reason)}")
              acc
          end

        _ ->
          Logger.warning("Service account config not found for tool #{tool.name}")
          acc
      end
    end)
  end

  defp google_workspace_prefix(tool_name) do
    Enum.find(@google_workspace_prefixes, fn prefix ->
      String.starts_with?(tool_name, prefix)
    end)
  end

  defp build_google_workspace_callback(tool_name, token) do
    fn args -> execute_google_workspace_tool(tool_name, args, token) end
  end

  defp execute_google_workspace_tool(tool_name, args, token) do
    alias Autoforge.Google.{Gmail, Calendar, Drive, Directory}

    result =
      case tool_name do
        # Gmail
        "gmail_list_messages" ->
          opts = []
          opts = if args[:query], do: Keyword.put(opts, :q, args.query), else: opts

          opts =
            if args[:max_results],
              do: Keyword.put(opts, :maxResults, args.max_results),
              else: opts

          Gmail.list_messages(token, opts)

        "gmail_get_message" ->
          Gmail.get_message(token, args.message_id, format: "full")

        "gmail_send_message" ->
          raw = build_rfc2822(args)
          encoded = Base.url_encode64(raw, padding: false)
          Gmail.send_message(token, encoded)

        "gmail_modify_labels" ->
          Gmail.modify_message(
            token,
            args.message_id,
            args[:add_label_ids] || [],
            args[:remove_label_ids] || []
          )

        "gmail_list_labels" ->
          Gmail.list_labels(token)

        # Calendar
        "calendar_list_calendars" ->
          Calendar.list_calendars(token)

        "calendar_list_events" ->
          cal_id = args[:calendar_id] || "primary"
          opts = []
          opts = if args[:time_min], do: Keyword.put(opts, :timeMin, args.time_min), else: opts
          opts = if args[:time_max], do: Keyword.put(opts, :timeMax, args.time_max), else: opts

          opts =
            if args[:max_results],
              do: Keyword.put(opts, :maxResults, args.max_results),
              else: opts

          Calendar.list_events(token, cal_id, opts)

        "calendar_get_event" ->
          cal_id = args[:calendar_id] || "primary"
          Calendar.get_event(token, cal_id, args.event_id)

        "calendar_create_event" ->
          cal_id = args[:calendar_id] || "primary"
          params = build_calendar_event_params(args)
          Calendar.create_event(token, cal_id, params)

        "calendar_update_event" ->
          cal_id = args[:calendar_id] || "primary"
          params = build_calendar_event_params(args)
          Calendar.update_event(token, cal_id, args.event_id, params)

        "calendar_delete_event" ->
          cal_id = args[:calendar_id] || "primary"
          Calendar.delete_event(token, cal_id, args.event_id)

        "calendar_freebusy_query" ->
          Calendar.freebusy_query(token, args.time_min, args.time_max, args.calendar_ids)

        # Drive
        "drive_list_files" ->
          opts = []
          opts = if args[:query], do: Keyword.put(opts, :q, args.query), else: opts
          opts = if args[:page_size], do: Keyword.put(opts, :pageSize, args.page_size), else: opts
          Drive.list_files(token, opts)

        "drive_get_file" ->
          Drive.get_file(token, args.file_id)

        "drive_download_file" ->
          Drive.download_file(token, args.file_id)

        "drive_upload_file" ->
          opts = if args[:parent_id], do: [parent_id: args.parent_id], else: []
          Drive.upload_file(token, args.name, args.content, args.mime_type, opts)

        "drive_update_file" ->
          metadata = %{}
          metadata = if args[:name], do: Map.put(metadata, "name", args.name), else: metadata

          metadata =
            if args[:add_parents],
              do: Map.put(metadata, "addParents", args.add_parents),
              else: metadata

          metadata =
            if args[:remove_parents],
              do: Map.put(metadata, "removeParents", args.remove_parents),
              else: metadata

          Drive.update_file(token, args.file_id, metadata)

        "drive_copy_file" ->
          opts = []
          opts = if args[:name], do: Keyword.put(opts, :name, args.name), else: opts

          opts =
            if args[:parent_id], do: Keyword.put(opts, :parent_id, args.parent_id), else: opts

          Drive.copy_file(token, args.file_id, opts)

        "drive_list_shared_drives" ->
          Drive.list_shared_drives(token)

        # Directory
        "directory_list_users" ->
          opts = []
          opts = if args[:query], do: Keyword.put(opts, :query, args.query), else: opts

          opts =
            if args[:max_results],
              do: Keyword.put(opts, :maxResults, args.max_results),
              else: opts

          Directory.list_users(token, args.domain, opts)

        "directory_get_user" ->
          Directory.get_user(token, args.user_key)

        _ ->
          {:error, "Unknown Google Workspace tool: #{tool_name}"}
      end

    case result do
      {:ok, data} when is_map(data) or is_list(data) -> {:ok, Jason.encode!(data)}
      {:ok, data} when is_binary(data) -> {:ok, data}
      :ok -> {:ok, "Success"}
      {:error, reason} -> {:error, to_string(reason)}
    end
  end

  # ── Connecteam Context ────────────────────────────────────────────────

  defp inject_connecteam_context(tools) do
    ct_tool_names =
      tools
      |> Enum.filter(&String.starts_with?(&1.name, "connecteam_"))
      |> Enum.map(& &1.name)

    if ct_tool_names == [] do
      tools
    else
      configs = load_connecteam_configs(ct_tool_names)

      Enum.map(tools, fn tool ->
        case Map.get(configs, tool.name) do
          nil ->
            tool

          {api_key, region} ->
            %{tool | callback: build_connecteam_callback(tool.name, api_key, region)}
        end
      end)
    end
  end

  defp load_connecteam_configs(tool_names) do
    alias Autoforge.Ai.Tool, as: ToolResource
    alias Autoforge.Config.ConnecteamApiKeyConfig

    db_tools =
      ToolResource
      |> Ash.Query.filter(name in ^tool_names)
      |> Ash.read!(authorize?: false)

    db_tools
    |> Enum.filter(fn t ->
      match?(%Ash.Union{type: :connecteam}, t.config)
    end)
    |> Enum.reduce(%{}, fn tool, acc ->
      %Ash.Union{value: config} = tool.config
      ct_id = config.connecteam_api_key_config_id

      case Ash.get(ConnecteamApiKeyConfig, ct_id, authorize?: false) do
        {:ok, ct_config} ->
          if ct_config.enabled do
            Map.put(acc, tool.name, {ct_config.api_key, ct_config.region})
          else
            Logger.warning("Connecteam API key disabled for tool #{tool.name}")
            acc
          end

        _ ->
          Logger.warning("Connecteam API key config not found for tool #{tool.name}")
          acc
      end
    end)
  end

  defp build_connecteam_callback(tool_name, api_key, region) do
    fn args -> execute_connecteam_tool(tool_name, args, api_key, region) end
  end

  defp execute_connecteam_tool(tool_name, args, api_key, region) do
    alias Autoforge.Connecteam.Client

    result =
      case tool_name do
        "connecteam_list_users" ->
          opts = []
          opts = if args[:limit], do: Keyword.put(opts, :limit, args.limit), else: opts
          opts = if args[:offset], do: Keyword.put(opts, :offset, args.offset), else: opts
          Client.list_users(api_key, region, opts)

        "connecteam_create_user" ->
          attrs = %{
            "email" => args.email,
            "firstName" => args.first_name,
            "lastName" => args.last_name
          }

          attrs = if args[:phone], do: Map.put(attrs, "phone", args.phone), else: attrs
          attrs = if args[:role], do: Map.put(attrs, "role", args.role), else: attrs
          Client.create_user(api_key, region, attrs)

        "connecteam_list_schedulers" ->
          Client.list_schedulers(api_key, region)

        "connecteam_list_shifts" ->
          opts = []

          opts =
            if args[:start_date], do: Keyword.put(opts, :start_date, args.start_date), else: opts

          opts = if args[:end_date], do: Keyword.put(opts, :end_date, args.end_date), else: opts
          opts = if args[:limit], do: Keyword.put(opts, :limit, args.limit), else: opts
          opts = if args[:offset], do: Keyword.put(opts, :offset, args.offset), else: opts
          Client.list_shifts(api_key, region, args.scheduler_id, opts)

        "connecteam_get_shift" ->
          Client.get_shift(api_key, region, args.scheduler_id, args.shift_id)

        "connecteam_create_shift" ->
          attrs = %{
            "title" => args.title,
            "startTime" => args.start_time,
            "endTime" => args.end_time
          }

          attrs =
            if args[:user_ids], do: Map.put(attrs, "userIds", args.user_ids), else: attrs

          Client.create_shift(api_key, region, args.scheduler_id, attrs)

        "connecteam_delete_shift" ->
          Client.delete_shift(api_key, region, args.scheduler_id, args.shift_id)

        "connecteam_get_shift_layers" ->
          Client.get_shift_layers(api_key, region, args.scheduler_id)

        "connecteam_list_jobs" ->
          opts = []
          opts = if args[:limit], do: Keyword.put(opts, :limit, args.limit), else: opts
          opts = if args[:offset], do: Keyword.put(opts, :offset, args.offset), else: opts
          Client.list_jobs(api_key, region, opts)

        "connecteam_list_onboarding_packs" ->
          opts = []
          opts = if args[:limit], do: Keyword.put(opts, :limit, args.limit), else: opts
          opts = if args[:offset], do: Keyword.put(opts, :offset, args.offset), else: opts
          Client.list_onboarding_packs(api_key, region, opts)

        "connecteam_get_pack_assignments" ->
          opts = []
          opts = if args[:limit], do: Keyword.put(opts, :limit, args.limit), else: opts
          opts = if args[:offset], do: Keyword.put(opts, :offset, args.offset), else: opts
          Client.get_pack_assignments(api_key, region, args.pack_id, opts)

        "connecteam_assign_users_to_pack" ->
          attrs = %{"userIds" => args.user_ids}
          Client.assign_users_to_pack(api_key, region, args.pack_id, attrs)

        _ ->
          {:error, "Unknown Connecteam tool: #{tool_name}"}
      end

    case result do
      {:ok, data} when is_map(data) or is_list(data) -> {:ok, Jason.encode!(data)}
      {:ok, data} when is_binary(data) -> {:ok, data}
      :ok -> {:ok, "Success"}
      {:error, reason} -> {:error, to_string(reason)}
    end
  end

  defp build_rfc2822(args) do
    headers =
      ["To: #{args.to}", "Subject: #{args.subject}", "Content-Type: text/plain; charset=UTF-8"]

    headers = if args[:cc], do: headers ++ ["Cc: #{args.cc}"], else: headers
    headers = if args[:bcc], do: headers ++ ["Bcc: #{args.bcc}"], else: headers

    Enum.join(headers, "\r\n") <> "\r\n\r\n" <> args.body
  end

  defp build_calendar_event_params(args) do
    params = %{}
    params = if args[:summary], do: Map.put(params, "summary", args.summary), else: params

    params =
      if args[:description], do: Map.put(params, "description", args.description), else: params

    params = if args[:location], do: Map.put(params, "location", args.location), else: params

    params =
      if args[:start_time],
        do: Map.put(params, "start", %{"dateTime" => args.start_time}),
        else: params

    params =
      if args[:end_time],
        do: Map.put(params, "end", %{"dateTime" => args.end_time}),
        else: params

    params =
      if args[:attendees] do
        attendees = Enum.map(args.attendees, &%{"email" => &1})
        Map.put(params, "attendees", attendees)
      else
        params
      end

    params
  end

  defp broadcast_thinking(conversation_id, bot_id, thinking?) do
    Phoenix.PubSub.broadcast(
      Autoforge.PubSub,
      "conversation:#{conversation_id}",
      {:bot_thinking, bot_id, thinking?}
    )
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp maybe_put_anthropic_caching(opts, model) do
    if String.starts_with?(model, "anthropic:") do
      Keyword.put(opts, :anthropic_prompt_cache, true)
    else
      opts
    end
  end
end
