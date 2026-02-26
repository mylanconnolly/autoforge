defmodule Autoforge.Ai.ToolConfigs.ToolConfig do
  use Ash.Type.NewType,
    subtype_of: :union,
    constraints: [
      types: [
        google_workspace: [
          type: Autoforge.Ai.ToolConfigs.GoogleWorkspaceConfig,
          tag: :type,
          tag_value: "google_workspace"
        ],
        connecteam: [
          type: Autoforge.Ai.ToolConfigs.ConnecteamConfig,
          tag: :type,
          tag_value: "connecteam"
        ]
      ]
    ]
end
