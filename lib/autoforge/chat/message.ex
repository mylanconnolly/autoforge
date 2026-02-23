defmodule Autoforge.Chat.Message do
  use Ash.Resource,
    otp_app: :autoforge,
    domain: Autoforge.Chat,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    notifiers: [Ash.Notifier.PubSub]

  postgres do
    table "messages"
    repo Autoforge.Repo
  end

  actions do
    defaults [:read]

    create :create do
      accept [:body, :role, :bot_id, :conversation_id]

      change fn changeset, context ->
        if Ash.Changeset.get_attribute(changeset, :role) == :user do
          Ash.Changeset.manage_relationship(changeset, :user, context.actor, type: :append)
        else
          changeset
        end
      end

      change fn changeset, _context ->
        Ash.Changeset.after_action(changeset, fn _changeset, message ->
          if message.role == :user do
            Autoforge.Chat.BotDispatcher.dispatch(message)
          end

          {:ok, message}
        end)
      end
    end
  end

  policies do
    bypass AshAuthentication.Checks.AshAuthenticationInteraction do
      authorize_if always()
    end

    policy action_type(:create) do
      authorize_if actor_present()
    end

    policy action_type(:read) do
      authorize_if expr(exists(conversation.participants, id == ^actor(:id)))
    end
  end

  pub_sub do
    module AutoforgeWeb.Endpoint
    prefix "conversation"
    publish :create, [:conversation_id]
  end

  attributes do
    uuid_primary_key :id

    attribute :body, :string do
      allow_nil? false
      public? true
    end

    attribute :role, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:user, :bot]
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :conversation, Autoforge.Chat.Conversation do
      allow_nil? false
      attribute_writable? true
    end

    belongs_to :user, Autoforge.Accounts.User do
      allow_nil? true
    end

    belongs_to :bot, Autoforge.Ai.Bot do
      allow_nil? true
      attribute_writable? true
    end
  end
end
