defmodule Autoforge.Config.GcsStorageConfig do
  use Ash.Resource,
    otp_app: :autoforge,
    domain: Autoforge.Config,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshPaperTrail.Resource]

  postgres do
    table "gcs_storage_configs"
    repo Autoforge.Repo
  end

  paper_trail do
    primary_key_type :uuid_v7
    change_tracking_mode :changes_only
    store_action_name? true
    reference_source? false
    ignore_attributes [:inserted_at, :updated_at]
    belongs_to_actor :user, Autoforge.Accounts.User, domain: Autoforge.Accounts
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      accept [:label, :bucket_name, :path_prefix, :service_account_config_id, :enabled]
    end

    update :update do
      accept [:label, :bucket_name, :path_prefix, :service_account_config_id, :enabled]
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

    attribute :bucket_name, :string do
      allow_nil? false
      public? true
    end

    attribute :path_prefix, :string do
      allow_nil? true
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

  relationships do
    belongs_to :service_account_config, Autoforge.Config.GoogleServiceAccountConfig do
      allow_nil? false
      public? true
    end
  end
end
