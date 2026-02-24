defmodule Autoforge.Repo.Migrations.AddDelegateTaskTool do
  use Ecto.Migration

  def up do
    execute """
    INSERT INTO tools (id, name, description, inserted_at, updated_at)
    VALUES (gen_random_uuid(), 'delegate_task', 'Delegate a task to another bot in the conversation.', now(), now())
    ON CONFLICT (name) DO NOTHING
    """
  end

  def down do
    execute """
    DELETE FROM tools WHERE name = 'delegate_task'
    """
  end
end
