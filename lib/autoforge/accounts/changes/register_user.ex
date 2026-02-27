defmodule Autoforge.Accounts.Changes.RegisterUser do
  @moduledoc """
  This is the change that is responsible for assigning the parameters in the
  upsert changeset. This allows users to be registered automatically after they
  can authenticate with Auth0. The goal here is to automatically assign any
  necessary relationships without intervention in this system.
  """

  use Ash.Resource.Change

  @impl true
  def init(opts), do: {:ok, opts}

  @impl true
  def change(changeset, _opts, _context) do
    user_info = Ash.Changeset.get_argument(changeset, :user_info)

    Ash.Changeset.change_attributes(changeset, %{
      name: user_info["name"],
      email: user_info["email"]
    })
  end
end
