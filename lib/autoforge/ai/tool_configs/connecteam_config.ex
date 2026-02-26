defmodule Autoforge.Ai.ToolConfigs.ConnecteamConfig do
  use Ash.Resource, data_layer: :embedded

  attributes do
    attribute :connecteam_api_key_config_id, :uuid do
      allow_nil? false
      public? true
    end
  end
end
