defmodule AutoforgeWeb.ConversationLive do
  use AutoforgeWeb, :live_view

  alias Autoforge.Chat.{Conversation, Message}
  alias Autoforge.Markdown

  require Ash.Query

  on_mount {AutoforgeWeb.LiveUserAuth, :live_user_required}

  @bytes_per_token 4
  @default_context_limit 8192

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    user = socket.assigns.current_user

    conversation =
      Conversation
      |> Ash.Query.filter(id == ^id)
      |> Ash.Query.load([:bots, :participants, messages: [:user, :bot]])
      |> Ash.read_one!(actor: user)

    case conversation do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, "Conversation not found.")
         |> push_navigate(to: ~p"/conversations")}

      conversation ->
        topic = "conversation:#{conversation.id}"
        if connected?(socket), do: AutoforgeWeb.Endpoint.subscribe(topic)

        messages =
          conversation.messages
          |> Enum.sort_by(& &1.inserted_at, {:asc, DateTime})

        context_limit = conversation_context_limit(conversation)
        context_usage = compute_context_usage(messages, context_limit)
        bot_info = build_bot_info(conversation.bots)

        {:ok,
         assign(socket,
           page_title: conversation.subject,
           conversation: conversation,
           messages: messages,
           message_body: "",
           topic: topic,
           thinking_bots: MapSet.new(),
           context_limit: context_limit,
           context_usage: context_usage,
           bot_info: bot_info
         )}
    end
  end

  @impl true
  def handle_event("send", %{"body" => body}, socket) do
    body = String.trim(body)

    if body == "" do
      {:noreply, socket}
    else
      user = socket.assigns.current_user
      conversation = socket.assigns.conversation

      case Ash.create(
             Message
             |> Ash.Changeset.for_create(:create, %{
               body: body,
               role: :user,
               conversation_id: conversation.id
             }),
             actor: user
           ) do
        {:ok, _message} ->
          {:noreply, assign(socket, message_body: "")}

        {:error, _changeset} ->
          {:noreply, put_flash(socket, :error, "Failed to send message.")}
      end
    end
  end

  @impl true
  def handle_info(
        %Phoenix.Socket.Broadcast{
          event: "create",
          payload: %Ash.Notifier.Notification{data: message}
        },
        socket
      ) do
    message = Ash.load!(message, [:user, :bot], authorize?: false)
    messages = socket.assigns.messages ++ [message]
    context_usage = compute_context_usage(messages, socket.assigns.context_limit)

    {:noreply, assign(socket, messages: messages, context_usage: context_usage)}
  end

  def handle_info({:bot_thinking, bot_id, true}, socket) do
    {:noreply, assign(socket, thinking_bots: MapSet.put(socket.assigns.thinking_bots, bot_id))}
  end

  def handle_info({:bot_thinking, bot_id, false}, socket) do
    {:noreply, assign(socket, thinking_bots: MapSet.delete(socket.assigns.thinking_bots, bot_id))}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  defp message_sender(message) do
    case message.role do
      :user -> (message.user && (message.user.name || to_string(message.user.email))) || "User"
      :bot -> (message.bot && message.bot.name) || "Bot"
    end
  end

  defp format_time(datetime) do
    Calendar.strftime(datetime, "%I:%M %p")
  end

  defp get_bot_info(bot_id, bot_info) do
    Map.get(bot_info, bot_id, %{name: "Bot", model_name: nil, description: nil})
  end

  defp bot_name(bot_id, bot_info) do
    get_bot_info(bot_id, bot_info).name
  end

  defp build_bot_info(bots) do
    Map.new(bots, fn bot ->
      model_name = humanize_model(bot.model)
      {bot.id, %{name: bot.name, model_name: model_name, description: bot.description}}
    end)
  end

  defp humanize_model(model_spec) do
    with {:ok, model} <- LLMDB.model(model_spec),
         {:ok, provider} <- LLMDB.provider(model.provider) do
      "#{provider.name} #{model.name}"
    else
      _ -> model_spec
    end
  end

  defp multi_participant?(conversation) do
    length(conversation.bots) > 1 || length(conversation.participants) > 1
  end

  defp conversation_context_limit(conversation) do
    conversation.bots
    |> Enum.map(fn bot ->
      case LLMDB.model(bot.model) do
        {:ok, model} -> model.limits[:context] || @default_context_limit
        _ -> @default_context_limit
      end
    end)
    |> Enum.min(fn -> @default_context_limit end)
  end

  defp compute_context_usage(messages, context_limit) do
    total_bytes = Enum.reduce(messages, 0, fn msg, acc -> acc + byte_size(msg.body) end)
    estimated_tokens = div(total_bytes, @bytes_per_token)
    min(estimated_tokens / context_limit, 1.0)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user} active_page={:conversations}>
      <div class="flex flex-col h-[calc(100vh-3rem)] -my-6 -mx-4 sm:-mx-6 lg:-mx-8">
        <header class="flex items-center gap-3 px-5 py-3 border-b border-base-300 bg-base-200/50">
          <.link
            navigate={~p"/conversations"}
            class="text-base-content/60 hover:text-base-content transition-colors"
          >
            <.icon name="hero-arrow-left" class="w-5 h-5" />
          </.link>
          <div class="flex-1 min-w-0">
            <h1 class="text-lg font-semibold truncate">{@conversation.subject}</h1>
            <div class="flex items-center gap-1.5 mt-0.5">
              <.tooltip :for={bot <- @conversation.bots} placement="bottom" class="w-48">
                <span class="badge badge-xs badge-ghost cursor-help">{bot.name}</span>
                <:content>
                  <.bot_tooltip_content info={get_bot_info(bot.id, @bot_info)} />
                </:content>
              </.tooltip>
            </div>
          </div>
        </header>

        <.context_warning :if={@context_usage > 0.7} usage={@context_usage} />

        <div id="messages" phx-hook="ChatScroll" class="flex-1 overflow-y-auto px-5 py-4 space-y-4">
          <div
            :if={@messages == []}
            class="flex flex-col items-center justify-center h-full text-base-content/40"
          >
            <.icon name="hero-chat-bubble-left-right" class="w-12 h-12 mb-3" />
            <p class="text-lg font-medium">Start the conversation</p>
            <p class="text-sm mt-1">Send a message below to get started.</p>
          </div>

          <div :for={message <- @messages} class="flex flex-col">
            <div class={[
              "flex",
              if(message.role == :user, do: "justify-end", else: "justify-start")
            ]}>
              <div class={[
                "max-w-[75%] rounded-2xl px-4 py-2.5",
                if(message.role == :user,
                  do: "bg-primary text-primary-content rounded-br-md",
                  else: "bg-base-200 text-base-content rounded-bl-md"
                )
              ]}>
                <div :if={message.role == :bot} class="mb-1">
                  <.tooltip placement="right" class="w-48">
                    <span class="text-xs font-semibold opacity-70 cursor-help">
                      {message_sender(message)}
                    </span>
                    <:content>
                      <.bot_tooltip_content info={get_bot_info(message.bot_id, @bot_info)} />
                    </:content>
                  </.tooltip>
                </div>
                <div class="prose prose-sm max-w-none [&>*:first-child]:mt-0 [&>*:last-child]:mb-0">
                  {Markdown.to_html(message.body)}
                </div>
              </div>
            </div>
            <span class={[
              "text-[10px] text-base-content/40 mt-1 px-1",
              if(message.role == :user, do: "text-right", else: "text-left")
            ]}>
              {message_sender(message)} · {format_time(message.inserted_at)}
            </span>
          </div>

          <div :for={bot_id <- @thinking_bots} class="flex justify-start">
            <div class="bg-base-200 rounded-2xl px-4 py-2.5 rounded-bl-md">
              <div class="mb-1">
                <.tooltip placement="right" class="w-48">
                  <span class="text-xs font-semibold opacity-70 cursor-help">
                    {bot_name(bot_id, @bot_info)}
                  </span>
                  <:content>
                    <.bot_tooltip_content info={get_bot_info(bot_id, @bot_info)} />
                  </:content>
                </.tooltip>
              </div>
              <div class="flex gap-1 items-center py-1">
                <span class="w-2 h-2 bg-base-content/40 rounded-full animate-bounce [animation-delay:0ms]" />
                <span class="w-2 h-2 bg-base-content/40 rounded-full animate-bounce [animation-delay:150ms]" />
                <span class="w-2 h-2 bg-base-content/40 rounded-full animate-bounce [animation-delay:300ms]" />
              </div>
            </div>
          </div>
        </div>

        <div class="border-t border-base-300 bg-base-100 px-5 py-3">
          <p
            :if={multi_participant?(@conversation)}
            class="text-xs text-base-content/40 mb-1"
          >
            Mention a bot: {Enum.map_join(@conversation.bots, ", ", &"@#{&1.name}")}
          </p>
          <form phx-submit="send" class="flex items-end gap-3">
            <div class="flex-1">
              <textarea
                name="body"
                placeholder="Type a message..."
                rows="1"
                class="textarea textarea-bordered w-full min-h-[2.5rem] max-h-32 resize-none"
              >{@message_body}</textarea>
            </div>
            <.button type="submit" variant="solid" color="primary" class="shrink-0">
              <.icon name="hero-paper-airplane" class="w-5 h-5" />
            </.button>
          </form>
        </div>
      </div>
    </Layouts.app>
    """
  end

  attr :info, :map, required: true

  defp bot_tooltip_content(assigns) do
    ~H"""
    <div class="space-y-1">
      <p class="font-semibold">{@info.name}</p>
      <p :if={@info.model_name} class="opacity-70">{@info.model_name}</p>
      <p :if={@info.description} class="opacity-50 leading-relaxed">{@info.description}</p>
    </div>
    """
  end

  defp context_warning(assigns) do
    ~H"""
    <div class={[
      "px-5 py-2 text-xs flex items-center gap-2 border-b",
      if(@usage > 0.9,
        do: "bg-error/10 text-error border-error/20",
        else: "bg-warning/10 text-warning border-warning/20"
      )
    ]}>
      <.icon name="hero-exclamation-triangle" class="w-4 h-4 shrink-0" />
      <span :if={@usage > 0.9}>
        Conversation is near the context limit. Consider starting a new conversation.
      </span>
      <span :if={@usage <= 0.9}>
        Conversation is using most of the context window. Older messages may be truncated for bot responses.
      </span>
    </div>
    """
  end
end
