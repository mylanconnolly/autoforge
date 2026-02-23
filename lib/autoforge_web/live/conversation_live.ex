defmodule AutoforgeWeb.ConversationLive do
  use AutoforgeWeb, :live_view

  alias Autoforge.Chat.{Conversation, Message}
  alias Autoforge.Markdown

  require Ash.Query

  on_mount {AutoforgeWeb.LiveUserAuth, :live_user_required}

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
        if connected?(socket), do: Phoenix.PubSub.subscribe(Autoforge.PubSub, topic)

        messages =
          conversation.messages
          |> Enum.sort_by(& &1.inserted_at, {:asc, DateTime})

        {:ok,
         assign(socket,
           page_title: conversation.subject,
           conversation: conversation,
           messages: messages,
           message_body: "",
           topic: topic
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
        {:ok, message} ->
          message = Ash.load!(message, [:user, :bot], actor: user)

          Phoenix.PubSub.broadcast(
            Autoforge.PubSub,
            socket.assigns.topic,
            {:new_message, message}
          )

          {:noreply, assign(socket, message_body: "")}

        {:error, _changeset} ->
          {:noreply, put_flash(socket, :error, "Failed to send message.")}
      end
    end
  end

  @impl true
  def handle_info({:new_message, message}, socket) do
    {:noreply, assign(socket, messages: socket.assigns.messages ++ [message])}
  end

  defp message_sender(message) do
    case message.role do
      :user -> (message.user && (message.user.name || to_string(message.user.email))) || "User"
      :bot -> (message.bot && message.bot.name) || "Bot"
    end
  end

  defp format_time(datetime) do
    Calendar.strftime(datetime, "%I:%M %p")
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
              <span
                :for={bot <- @conversation.bots}
                class="badge badge-xs badge-ghost"
              >
                {bot.name}
              </span>
            </div>
          </div>
        </header>

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
                <p
                  :if={message.role == :bot}
                  class="text-xs font-semibold mb-1 opacity-70"
                >
                  {message_sender(message)}
                </p>
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
        </div>

        <div class="border-t border-base-300 bg-base-100 px-5 py-3">
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
end
