defmodule Autoforge.Deployments.VmTemplate do
  use Ash.Resource,
    otp_app: :autoforge,
    domain: Autoforge.Deployments,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "vm_templates"
    repo Autoforge.Repo
  end

  actions do
    defaults [:read, :destroy]

    read :search do
      argument :query, :string, default: ""
      argument :sort, :string, default: "-inserted_at"
      prepare {Autoforge.Preparations.Search, attributes: [:name, :description, :machine_type]}
      pagination offset?: true, countable: :by_default, default_limit: 20
    end

    create :create do
      accept [
        :name,
        :description,
        :machine_type,
        :os_image,
        :disk_size_gb,
        :disk_type,
        :region,
        :zone,
        :network,
        :subnetwork,
        :network_tags,
        :labels,
        :startup_script
      ]
    end

    update :update do
      accept [
        :name,
        :description,
        :machine_type,
        :os_image,
        :disk_size_gb,
        :disk_type,
        :region,
        :zone,
        :network,
        :subnetwork,
        :network_tags,
        :labels,
        :startup_script
      ]

      require_atomic? false
    end
  end

  policies do
    bypass AshAuthentication.Checks.AshAuthenticationInteraction do
      authorize_if always()
    end

    policy action_type([:read, :create, :update, :destroy]) do
      authorize_if actor_present()
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

    attribute :machine_type, :string do
      allow_nil? false
      public? true
      default "e2-medium"
      constraints max_length: 255
    end

    attribute :os_image, :string do
      allow_nil? false
      public? true
      default "projects/debian-cloud/global/images/family/debian-12"
    end

    attribute :disk_size_gb, :integer do
      allow_nil? false
      public? true
      default 50
      constraints min: 50
    end

    attribute :disk_type, :string do
      allow_nil? false
      public? true
      default "pd-standard"
      constraints max_length: 255
    end

    attribute :region, :string do
      allow_nil? false
      public? true
      default "us-central1"
      constraints max_length: 255
    end

    attribute :zone, :string do
      allow_nil? false
      public? true
      default "us-central1-a"
      constraints max_length: 255
    end

    attribute :network, :string do
      allow_nil? true
      public? true
      constraints max_length: 255
    end

    attribute :subnetwork, :string do
      allow_nil? true
      public? true
      constraints max_length: 255
    end

    attribute :network_tags, {:array, :string} do
      allow_nil? false
      public? true
      default []
    end

    attribute :labels, :map do
      allow_nil? false
      public? true
      default %{}
    end

    attribute :startup_script, :string do
      allow_nil? true
      public? true
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  identities do
    identity :unique_name, [:name]
  end
end
