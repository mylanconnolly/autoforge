defmodule Autoforge.Config.ConnecteamApiKeyConfig do
  use Ash.Resource,
    otp_app: :autoforge,
    domain: Autoforge.Config,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshCloak, AshPaperTrail.Resource]

  postgres do
    table "connecteam_api_key_configs"
    repo Autoforge.Repo
  end

  cloak do
    vault(Autoforge.Vault)
    attributes([:api_key])
    decrypt_by_default([:api_key])
  end

  paper_trail do
    primary_key_type :uuid_v7
    change_tracking_mode :changes_only
    store_action_name? true
    reference_source? false
    sensitive_attributes :redact
    ignore_attributes [:inserted_at, :updated_at]
    belongs_to_actor :user, Autoforge.Accounts.User, domain: Autoforge.Accounts
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      accept [:label, :api_key, :region, :enabled]
    end

    update :update do
      accept [:label, :api_key, :region, :enabled]
      require_atomic? false
    end
  end

  policies do
    policy always() do
      authorize_if actor_present()
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :label, :string do
      allow_nil? false
      public? true
    end

    attribute :api_key, :string do
      allow_nil? false
      public? true
    end

    attribute :region, :atom do
      allow_nil? false
      public? true
      default :global
      constraints one_of: [:global, :australia]
    end

    attribute :enabled, :boolean do
      allow_nil? false
      public? true
      default true
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end
end
