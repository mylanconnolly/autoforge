defmodule AutoforgeWeb.ConversationFormLive do
  use AutoforgeWeb, :live_view

  alias Autoforge.Ai.Bot
  alias Autoforge.Chat.Conversation

  require Ash.Query

  on_mount {AutoforgeWeb.LiveUserAuth, :live_user_required}

  @impl true
  def mount(params, _session, socket) do
    user = socket.assigns.current_user

    bots =
      Bot
      |> Ash.Query.filter(user_id == ^user.id)
      |> Ash.Query.sort(name: :asc)
      |> Ash.read!(actor: user)

    bot_options = Enum.map(bots, fn bot -> {bot.name, bot.id} end)

    pre_selected =
      case params do
        %{"bot_id" => bot_id} -> [bot_id]
        _ -> []
      end

    form =
      Conversation
      |> AshPhoenix.Form.for_create(:create,
        actor: user,
        forms: [auto?: true]
      )
      |> AshPhoenix.Form.validate(%{"subject" => "", "bot_ids" => pre_selected})
      |> to_form()

    {:ok,
     assign(socket,
       page_title: "New Conversation",
       form: form,
       bot_options: bot_options,
       selected_bots: pre_selected
     )}
  end

  @impl true
  def handle_event("validate", %{"form" => params}, socket) do
    params = Map.update(params, "bot_ids", [], fn ids -> Enum.reject(ids, &(&1 == "")) end)
    selected = Map.get(params, "bot_ids", [])

    form =
      socket.assigns.form.source
      |> AshPhoenix.Form.validate(params)
      |> to_form()

    {:noreply, assign(socket, form: form, selected_bots: selected)}
  end

  def handle_event("save", %{"form" => params}, socket) do
    params = Map.update(params, "bot_ids", [], fn ids -> Enum.reject(ids, &(&1 == "")) end)

    case AshPhoenix.Form.submit(socket.assigns.form.source, params: params) do
      {:ok, conversation} ->
        {:noreply,
         socket
         |> put_flash(:info, "Conversation created.")
         |> push_navigate(to: ~p"/conversations/#{conversation.id}")}

      {:error, form} ->
        {:noreply, assign(socket, form: to_form(form))}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user} active_page={:conversations}>
      <div class="max-w-2xl mx-auto">
        <div class="mb-6">
          <.link
            navigate={~p"/conversations"}
            class="text-sm text-base-content/60 hover:text-base-content transition-colors"
          >
            <.icon name="hero-arrow-left" class="w-4 h-4 inline-block mr-1" /> Back to Conversations
          </.link>
          <h1 class="text-2xl font-bold tracking-tight mt-2">New Conversation</h1>
          <p class="mt-2 text-base-content/70">
            Start a new conversation with your bots.
          </p>
        </div>

        <div class="card bg-base-200 shadow-sm">
          <div class="card-body">
            <.form for={@form} phx-change="validate" phx-submit="save" class="space-y-4">
              <.input
                field={@form[:subject]}
                label="Subject"
                placeholder="What would you like to discuss?"
              />

              <.select
                name="form[bot_ids][]"
                label="Bots"
                placeholder="Select bots..."
                options={@bot_options}
                value={@selected_bots}
                multiple
                searchable
                search_input_placeholder="Search bots..."
              />

              <div class="flex items-center gap-3 pt-2">
                <.button type="submit" variant="solid" color="primary">
                  Start Conversation
                </.button>
                <.link navigate={~p"/conversations"}>
                  <.button type="button" variant="ghost">
                    Cancel
                  </.button>
                </.link>
              </div>
            </.form>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
