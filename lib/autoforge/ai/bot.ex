defmodule Autoforge.Ai.Bot do
  use Ash.Resource,
    otp_app: :autoforge,
    domain: Autoforge.Ai,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "bots"
    repo Autoforge.Repo
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      accept [:name, :description, :system_prompt, :model, :temperature, :max_tokens]
      change relate_actor(:user)
    end

    update :update do
      accept [:name, :description, :system_prompt, :model, :temperature, :max_tokens]
      require_atomic? false
    end
  end

  policies do
    bypass AshAuthentication.Checks.AshAuthenticationInteraction do
      authorize_if always()
    end

    policy action_type(:create) do
      authorize_if actor_present()
    end

    policy action_type([:read, :update, :destroy]) do
      authorize_if expr(user_id == ^actor(:id))
    end
  end

  validations do
    validate {Autoforge.Ai.Validations.ValidBotModel, []} do
      on [:create, :update]
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :name, :string do
      allow_nil? false
      public? true
      constraints max_length: 255
    end

    attribute :description, :string do
      allow_nil? true
      public? true
    end

    attribute :system_prompt, :string do
      allow_nil? true
      public? true
    end

    attribute :model, :string do
      allow_nil? false
      public? true
      constraints max_length: 255
    end

    attribute :temperature, :decimal do
      allow_nil? true
      public? true
      default 0.7
      constraints min: 0, max: 2
    end

    attribute :max_tokens, :integer do
      allow_nil? true
      public? true
      constraints min: 1
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :user, Autoforge.Accounts.User do
      allow_nil? false
      attribute_writable? false
    end
  end

  identities do
    identity :unique_name_per_user, [:user_id, :name]
  end
end
