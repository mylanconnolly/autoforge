defmodule Autoforge.Accounts.UserGroup do
  use Ash.Resource,
    otp_app: :autoforge,
    domain: Autoforge.Accounts,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshPaperTrail.Resource]

  postgres do
    table "user_groups"
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

    read :search do
      argument :query, :string, default: ""
      argument :sort, :string, default: "name"
      prepare {Autoforge.Preparations.Search, attributes: [:name, :description]}
      pagination offset?: true, countable: :by_default, default_limit: 20
    end

    create :create do
      accept [:name, :description]
    end

    update :update do
      accept [:name, :description]
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

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    many_to_many :members, Autoforge.Accounts.User do
      through Autoforge.Accounts.UserGroupMembership
      source_attribute_on_join_resource :user_group_id
      destination_attribute_on_join_resource :user_id
    end

    many_to_many :bots, Autoforge.Ai.Bot do
      through Autoforge.Ai.BotUserGroup
      source_attribute_on_join_resource :user_group_id
      destination_attribute_on_join_resource :bot_id
    end

    many_to_many :tools, Autoforge.Ai.Tool do
      through Autoforge.Ai.UserGroupTool
      source_attribute_on_join_resource :user_group_id
      destination_attribute_on_join_resource :tool_id
    end

    many_to_many :projects, Autoforge.Projects.Project do
      through Autoforge.Projects.ProjectUserGroup
      source_attribute_on_join_resource :user_group_id
      destination_attribute_on_join_resource :project_id
    end

    many_to_many :project_templates, Autoforge.Projects.ProjectTemplate do
      through Autoforge.Projects.ProjectTemplateUserGroup
      source_attribute_on_join_resource :user_group_id
      destination_attribute_on_join_resource :project_template_id
    end
  end

  identities do
    identity :unique_name, [:name]
  end
end
