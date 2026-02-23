defmodule Autoforge.Chat do
  use Ash.Domain, otp_app: :autoforge, extensions: [AshAdmin.Domain]

  admin do
    show? true
  end

  resources do
    resource Autoforge.Chat.Conversation
    resource Autoforge.Chat.ConversationParticipant
    resource Autoforge.Chat.ConversationBot
    resource Autoforge.Chat.Message
  end
end
