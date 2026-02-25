defmodule Autoforge.Config.GoogleServiceAccountConfig do
  use Ash.Resource,
    otp_app: :autoforge,
    domain: Autoforge.Config,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshCloak]

  postgres do
    table "google_service_account_configs"
    repo Autoforge.Repo
  end

  cloak do
    vault(Autoforge.Vault)
    attributes([:service_account_json])
    decrypt_by_default([:service_account_json])
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      accept [:service_account_json, :enabled]
      change {__MODULE__.ParseServiceAccountJson, []}
    end

    update :update do
      accept [:service_account_json, :enabled]
      require_atomic? false
      change {__MODULE__.ParseServiceAccountJson, []}
    end
  end

  policies do
    policy always() do
      authorize_if actor_present()
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :service_account_json, :string do
      allow_nil? false
      public? true
      constraints max_length: 1_000_000
    end

    attribute :client_email, :string do
      allow_nil? false
      public? true
    end

    attribute :project_id, :string do
      allow_nil? false
      public? true
    end

    attribute :enabled, :boolean do
      allow_nil? false
      public? true
      default true
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  defmodule ParseServiceAccountJson do
    @moduledoc false
    use Ash.Resource.Change

    @required_keys ["type", "project_id", "client_email", "private_key"]

    @impl true
    def change(changeset, _opts, _context) do
      case Ash.Changeset.fetch_argument(changeset, :service_account_json) do
        {:ok, json_string} when is_binary(json_string) ->
          case Jason.decode(json_string) do
            {:ok, parsed} ->
              missing = Enum.filter(@required_keys, &(not Map.has_key?(parsed, &1)))

              if missing == [] do
                changeset
                |> Ash.Changeset.force_change_attribute(:client_email, parsed["client_email"])
                |> Ash.Changeset.force_change_attribute(:project_id, parsed["project_id"])
              else
                Ash.Changeset.add_error(changeset,
                  field: :service_account_json,
                  message: "missing required keys: %{keys}",
                  vars: %{keys: Enum.join(missing, ", ")}
                )
              end

            {:error, _} ->
              Ash.Changeset.add_error(changeset,
                field: :service_account_json,
                message: "must be valid JSON"
              )
          end

        _ ->
          changeset
      end
    end
  end
end
