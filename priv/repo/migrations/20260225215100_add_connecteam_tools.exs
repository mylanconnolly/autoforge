defmodule Autoforge.Repo.Migrations.AddConnecteamTools do
  use Ecto.Migration

  @connecteam_tools [
    # Users
    {"connecteam_list_users", "List users in the Connecteam account."},
    {"connecteam_create_user", "Create a new user in Connecteam."},
    # Scheduler
    {"connecteam_list_schedulers", "List all schedulers in the Connecteam account."},
    {"connecteam_list_shifts", "List shifts for a specific scheduler."},
    {"connecteam_get_shift", "Get details of a specific shift."},
    {"connecteam_create_shift", "Create a new shift in a scheduler."},
    {"connecteam_delete_shift", "Delete a shift from a scheduler."},
    {"connecteam_get_shift_layers", "Get shift layers for a scheduler."},
    # Jobs
    {"connecteam_list_jobs", "List jobs in the Connecteam account."},
    # Onboarding
    {"connecteam_list_onboarding_packs", "List onboarding packs in the Connecteam account."},
    {"connecteam_get_pack_assignments", "Get user assignments for a specific onboarding pack."},
    {"connecteam_assign_users_to_pack", "Assign users to an onboarding pack."}
  ]

  def up do
    for {name, description} <- @connecteam_tools do
      execute """
      INSERT INTO tools (id, name, description, inserted_at, updated_at)
      VALUES (gen_random_uuid(), '#{name}', '#{description}', now(), now())
      ON CONFLICT (name) DO NOTHING
      """
    end
  end

  def down do
    names =
      @connecteam_tools
      |> Enum.map(fn {name, _} -> "'#{name}'" end)
      |> Enum.join(", ")

    execute "DELETE FROM tools WHERE name IN (#{names})"
  end
end
