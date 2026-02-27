defmodule Autoforge.Deployments.Deployment do
  use Ash.Resource,
    otp_app: :autoforge,
    domain: Autoforge.Deployments,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshStateMachine, AshCloak, AshPaperTrail.Resource],
    notifiers: [Ash.Notifier.PubSub]

  postgres do
    table "deployments"
    repo Autoforge.Repo

    references do
      reference :project, on_delete: :nothing
      reference :vm_instance, on_delete: :nothing
    end
  end

  state_machine do
    initial_states [:pending]
    default_initial_state :pending

    transitions do
      transition :deploy, from: [:pending], to: :deploying
      transition :mark_running, from: :deploying, to: :running

      transition :mark_error,
        from: [:pending, :deploying, :running, :stopping, :destroying],
        to: :error

      transition :redeploy, from: [:running, :stopped, :error], to: :deploying
      transition :begin_stop, from: :running, to: :stopping
      transition :mark_stopped, from: :stopping, to: :stopped
      transition :begin_destroy, from: [:running, :stopped, :error], to: :destroying
      transition :mark_destroyed, from: :destroying, to: :destroyed
    end
  end

  cloak do
    vault(Autoforge.Vault)
    attributes([:db_password])
    decrypt_by_default([:db_password])
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
    defaults [:read]

    read :search do
      argument :query, :string, default: ""
      argument :sort, :string, default: "-inserted_at"
      filter expr(state != :destroyed)
      prepare {Autoforge.Preparations.Search, attributes: [:domain]}
      pagination offset?: true, countable: :by_default, default_limit: 20
    end

    create :create do
      accept [:project_id, :vm_instance_id, :container_port]

      change fn changeset, _context ->
        changeset
        |> Ash.Changeset.force_change_attribute(
          :db_name,
          "deploy_" <> String.replace(Ash.UUID.generate(), "-", "_")
        )
        |> Ash.Changeset.force_change_attribute(
          :db_password,
          :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
        )
        |> Ash.Changeset.after_action(fn _changeset, deployment ->
          %{deployment_id: deployment.id}
          |> Autoforge.Deployments.Workers.BuildWorker.new()
          |> Oban.insert!()

          {:ok, deployment}
        end)
      end
    end

    update :deploy do
      require_atomic? false
      change transition_state(:deploying)
    end

    update :mark_running do
      accept [:container_id, :db_container_id, :network_id, :external_port]
      require_atomic? false
      change transition_state(:running)

      change fn changeset, _context ->
        Ash.Changeset.force_change_attribute(changeset, :deployed_at, DateTime.utc_now())
      end
    end

    update :mark_error do
      accept [:error_message]
      require_atomic? false
      change transition_state(:error)
    end

    update :redeploy do
      require_atomic? false
      change transition_state(:deploying)

      change fn changeset, _context ->
        Ash.Changeset.after_action(changeset, fn _changeset, deployment ->
          %{deployment_id: deployment.id}
          |> Autoforge.Deployments.Workers.DeployWorker.new()
          |> Oban.insert!()

          {:ok, deployment}
        end)
      end
    end

    update :begin_stop do
      require_atomic? false
      change transition_state(:stopping)
    end

    update :mark_stopped do
      require_atomic? false
      change transition_state(:stopped)
    end

    update :begin_destroy do
      require_atomic? false
      change transition_state(:destroying)
    end

    update :mark_destroyed do
      require_atomic? false
      change transition_state(:destroyed)
    end

    update :update_image do
      accept [:image]
      require_atomic? false
    end

    update :assign_domain do
      accept [:domain]
      require_atomic? false
    end

    update :clear_domain do
      require_atomic? false
      change set_attribute(:domain, nil)
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
      authorize_if actor_present()
    end
  end

  pub_sub do
    module AutoforgeWeb.Endpoint
    prefix "deployment"
    publish_all :update, ["updated", [:id, nil]]
  end

  attributes do
    uuid_primary_key :id

    attribute :container_id, :string do
      allow_nil? true
      public? true
    end

    attribute :db_container_id, :string do
      allow_nil? true
      public? true
    end

    attribute :network_id, :string do
      allow_nil? true
      public? true
    end

    attribute :container_port, :integer do
      allow_nil? false
      public? true
      default 4000
    end

    attribute :external_port, :integer do
      allow_nil? true
      public? true
    end

    attribute :image, :string do
      allow_nil? true
      public? true
    end

    attribute :db_name, :string do
      allow_nil? false
      public? true
    end

    attribute :db_password, :string do
      allow_nil? false
      public? true
    end

    attribute :domain, :string do
      allow_nil? true
      public? true
      constraints max_length: 255
    end

    attribute :error_message, :string do
      allow_nil? true
      public? true
    end

    attribute :deployed_at, :utc_datetime do
      allow_nil? true
      public? true
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :project, Autoforge.Projects.Project do
      allow_nil? false
      attribute_writable? true
    end

    belongs_to :vm_instance, Autoforge.Deployments.VmInstance do
      allow_nil? false
      attribute_writable? true
    end

    has_many :env_vars, Autoforge.Deployments.DeploymentEnvVar
  end
end
