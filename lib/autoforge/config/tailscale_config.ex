defmodule Autoforge.Config.TailscaleConfig do
  use Ash.Resource,
    otp_app: :autoforge,
    domain: Autoforge.Config,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshCloak, AshPaperTrail.Resource]

  postgres do
    table "tailscale_configs"
    repo Autoforge.Repo
  end

  cloak do
    vault(Autoforge.Vault)
    attributes([:oauth_client_secret])
    decrypt_by_default([:oauth_client_secret])
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
      accept [:oauth_client_id, :oauth_client_secret, :tailnet_name, :tag, :enabled]
    end

    update :update do
      accept [:oauth_client_id, :oauth_client_secret, :tailnet_name, :tag, :enabled]
    end
  end

  policies do
    policy always() do
      authorize_if actor_present()
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :oauth_client_id, :string do
      allow_nil? false
      public? true
    end

    attribute :oauth_client_secret, :string do
      allow_nil? false
      public? true
    end

    attribute :tailnet_name, :string do
      allow_nil? false
      public? true
    end

    attribute :tag, :string do
      allow_nil? false
      public? true
      default "tag:autoforge"
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
