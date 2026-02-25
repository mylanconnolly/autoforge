defmodule Autoforge.Projects.CodeServerExtension do
  use Ash.TypedStruct

  typed_struct do
    field :id, :string, allow_nil?: false
    field :display_name, :string, allow_nil?: false
  end
end
