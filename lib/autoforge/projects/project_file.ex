defmodule Autoforge.Projects.ProjectFile do
  use Ash.Resource,
    otp_app: :autoforge,
    domain: Autoforge.Projects,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "project_files"
    repo Autoforge.Repo

    references do
      reference :project, on_delete: :delete
    end
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      accept [:filename, :content_type, :size, :gcs_object_key, :project_id]
    end
  end

  policies do
    policy always() do
      authorize_if actor_present()
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :filename, :string do
      allow_nil? false
      public? true
      constraints max_length: 255
    end

    attribute :content_type, :string do
      allow_nil? false
      public? true
      constraints max_length: 255
    end

    attribute :size, :integer do
      allow_nil? false
      public? true
    end

    attribute :gcs_object_key, :string do
      allow_nil? false
      public? true
      constraints max_length: 1024
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :project, Autoforge.Projects.Project do
      allow_nil? false
      attribute_writable? true
    end
  end
end
