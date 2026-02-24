defmodule AutoforgeWeb.ModelsLive do
  use AutoforgeWeb, :live_view

  alias Autoforge.Accounts.LlmProviderKey

  require Ash.Query

  on_mount {AutoforgeWeb.LiveUserAuth, :live_user_required}

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user

    configured_provider_ids =
      LlmProviderKey
      |> Ash.Query.sort(provider: :asc)
      |> Ash.read!(actor: user)
      |> Enum.map(& &1.provider)
      |> Enum.uniq()
      |> MapSet.new()

    provider_groups =
      LLMDB.providers()
      |> Enum.filter(&MapSet.member?(configured_provider_ids, &1.id))
      |> Enum.map(fn provider ->
        models =
          LLMDB.models(provider.id)
          |> Enum.filter(&(&1.capabilities[:chat] == true && !&1.deprecated))
          |> Enum.sort_by(& &1.name)

        {provider, models}
      end)
      |> Enum.reject(fn {_provider, models} -> models == [] end)
      |> Enum.sort_by(fn {provider, _models} -> provider.name end)

    {:ok, assign(socket, page_title: "Models", provider_groups: provider_groups)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user} active_page={:models}>
      <div class="max-w-7xl mx-auto">
        <div class="mb-8">
          <h1 class="text-2xl font-bold tracking-tight">Models</h1>
          <p class="mt-2 text-base-content/70">
            Browse available LLM models by provider. Use this reference when configuring bots.
          </p>
        </div>

        <div :if={@provider_groups == []} class="card bg-base-200">
          <div class="card-body items-center text-center py-12">
            <.icon name="hero-rectangle-stack" class="w-10 h-10 text-base-content/30 mb-2" />
            <p class="text-lg font-medium text-base-content/70">No providers configured</p>
            <p class="text-sm text-base-content/50 mt-1">
              Add an API key in Settings to see available models.
            </p>
            <.link navigate={~p"/settings"} class="mt-4">
              <.button variant="solid" color="primary" size="sm">
                <.icon name="hero-cog-6-tooth" class="w-4 h-4 mr-1" /> Go to Settings
              </.button>
            </.link>
          </div>
        </div>

        <div :if={@provider_groups != []} class="space-y-10">
          <section :for={{provider, models} <- @provider_groups} id={"provider-#{provider.id}"}>
            <div class="flex items-center gap-3 mb-4">
              <h2 class="text-lg font-semibold">{provider.name}</h2>
              <span class="text-xs text-base-content/50 bg-base-200 px-2 py-0.5 rounded-full">
                {length(models)} {if length(models) == 1, do: "model", else: "models"}
              </span>
            </div>

            <.table>
              <.table_head>
                <:col>Name</:col>
                <:col>Model ID</:col>
                <:col>Context</:col>
                <:col>Max Output</:col>
                <:col>Knowledge</:col>
                <:col>Input / Output</:col>
                <:col>Cache R / W</:col>
                <:col>Capabilities</:col>
                <:col>Released</:col>
              </.table_head>
              <.table_body>
                <.table_row :for={model <- models}>
                  <:cell>
                    <span class="font-medium">{model.name}</span>
                  </:cell>
                  <:cell>
                    <code class="text-xs bg-base-200 px-1.5 py-0.5 rounded">{model.model}</code>
                  </:cell>
                  <:cell class="text-sm">
                    {format_token_count(model.limits[:context])}
                  </:cell>
                  <:cell class="text-sm">
                    {format_token_count(model.limits[:output])}
                  </:cell>
                  <:cell class="text-sm text-base-content/70">
                    {model.knowledge || "—"}
                  </:cell>
                  <:cell class="text-sm whitespace-nowrap">
                    {format_price(model.cost[:input])} / {format_price(model.cost[:output])}
                  </:cell>
                  <:cell class="text-sm text-base-content/70 whitespace-nowrap">
                    {format_cache_price(model.cost[:cache_read], model.cost[:cache_write])}
                  </:cell>
                  <:cell>
                    <div class="flex flex-wrap gap-1">
                      <span
                        :for={{label, color} <- capability_tags(model)}
                        class={[
                          "inline-flex items-center px-1.5 py-0.5 rounded text-[10px] font-medium",
                          capability_color(color)
                        ]}
                      >
                        {label}
                      </span>
                    </div>
                  </:cell>
                  <:cell class="text-sm text-base-content/70">
                    {model.release_date || "—"}
                  </:cell>
                </.table_row>
              </.table_body>
            </.table>
          </section>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp format_token_count(nil), do: "—"
  defp format_token_count(0), do: "—"

  defp format_token_count(n) when n >= 1_000_000 do
    value = n / 1_000_000

    formatted =
      if value == trunc(value), do: "#{trunc(value)}M", else: "#{Float.round(value, 1)}M"

    formatted
  end

  defp format_token_count(n) when n >= 1_000 do
    value = n / 1_000

    formatted =
      if value == trunc(value), do: "#{trunc(value)}K", else: "#{Float.round(value, 1)}K"

    formatted
  end

  defp format_token_count(n), do: to_string(n)

  defp format_price(nil), do: "—"
  defp format_price(n) when is_number(n) and n == 0, do: "$0"

  defp format_price(n) when is_number(n) do
    "$#{:erlang.float_to_binary(n / 1, decimals: 2)}"
  end

  defp format_cache_price(read, write) do
    has_read = is_number(read) && read > 0
    has_write = is_number(write) && write > 0

    cond do
      has_read && has_write -> "#{format_price(read)} / #{format_price(write)}"
      has_read -> "#{format_price(read)} / —"
      has_write -> "— / #{format_price(write)}"
      true -> "—"
    end
  end

  defp capability_tags(model) do
    tags = []

    tags =
      if model.capabilities[:tools] && model.capabilities[:tools][:enabled],
        do: tags ++ [{"tools", :blue}],
        else: tags

    tags =
      if model.capabilities[:reasoning] && model.capabilities[:reasoning][:enabled],
        do: tags ++ [{"reasoning", :purple}],
        else: tags

    tags =
      if model.modalities && :image in (model.modalities[:input] || []),
        do: tags ++ [{"vision", :green}],
        else: tags

    tags
  end

  defp capability_color(:blue), do: "bg-info/15 text-info"
  defp capability_color(:purple), do: "bg-secondary/15 text-secondary"
  defp capability_color(:green), do: "bg-success/15 text-success"
end
