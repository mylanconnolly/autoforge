defmodule Autoforge.Chat.Conversation do
  use Ash.Resource,
    otp_app: :autoforge,
    domain: Autoforge.Chat,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "conversations"
    repo Autoforge.Repo
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      accept [:subject]

      argument :bot_ids, {:array, :uuid} do
        allow_nil? false
        default []
      end

      change fn changeset, context ->
        Ash.Changeset.manage_relationship(changeset, :participants, [context.actor],
          type: :append
        )
      end

      change manage_relationship(:bot_ids, :bots, type: :append)
    end
  end

  policies do
    bypass AshAuthentication.Checks.AshAuthenticationInteraction do
      authorize_if always()
    end

    policy action_type(:create) do
      authorize_if actor_present()
    end

    policy action_type([:read, :destroy]) do
      authorize_if expr(exists(participants, id == ^actor(:id)))
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :subject, :string do
      allow_nil? false
      public? true
      constraints max_length: 255
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    has_many :messages, Autoforge.Chat.Message

    many_to_many :participants, Autoforge.Accounts.User do
      through Autoforge.Chat.ConversationParticipant
      source_attribute_on_join_resource :conversation_id
      destination_attribute_on_join_resource :user_id
    end

    many_to_many :bots, Autoforge.Ai.Bot do
      through Autoforge.Chat.ConversationBot
      source_attribute_on_join_resource :conversation_id
      destination_attribute_on_join_resource :bot_id
    end
  end
end
