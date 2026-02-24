defmodule AutoforgeWeb.BotFormLive do
  use AutoforgeWeb, :live_view

  alias Autoforge.Accounts.LlmProviderKey
  alias Autoforge.Ai.Bot

  require Ash.Query

  on_mount {AutoforgeWeb.LiveUserAuth, :live_user_required}

  @impl true
  def mount(params, _session, socket) do
    user = socket.assigns.current_user
    provider_keys = load_provider_keys(user)
    key_options = build_key_options(provider_keys)
    model_options = build_model_options(provider_keys)

    case params do
      %{"id" => id} ->
        bot =
          Bot
          |> Ash.Query.filter(id == ^id)
          |> Ash.read_one!(actor: user)

        if bot do
          form =
            bot
            |> AshPhoenix.Form.for_update(:update, actor: user)
            |> to_form()

          {:ok,
           assign(socket,
             page_title: "Edit Bot",
             form: form,
             key_options: key_options,
             model_options: model_options,
             editing?: true
           )}
        else
          {:ok,
           socket
           |> put_flash(:error, "Bot not found.")
           |> push_navigate(to: ~p"/bots")}
        end

      _ ->
        form =
          Bot
          |> AshPhoenix.Form.for_create(:create, actor: user)
          |> to_form()

        {:ok,
         assign(socket,
           page_title: "New Bot",
           form: form,
           key_options: key_options,
           model_options: model_options,
           editing?: false
         )}
    end
  end

  @impl true
  def handle_event("validate", %{"form" => params}, socket) do
    form =
      socket.assigns.form.source
      |> AshPhoenix.Form.validate(params)
      |> to_form()

    {:noreply, assign(socket, form: form)}
  end

  def handle_event("save", %{"form" => params}, socket) do
    case AshPhoenix.Form.submit(socket.assigns.form.source, params: params) do
      {:ok, bot} ->
        action = if socket.assigns.editing?, do: "updated", else: "created"

        {:noreply,
         socket
         |> put_flash(:info, "Bot #{action} successfully.")
         |> push_navigate(to: ~p"/bots/#{bot.id}")}

      {:error, form} ->
        {:noreply, assign(socket, form: to_form(form))}
    end
  end

  defp load_provider_keys(user) do
    LlmProviderKey
    |> Ash.Query.sort(provider: :asc)
    |> Ash.read!(actor: user)
  end

  defp build_key_options(provider_keys) do
    provider_keys
    |> Enum.sort_by(fn key -> {key.provider, key.name} end)
    |> Enum.map(fn key ->
      provider_name =
        case LLMDB.provider(key.provider) do
          {:ok, p} -> p.name
          _ -> to_string(key.provider)
        end

      {"#{provider_name} — #{key.name}", key.id}
    end)
  end

  defp build_model_options(provider_keys) do
    provider_keys
    |> Enum.sort_by(& &1.provider)
    |> Enum.map(& &1.provider)
    |> Enum.uniq()
    |> Enum.flat_map(fn provider_id ->
      provider_name =
        case LLMDB.provider(provider_id) do
          {:ok, p} -> p.name
          _ -> to_string(provider_id)
        end

      LLMDB.models(provider_id)
      |> Enum.filter(fn m -> m.capabilities && m.capabilities[:chat] end)
      |> Enum.sort_by(fn m -> m.name || m.id end)
      |> Enum.map(fn m ->
        label = "#{provider_name} — #{m.name || m.id}"
        value = "#{provider_id}:#{m.id}"
        {label, value}
      end)
    end)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user} active_page={:bots}>
      <div class="max-w-2xl mx-auto">
        <div class="mb-6">
          <.link
            navigate={~p"/bots"}
            class="text-sm text-base-content/60 hover:text-base-content transition-colors"
          >
            <.icon name="hero-arrow-left" class="w-4 h-4 inline-block mr-1" /> Back to Bots
          </.link>
          <h1 class="text-2xl font-bold tracking-tight mt-2">
            {if @editing?, do: "Edit Bot", else: "New Bot"}
          </h1>
          <p class="mt-2 text-base-content/70">
            {if @editing?, do: "Update your bot's configuration.", else: "Configure a new AI bot."}
          </p>
        </div>

        <div class="card bg-base-200 shadow-sm">
          <div class="card-body">
            <.form for={@form} phx-change="validate" phx-submit="save" class="space-y-4">
              <.input
                field={@form[:name]}
                label="Name"
                placeholder="My Assistant"
              />

              <.textarea
                field={@form[:description]}
                label="Description"
                placeholder="A helpful assistant for..."
                rows={3}
              />

              <.select
                field={@form[:llm_provider_key_id]}
                label="Provider Key"
                placeholder="Select a provider key..."
                options={@key_options}
                searchable
                search_input_placeholder="Search keys..."
              />

              <.select
                field={@form[:model]}
                label="Model"
                placeholder="Select a model..."
                options={@model_options}
                searchable
                search_input_placeholder="Search models..."
              />

              <.textarea
                field={@form[:system_prompt]}
                label="System Prompt"
                placeholder="You are a helpful assistant..."
                rows={5}
              />

              <div class="grid grid-cols-2 gap-4">
                <.input
                  field={@form[:temperature]}
                  type="number"
                  label="Temperature"
                  step="0.1"
                  min="0"
                  max="2"
                />

                <.input
                  field={@form[:max_tokens]}
                  type="number"
                  label="Max Tokens"
                  min="1"
                  placeholder="Optional"
                />
              </div>

              <div class="flex items-center gap-3 pt-2">
                <.button type="submit" variant="solid" color="primary">
                  {if @editing?, do: "Save Changes", else: "Create Bot"}
                </.button>
                <.link navigate={~p"/bots"}>
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
