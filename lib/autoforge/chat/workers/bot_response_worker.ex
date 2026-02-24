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
