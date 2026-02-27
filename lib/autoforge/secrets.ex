defmodule Autoforge.Secrets do
  use AshAuthentication.Secret

  alias Autoforge.Accounts.User

  def secret_for(
        [:authentication, :tokens, :signing_secret],
        Autoforge.Accounts.User,
        _opts,
        _context
      ) do
    Application.fetch_env(:autoforge, :token_signing_secret)
  end

  def secret_for([:authentication, :strategies, :auth0, :client_id], User, _opts, _meth) do
    get_auth0_config(:client_id)
  end

  def secret_for([:authentication, :strategies, :auth0, :redirect_uri], User, _opts, _meth) do
    get_auth0_config(:redirect_uri)
  end

  def secret_for([:authentication, :strategies, :auth0, :client_secret], User, _opts, _meth) do
    get_auth0_config(:client_secret)
  end

  def secret_for([:authentication, :strategies, :auth0, :base_url], User, _opts, _meth) do
    get_auth0_config(:base_url)
  end

  defp get_auth0_config(key) do
    :autoforge
    |> Application.fetch_env!(:auth0)
    |> Keyword.fetch!(key)
    |> then(&{:ok, &1})
  end
end
