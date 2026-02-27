defmodule Autoforge.Deployments.VmInstance do
  use Ash.Resource,
    otp_app: :autoforge,
    domain: Autoforge.Deployments,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshStateMachine, AshPaperTrail.Resource],
    notifiers: [Ash.Notifier.PubSub]

  postgres do
    table "vm_instances"
    repo Autoforge.Repo

    references do
      reference :vm_template, on_delete: :nothing
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

  paper_trail do
    primary_key_type :uuid_v7
    change_tracking_mode :changes_only
    store_action_name? true
    reference_source? false
    ignore_attributes [:inserted_at, :updated_at]
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
      accept [:name, :vm_template_id]

      change fn changeset, _context ->
        Ash.Changeset.after_action(changeset, fn _changeset, vm_instance ->
          %{vm_instance_id: vm_instance.id}
          |> Autoforge.Deployments.Workers.VmProvisionWorker.new()
          |> Oban.insert!()

          {:ok, vm_instance}
        end)
      end
    end

    update :provision do
      require_atomic? false
      change transition_state(:provisioning)
    end

    update :mark_running do
      accept [
        :gce_instance_name,
        :gce_zone,
        :gce_project_id,
        :external_ip,
        :tailscale_ip,
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
    prefix "vm_instance"
    publish_all :update, ["updated", [:id, nil]]
  end

  attributes do
    uuid_primary_key :id

    attribute :name, :string do
      allow_nil? false
      public? true
      constraints max_length: 255
    end

    attribute :gce_instance_name, :string do
      allow_nil? true
      public? true
    end

    attribute :gce_zone, :string do
      allow_nil? true
      public? true
    end

    attribute :gce_project_id, :string do
      allow_nil? true
      public? true
    end

    attribute :external_ip, :string do
      allow_nil? true
      public? true
    end

    attribute :tailscale_ip, :string do
      allow_nil? true
      public? true
    end

    attribute :tailscale_hostname, :string do
      allow_nil? true
      public? true
    end

    attribute :error_message, :string do
      allow_nil? true
      public? true
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :vm_template, Autoforge.Deployments.VmTemplate do
      allow_nil? false
      attribute_writable? true
    end
  end
end
