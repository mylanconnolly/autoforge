defmodule Autoforge.Deployments.DeploymentEnvVar do
  use Ash.Resource,
    otp_app: :autoforge,
    domain: Autoforge.Deployments,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshCloak, AshPaperTrail.Resource]

  postgres do
    table "deployment_env_vars"
    repo Autoforge.Repo

    references do
      reference :deployment, on_delete: :delete
    end
  end

  cloak do
    vault(Autoforge.Vault)
    attributes([:value])
    decrypt_by_default([:value])
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
      accept [:key, :value, :deployment_id]
    end

    update :update do
      accept [:key, :value]
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
    validate match(:key, ~r/^[A-Z_][A-Z0-9_]*$/) do
      message "must be a valid POSIX environment variable name (uppercase letters, digits, and underscores)"
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :key, :string do
      allow_nil? false
      public? true
      constraints max_length: 255
    end

    attribute :value, :string do
      allow_nil? false
      public? true
      constraints max_length: 4096
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :deployment, Autoforge.Deployments.Deployment do
      allow_nil? false
      attribute_writable? true
    end
  end

  identities do
    identity :unique_key_per_deployment, [:deployment_id, :key]
  end
end
