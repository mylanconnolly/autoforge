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
      |> Ash.Query.load([:bots, :participants, messages: [:user, :bot, :tool_invocations]])
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
           tools_expanded: MapSet.new(),
           context_limit: context_limit,
           context_usage: context_usage,
           bot_info: bot_info
         )}
    end
  end

  @impl true
  def handle_event("delete", _params, socket) do
    user = socket.assigns.current_user
    conversation = socket.assigns.conversation

    Ash.destroy!(conversation, actor: user)

    {:noreply,
     socket
     |> put_flash(:info, "Conversation deleted.")
     |> push_navigate(to: ~p"/conversations")}
  end

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
          {:noreply,
           socket
           |> assign(message_body: "")
           |> push_event("clear_input", %{})}

        {:error, _changeset} ->
          {:noreply, put_flash(socket, :error, "Failed to send message.")}
      end
    end
  end

  @impl true
  def handle_event("toggle_tools", %{"message-id" => id}, socket) do
    tools_expanded = socket.assigns.tools_expanded

    tools_expanded =
      if MapSet.member?(tools_expanded, id) do
        MapSet.delete(tools_expanded, id)
      else
        MapSet.put(tools_expanded, id)
      end

    {:noreply, assign(socket, tools_expanded: tools_expanded)}
  end

  @impl true
  def handle_info(
        %Phoenix.Socket.Broadcast{
          event: "create",
          payload: %Ash.Notifier.Notification{data: message}
        },
        socket
      ) do
    message = Ash.load!(message, [:user, :bot, :tool_invocations], authorize?: false)
    messages = socket.assigns.messages ++ [message]
    context_usage = compute_context_usage(messages, socket.assigns.context_limit)

    {:noreply, assign(socket, messages: messages, context_usage: context_usage)}
  end

  def handle_info({:tool_invocations_saved, message_id}, socket) do
    messages =
      Enum.map(socket.assigns.messages, fn msg ->
        if msg.id == message_id do
          Ash.load!(msg, [:tool_invocations], authorize?: false)
        else
          msg
        end
      end)

    {:noreply, assign(socket, messages: messages)}
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
      <div class="flex flex-col h-screen -my-6 -mx-4 sm:-mx-6 lg:-mx-8">
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
          <.dropdown placement="bottom-end">
            <:toggle>
              <button class="p-1.5 rounded-lg hover:bg-base-300 transition-colors">
                <.icon name="hero-ellipsis-vertical" class="w-5 h-5 text-base-content/60" />
              </button>
            </:toggle>
            <.dropdown_button
              phx-click="delete"
              data-confirm="Are you sure you want to delete this conversation? All messages will be lost."
              class="text-error"
            >
              <.icon name="hero-trash" class="w-4 h-4 mr-2" /> Delete conversation
            </.dropdown_button>
          </.dropdown>
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
                  do: "bg-base-200 text-base-content rounded-br-md",
                  else: "bg-info/10 text-base-content rounded-bl-md"
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
                <div class={[
                  "prose prose-sm max-w-none dark:prose-invert [&>*:first-child]:mt-0 [&>*:last-child]:mb-0",
                  if(message.role == :bot, do: "prose-bot")
                ]}>
                  {Markdown.to_html(message.body)}
                </div>
                <.tool_invocations_panel
                  :if={message.role == :bot && message.tool_invocations != []}
                  message={message}
                  expanded={MapSet.member?(@tools_expanded, message.id)}
                />
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
          <form phx-submit="send" class="flex items-end gap-2">
            <textarea
              id="chat-input"
              name="body"
              placeholder="Type a message..."
              rows="1"
              phx-hook="ChatInput"
              class="flex-1 min-h-9 max-h-32 resize-none bg-input text-foreground border border-input rounded-base shadow-base px-3 py-1.5 text-sm outline-hidden placeholder:text-foreground-softest focus-visible:border-focus focus-visible:ring-3 focus-visible:ring-focus transition-[box-shadow] duration-100"
            >{@message_body}</textarea>
            <.button type="submit" variant="solid" color="primary" class="shrink-0 mb-px">
              <.icon name="hero-paper-airplane" class="w-5 h-5" />
            </.button>
          </form>
        </div>
      </div>
    </Layouts.app>
    """
  end

  attr :message, :map, required: true
  attr :expanded, :boolean, required: true

  defp tool_invocations_panel(assigns) do
    count = length(assigns.message.tool_invocations)
    assigns = assign(assigns, count: count)

    ~H"""
    <div class="mt-2 border-t border-base-content/10 pt-2">
      <button
        phx-click="toggle_tools"
        phx-value-message-id={@message.id}
        class="inline-flex items-center gap-1.5 text-xs text-base-content/60 hover:text-base-content transition-colors cursor-pointer"
      >
        <.icon name="hero-wrench-screwdriver" class="w-3.5 h-3.5" />
        {@count} tool {if(@count == 1, do: "call", else: "calls")}
        <.icon name={if(@expanded, do: "hero-chevron-up", else: "hero-chevron-down")} class="w-3 h-3" />
      </button>

      <div :if={@expanded} class="mt-2 space-y-2">
        <.tool_invocation_row :for={inv <- @message.tool_invocations} inv={inv} />
      </div>
    </div>
    """
  end

  attr :inv, :map, required: true

  defp tool_invocation_row(assigns) do
    args_json =
      case Jason.encode(assigns.inv.arguments, pretty: true) do
        {:ok, json} -> json
        _ -> inspect(assigns.inv.arguments)
      end

    assigns = assign(assigns, args_json: args_json)

    ~H"""
    <div class="rounded-lg bg-base-200/50 p-2.5 text-xs">
      <div class="flex items-center gap-2 mb-1.5">
        <code class="font-mono font-semibold text-base-content/80">{@inv.tool_name}</code>
        <span class={[
          "badge badge-xs",
          if(@inv.status == :ok, do: "badge-success", else: "badge-error")
        ]}>
          {@inv.status}
        </span>
      </div>
      <details class="group">
        <summary class="cursor-pointer text-base-content/50 hover:text-base-content/70 transition-colors select-none">
          Arguments
        </summary>
        <pre class="mt-1 p-2 rounded bg-base-300/50 overflow-x-auto text-[11px] leading-relaxed whitespace-pre-wrap break-all"><code>{@args_json}</code></pre>
      </details>
      <details :if={@inv.result} class="group mt-1">
        <summary class="cursor-pointer text-base-content/50 hover:text-base-content/70 transition-colors select-none">
          Result
        </summary>
        <pre class="mt-1 p-2 rounded bg-base-300/50 overflow-x-auto text-[11px] leading-relaxed whitespace-pre-wrap break-all max-h-48"><code>{@inv.result}</code></pre>
      </details>
    </div>
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
