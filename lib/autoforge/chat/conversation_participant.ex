defmodule Autoforge.Chat.ConversationParticipant do
  use Ash.Resource,
    otp_app: :autoforge,
    domain: Autoforge.Chat,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "conversation_participants"
    repo Autoforge.Repo
  end

  actions do
    defaults [:read, :destroy, create: :*, update: :*]
  end

  policies do
    bypass AshAuthentication.Checks.AshAuthenticationInteraction do
      authorize_if always()
    end

    policy action_type(:create) do
      authorize_if actor_present()
    end

    policy action_type([:read, :update, :destroy]) do
      authorize_if expr(exists(conversation.participants, id == ^actor(:id)))
    end
  end

  attributes do
    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :conversation, Autoforge.Chat.Conversation do
      primary_key? true
      allow_nil? false
    end

    belongs_to :user, Autoforge.Accounts.User do
      primary_key? true
      allow_nil? false
    end
  end
end
