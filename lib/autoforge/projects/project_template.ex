defmodule Autoforge.Projects.ProjectTemplate do
  use Ash.Resource,
    otp_app: :autoforge,
    domain: Autoforge.Projects,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "project_templates"
    repo Autoforge.Repo
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      accept [
        :name,
        :description,
        :base_image,
        :db_image,
        :bootstrap_script,
        :startup_script,
        :dev_server_script,
        :code_server_extensions
      ]
    end

    update :update do
      accept [
        :name,
        :description,
        :base_image,
        :db_image,
        :bootstrap_script,
        :startup_script,
        :dev_server_script,
        :code_server_extensions
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

    attribute :base_image, :string do
      allow_nil? false
      public? true
      constraints max_length: 255
    end

    attribute :db_image, :string do
      allow_nil? false
      public? true
      default "postgres:18-alpine"
      constraints max_length: 255
    end

    attribute :bootstrap_script, :string do
      allow_nil? true
      public? true
    end

    attribute :startup_script, :string do
      allow_nil? true
      public? true
    end

    attribute :dev_server_script, :string do
      allow_nil? true
      public? true
    end

    attribute :code_server_extensions, {:array, Autoforge.Projects.CodeServerExtension} do
      allow_nil? true
      public? true
      default []
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    has_many :files, Autoforge.Projects.ProjectTemplateFile do
      destination_attribute :project_template_id
    end

    many_to_many :user_groups, Autoforge.Accounts.UserGroup do
      through Autoforge.Projects.ProjectTemplateUserGroup
      source_attribute_on_join_resource :project_template_id
      destination_attribute_on_join_resource :user_group_id
    end
  end

  identities do
    identity :unique_name, [:name]
  end
end
