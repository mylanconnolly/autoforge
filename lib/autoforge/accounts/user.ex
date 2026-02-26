defmodule Autoforge.Accounts.User do
  use Ash.Resource,
    otp_app: :autoforge,
    domain: Autoforge.Accounts,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshAuthentication, AshCloak]

  authentication do
    add_ons do
      log_out_everywhere do
        apply_on_password_change? true
      end
    end

    tokens do
      enabled? true
      token_resource Autoforge.Accounts.Token
      signing_secret Autoforge.Secrets
      store_all_tokens? true
      require_token_presence_for_authentication? true
    end

    strategies do
      magic_link do
        identity_field :email
        registration_enabled? true
        require_interaction? true

        sender Autoforge.Accounts.User.Senders.SendMagicLinkEmail
      end

      auth0 :auth0 do
        client_id Autoforge.Secrets
        redirect_uri Autoforge.Secrets
        client_secret Autoforge.Secrets
        base_url Autoforge.Secrets
      end

      remember_me :remember_me

      api_key do
        api_key_relationship :valid_api_keys
      end
    end
  end

  postgres do
    table "users"
    repo Autoforge.Repo
  end

  cloak do
    vault(Autoforge.Vault)
    attributes([:github_token, :ssh_private_key])
    decrypt_by_default([:github_token, :ssh_private_key])
  end

  actions do
    defaults [:read]

    read :search do
      argument :query, :string, default: ""
      argument :sort, :string, default: "email"
      prepare {Autoforge.Preparations.Search, attributes: [:name, :email]}
      pagination offset?: true, countable: :by_default, default_limit: 20
    end

    read :sign_in_with_api_key do
      argument :api_key, :string, allow_nil?: false
      prepare AshAuthentication.Strategy.ApiKey.SignInPreparation
    end

    read :get_by_subject do
      description "Get a user by the subject claim in a JWT"
      argument :subject, :string, allow_nil?: false
      get? true
      prepare AshAuthentication.Preparations.FilterBySubject
    end

    read :get_by_email do
      description "Looks up a user by their email"
      get_by :email
    end

    update :update_profile do
      accept [:name, :timezone, :github_token]
      require_atomic? false
    end

    update :regenerate_ssh_key do
      require_atomic? false

      change fn changeset, _context ->
        {pub, priv} = Autoforge.Accounts.SSHKeygen.generate()

        changeset
        |> Ash.Changeset.force_change_attribute(:ssh_public_key, pub)
        |> AshCloak.encrypt_and_set(:ssh_private_key, priv)
      end
    end

    create :create_user do
      accept [:email, :name, :timezone, :github_token]
    end

    update :update_user do
      accept [:email, :name, :timezone, :github_token]
      require_atomic? false
    end

    destroy :destroy do
    end

    create :register_with_auth0 do
      argument :user_info, :map, allow_nil?: false
      argument :oauth_tokens, :map, allow_nil?: false
      upsert? true
      upsert_identity :unique_email

      # Required if you have token generation enabled.
      change AshAuthentication.GenerateTokenChange

      # Required if you have the `identity_resource` configuration enabled.
      change AshAuthentication.Strategy.OAuth2.IdentityChange

      # Perform the actual registration / sign-in logic
      change {Autoforge.Accounts.Changes.RegisterUser, []}
    end

    create :sign_in_with_magic_link do
      description "Sign in or register a user with magic link."

      argument :token, :string do
        description "The token from the magic link that was sent to the user"
        allow_nil? false
      end

      argument :remember_me, :boolean do
        description "Whether to generate a remember me token"
        allow_nil? true
      end

      upsert? true
      upsert_identity :unique_email
      upsert_fields [:email]

      # Uses the information from the token to create or sign in the user
      change AshAuthentication.Strategy.MagicLink.SignInChange

      change {AshAuthentication.Strategy.RememberMe.MaybeGenerateTokenChange,
              strategy_name: :remember_me}

      metadata :token, :string do
        allow_nil? false
      end
    end

    action :request_magic_link do
      argument :email, :ci_string do
        allow_nil? false
      end

      run AshAuthentication.Strategy.MagicLink.Request
    end
  end

  policies do
    bypass AshAuthentication.Checks.AshAuthenticationInteraction do
      authorize_if always()
    end

    policy action_type(:read) do
      authorize_if actor_present()
    end

    policy action(:update_profile) do
      authorize_if expr(id == ^actor(:id))
    end

    policy action(:regenerate_ssh_key) do
      authorize_if expr(id == ^actor(:id))
    end

    policy action([:create_user, :update_user, :destroy]) do
      authorize_if actor_present()
    end
  end

  validations do
    validate {Autoforge.Accounts.Validations.ValidTimezone, []} do
      on [:create, :update]
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :email, :ci_string do
      allow_nil? false
      public? true
    end

    attribute :name, :string do
      allow_nil? true
      public? true
      constraints max_length: 255
    end

    attribute :timezone, :string do
      allow_nil? false
      public? true
      default "America/New_York"
      constraints max_length: 100
    end

    attribute :github_token, :string do
      allow_nil? true
      public? true
      constraints max_length: 1024
    end

    attribute :ssh_public_key, :string do
      allow_nil? true
      public? true
    end

    attribute :ssh_private_key, :string do
      allow_nil? true
      public? true
    end
  end

  relationships do
    many_to_many :user_groups, Autoforge.Accounts.UserGroup do
      through Autoforge.Accounts.UserGroupMembership
      source_attribute_on_join_resource :user_id
      destination_attribute_on_join_resource :user_group_id
    end

    has_many :valid_api_keys, Autoforge.Accounts.ApiKey do
      filter expr(valid)
    end
  end

  identities do
    identity :unique_email, [:email]
  end
end
