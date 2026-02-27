defmodule Autoforge.Projects.Project do
  use Ash.Resource,
    otp_app: :autoforge,
    domain: Autoforge.Projects,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshStateMachine, AshCloak, AshPaperTrail.Resource],
    notifiers: [Ash.Notifier.PubSub]

  postgres do
    table "projects"
    repo Autoforge.Repo

    references do
      reference :project_template, on_delete: :nothing
      reference :user, on_delete: :delete
    end
  end

  state_machine do
    initial_states [:creating]
    default_initial_state :creating

    transitions do
      transition :provision, from: [:creating, :error, :provisioning], to: :provisioning
      transition :mark_running, from: :provisioning, to: :running
      transition :mark_error, from: [:creating, :provisioning, :running, :stopped], to: :error
      transition :stop, from: :running, to: :stopped
      transition :start, from: :stopped, to: :running
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
    ignore_actions [:touch]
    belongs_to_actor :user, Autoforge.Accounts.User, domain: Autoforge.Accounts
  end

  actions do
    defaults [:read]

    read :search do
      argument :query, :string, default: ""
      argument :sort, :string, default: "-inserted_at"
      filter expr(state != :destroyed)
      prepare {Autoforge.Preparations.Search, attributes: [:name]}
      pagination offset?: true, countable: :by_default, default_limit: 20
    end

    create :create do
      accept [:name, :project_template_id, :db_password, :github_repo_owner, :github_repo_name]

      argument :env_vars, {:array, :map}

      change manage_relationship(:env_vars,
               on_no_match: {:create, :create},
               on_match: :ignore,
               on_missing: :ignore
             )

      change relate_actor(:user)

      change fn changeset, _context ->
        changeset
        |> Ash.Changeset.force_change_attribute(
          :db_name,
          "proj_" <> String.replace(Ash.UUID.generate(), "-", "_")
        )
        |> Ash.Changeset.set_argument(
          :db_password,
          :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
        )
        |> Ash.Changeset.after_action(fn _changeset, project ->
          %{project_id: project.id}
          |> Autoforge.Projects.Workers.ProvisionWorker.new()
          |> Oban.insert!()

          {:ok, project}
        end)
      end
    end

    update :provision do
      require_atomic? false
      change transition_state(:provisioning)
    end

    update :mark_running do
      accept [
        :container_id,
        :db_container_id,
        :network_id,
        :host_port,
        :code_server_port,
        :tailscale_container_id,
        :tailscale_hostname
      ]

      require_atomic? false
      change transition_state(:running)
    end

    update :mark_error do
      accept [:error_message]
      require_atomic? false
      change transition_state(:error)
    end

    update :stop do
      require_atomic? false
      change transition_state(:stopped)
    end

    update :start do
      require_atomic? false
      change transition_state(:running)
    end

    update :begin_destroy do
      require_atomic? false
      change transition_state(:destroying)
    end

    update :mark_destroyed do
      require_atomic? false
      change transition_state(:destroyed)
    end

    update :touch do
      require_atomic? false

      change fn changeset, _context ->
        Ash.Changeset.force_change_attribute(changeset, :last_activity_at, DateTime.utc_now())
      end
    end

    update :link_github_repo do
      accept [:github_repo_owner, :github_repo_name]
      require_atomic? false
    end

    update :unlink_github_repo do
      require_atomic? false
      change set_attribute(:github_repo_owner, nil)
      change set_attribute(:github_repo_name, nil)
    end

    destroy :destroy do
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
      authorize_if actor_present()
    end
  end

  pub_sub do
    module AutoforgeWeb.Endpoint
    prefix "project"
    publish_all :update, ["updated", [:id, nil]]
  end

  attributes do
    uuid_primary_key :id

    attribute :name, :string do
      allow_nil? false
      public? true
      constraints max_length: 255
    end

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

    attribute :db_name, :string do
      allow_nil? false
      public? true
    end

    attribute :db_password, :string do
      allow_nil? false
      public? true
    end

    attribute :error_message, :string do
      allow_nil? true
      public? true
    end

    attribute :host_port, :integer do
      allow_nil? true
      public? true
    end

    attribute :code_server_port, :integer do
      allow_nil? true
      public? true
    end

    attribute :tailscale_container_id, :string do
      allow_nil? true
      public? true
    end

    attribute :tailscale_hostname, :string do
      allow_nil? true
      public? true
    end

    attribute :github_repo_owner, :string do
      allow_nil? true
      public? true
      constraints max_length: 255
    end

    attribute :github_repo_name, :string do
      allow_nil? true
      public? true
      constraints max_length: 255
    end

    attribute :last_activity_at, :utc_datetime do
      allow_nil? true
      public? true
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :project_template, Autoforge.Projects.ProjectTemplate do
      allow_nil? false
      attribute_writable? true
    end

    belongs_to :user, Autoforge.Accounts.User do
      allow_nil? false
    end

    many_to_many :user_groups, Autoforge.Accounts.UserGroup do
      through Autoforge.Projects.ProjectUserGroup
      source_attribute_on_join_resource :project_id
      destination_attribute_on_join_resource :user_group_id
    end

    has_many :env_vars, Autoforge.Projects.ProjectEnvVar
    has_many :files, Autoforge.Projects.ProjectFile
  end
end
