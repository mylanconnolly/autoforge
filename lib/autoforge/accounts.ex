defmodule Autoforge.Accounts do
  use Ash.Domain, otp_app: :autoforge, extensions: [AshAdmin.Domain, AshPaperTrail.Domain]

  admin do
    show? true
  end

  paper_trail do
    include_versions? true
  end

  resources do
    resource Autoforge.Accounts.Token
    resource Autoforge.Accounts.User
    resource Autoforge.Accounts.LlmProviderKey
    resource Autoforge.Accounts.UserGroup
    resource Autoforge.Accounts.UserGroupMembership
    resource Autoforge.Accounts.ApiKey
  end
end
