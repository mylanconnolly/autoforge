defmodule Autoforge.Chat.BotDispatcher do
  @moduledoc """
  Determines which bots should respond to a user message and enqueues
  Oban jobs for each responding bot.

  ## Rules

  - **Single bot, single user**: the bot always responds.
  - **Multiple participants**: only bots explicitly `@mentioned` in the
    message body respond. If no bot is mentioned, no bot responds.
  """

  alias Autoforge.Chat.Conversation
  alias Autoforge.Chat.Workers.BotResponseWorker

  require Ash.Query

  @doc """
  Dispatches bot response jobs for the given user message.

  Loads the conversation's bots and participants, applies the mention
  rules, and enqueues an Oban job for each bot that should respond.
  """
  def dispatch(%{conversation_id: conversation_id} = message) do
    conversation =
      Conversation
      |> Ash.Query.filter(id == ^conversation_id)
      |> Ash.Query.load([:bots, :participants])
      |> Ash.read_one!(authorize?: false)

    bots = responding_bots(message.body, conversation.bots, conversation.participants)

    Enum.each(bots, fn bot ->
      %{message_id: message.id, bot_id: bot.id, conversation_id: conversation_id}
      |> BotResponseWorker.new()
      |> Oban.insert!()
    end)
  end

  defp responding_bots(_body, [single_bot], [_single_participant]) do
    [single_bot]
  end

  defp responding_bots(body, bots, _participants) do
    case mentioned_bots(body, bots) do
      [] -> []
      mentioned -> mentioned
    end
  end

  @doc """
  Returns the bots whose names appear after an `@` in the message body.

  Matching is case-insensitive.
  """
  def mentioned_bots(body, bots) do
    body_lower = String.downcase(body)

    Enum.filter(bots, fn bot ->
      name_lower = String.downcase(bot.name)
      String.contains?(body_lower, "@#{name_lower}")
    end)
  end
end
