defmodule AutoforgeWeb.ConversationsLive do
  use AutoforgeWeb, :live_view

  alias Autoforge.Chat.Conversation

  require Ash.Query

  on_mount {AutoforgeWeb.LiveUserAuth, :live_user_required}

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user

    conversations =
      Conversation
      |> Ash.Query.sort(updated_at: :desc)
      |> Ash.Query.load([:bots, :messages])
      |> Ash.read!(actor: user)

    {:ok, assign(socket, page_title: "Conversations", conversations: conversations)}
  end

  defp last_message(conversation) do
    conversation.messages
    |> Enum.sort_by(& &1.inserted_at, {:desc, DateTime})
    |> List.first()
  end

  defp truncate(nil), do: ""

  defp truncate(text) when byte_size(text) > 80 do
    String.slice(text, 0, 80) <> "..."
  end

  defp truncate(text), do: text

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user} active_page={:conversations}>
      <div class="max-w-4xl mx-auto">
        <div class="flex items-center justify-between mb-6">
          <div>
            <h1 class="text-2xl font-bold tracking-tight">Conversations</h1>
            <p class="mt-2 text-base-content/70">
              Chat with your AI bots.
            </p>
          </div>
          <.link navigate={~p"/conversations/new"}>
            <.button variant="solid" color="primary">
              <.icon name="hero-plus" class="w-4 h-4 mr-1" /> New Conversation
            </.button>
          </.link>
        </div>

        <%= if @conversations == [] do %>
          <div class="card bg-base-200">
            <div class="card-body items-center text-center py-12">
              <.icon
                name="hero-chat-bubble-left-right"
                class="w-10 h-10 text-base-content/30 mb-2"
              />
              <p class="text-lg font-medium text-base-content/70">No conversations yet</p>
              <p class="text-sm text-base-content/50 mt-1">
                Start a conversation with one of your bots.
              </p>
              <.link navigate={~p"/conversations/new"} class="mt-4">
                <.button variant="solid" color="primary" size="sm">
                  <.icon name="hero-plus" class="w-4 h-4 mr-1" /> New Conversation
                </.button>
              </.link>
            </div>
          </div>
        <% else %>
          <div class="flex flex-col gap-2">
            <.link
              :for={conversation <- @conversations}
              navigate={~p"/conversations/#{conversation.id}"}
              class="card bg-base-200 hover:bg-base-300 transition-colors cursor-pointer"
            >
              <div class="card-body py-4 px-5">
                <div class="flex items-start justify-between gap-4">
                  <div class="flex-1 min-w-0">
                    <h3 class="font-semibold truncate">{conversation.subject}</h3>
                    <div class="flex items-center gap-2 mt-1.5">
                      <span
                        :for={bot <- conversation.bots}
                        class="badge badge-sm badge-ghost"
                      >
                        {bot.name}
                      </span>
                    </div>
                    <p
                      :if={msg = last_message(conversation)}
                      class="text-sm text-base-content/60 mt-1.5 truncate"
                    >
                      {truncate(msg.body)}
                    </p>
                  </div>
                  <span class="text-xs text-base-content/50 whitespace-nowrap pt-1">
                    {format_date(conversation.updated_at)}
                  </span>
                </div>
              </div>
            </.link>
          </div>
        <% end %>
      </div>
    </Layouts.app>
    """
  end
end
