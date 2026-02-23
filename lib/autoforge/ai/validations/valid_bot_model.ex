defmodule Autoforge.Ai.Validations.ValidBotModel do
  use Ash.Resource.Validation

  alias Autoforge.Accounts.LlmProviderKey

  require Ash.Query

  @impl true
  def validate(changeset, _opts, context) do
    case Ash.Changeset.get_attribute(changeset, :model) do
      nil ->
        :ok

      model_string ->
        with {:ok, {provider_id, model_id}} <- LLMDB.parse(model_string),
             {:ok, _model} <- LLMDB.model(provider_id, model_id),
             :ok <- verify_provider_key(provider_id, context.actor) do
          :ok
        else
          {:error, _} ->
            {:error,
             field: :model,
             message: "is not a valid model or you don't have a key for this provider"}
        end
    end
  end

  defp verify_provider_key(_provider_id, nil), do: {:error, :no_actor}

  defp verify_provider_key(provider_id, actor) do
    LlmProviderKey
    |> Ash.Query.filter(user_id == ^actor.id and provider == ^provider_id)
    |> Ash.read!(actor: actor)
    |> case do
      [_ | _] -> :ok
      [] -> {:error, :no_provider_key}
    end
  end
end
