defmodule Autoforge.Ai.Validations.ValidBotModel do
  use Ash.Resource.Validation

  @impl true
  def validate(changeset, _opts, _context) do
    model = Ash.Changeset.get_attribute(changeset, :model)
    key_id = Ash.Changeset.get_attribute(changeset, :llm_provider_key_id)

    case model do
      nil ->
        :ok

      model_string ->
        with {:ok, {provider_id, model_id}} <- LLMDB.parse(model_string),
             {:ok, _model} <- LLMDB.model(provider_id, model_id),
             :ok <- verify_key_provider_match(key_id, provider_id) do
          :ok
        else
          {:error, _} ->
            {:error,
             field: :model,
             message: "is not a valid model or the selected key doesn't match this provider"}
        end
    end
  end

  defp verify_key_provider_match(nil, _provider_id), do: :ok

  defp verify_key_provider_match(key_id, provider_id) do
    case Ash.get(Autoforge.Accounts.LlmProviderKey, key_id, authorize?: false) do
      {:ok, %{provider: ^provider_id}} -> :ok
      {:ok, _} -> {:error, :provider_mismatch}
      _ -> {:error, :key_not_found}
    end
  end
end
