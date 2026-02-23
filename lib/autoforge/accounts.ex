defmodule Autoforge.Accounts do
  use Ash.Domain, otp_app: :autoforge, extensions: [AshAdmin.Domain]

  admin do
    show? true
  end

  resources do
    resource Autoforge.Accounts.Token
    resource Autoforge.Accounts.User
  end
end
