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

  alias Autoforge.Accounts.LlmProviderKey
  alias Autoforge.Ai.Bot
  alias Autoforge.Chat.{Conversation, Message}

  import ReqLLM.Context, only: [user: 1, assistant: 1]

  require Ash.Query
  require Logger

  @default_context_limit 8192
  @context_usage_ratio 0.8
  @bytes_per_token 4

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"bot_id" => bot_id, "conversation_id" => conversation_id}}) do
    with {:ok, bot} <- load_bot(bot_id),
         {:ok, conversation} <- load_conversation(conversation_id),
         {:ok, api_key} <- fetch_api_key(bot) do
      broadcast_thinking(conversation_id, bot_id, true)

      try do
        generate_and_create_response(bot, conversation, api_key)
      after
        broadcast_thinking(conversation_id, bot_id, false)
      end
    end
  end

  defp load_bot(bot_id) do
    case Ash.get(Bot, bot_id, load: [:user], authorize?: false) do
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

  defp fetch_api_key(bot) do
    with {:ok, {provider_id, _model_id}} <- LLMDB.parse(bot.model) do
      key =
        LlmProviderKey
        |> Ash.Query.filter(user_id == ^bot.user_id and provider == ^provider_id)
        |> Ash.read_one!(authorize?: false)

      case key do
        nil -> {:cancel, "no API key for provider #{provider_id}"}
        key -> {:ok, key.value}
      end
    else
      {:error, reason} -> {:cancel, "invalid model spec: #{inspect(reason)}"}
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

    opts =
      [api_key: api_key, system_prompt: system_prompt]
      |> maybe_put(:temperature, bot.temperature && Decimal.to_float(bot.temperature))
      |> maybe_put(:max_tokens, bot.max_tokens)

    case ReqLLM.generate_text(bot.model, truncated, opts) do
      {:ok, response} ->
        response_text = ReqLLM.Response.text(response)

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

        :ok

      {:error, %{status: status}} when status in [401, 403] ->
        {:cancel, "authentication failed (HTTP #{status})"}

      {:error, reason} ->
        Logger.warning("Bot response failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

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

  defp broadcast_thinking(conversation_id, bot_id, thinking?) do
    Phoenix.PubSub.broadcast(
      Autoforge.PubSub,
      "conversation:#{conversation_id}",
      {:bot_thinking, bot_id, thinking?}
    )
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
