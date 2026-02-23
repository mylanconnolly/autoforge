defmodule Autoforge.Accounts.LlmProviderKey do
  use Ash.Resource,
    otp_app: :autoforge,
    domain: Autoforge.Accounts,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshCloak]

  postgres do
    table "llm_provider_keys"
    repo Autoforge.Repo
  end

  cloak do
    vault(Autoforge.Vault)
    attributes([:value])
    decrypt_by_default([:value])
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      accept [:name, :provider, :value]
    end

    update :update do
      accept [:name, :value]
    end
  end

  policies do
    bypass AshAuthentication.Checks.AshAuthenticationInteraction do
      authorize_if always()
    end

    policy action_type([:create, :read, :update, :destroy]) do
      authorize_if actor_present()
    end
  end

  validations do
    validate {Autoforge.Accounts.Validations.ValidProvider, []} do
      on [:create]
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :provider, :atom do
      allow_nil? false
      public? true
    end

    attribute :name, :string do
      allow_nil? false
      public? true
      constraints max_length: 255
    end

    attribute :value, :string do
      allow_nil? false
      public? true
      constraints max_length: 1024
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  identities do
    identity :unique_name, [:name]
  end
end
