defmodule Autoforge.Projects.DevServerCleanup do
  @moduledoc """
  Cleans up orphaned dev server processes on application startup.

  When the application shuts down while dev servers are running, the exec
  processes inside Docker containers survive. This task kills those orphaned
  processes so the user can start fresh.
  """

  use Task, restart: :temporary

  require Ash.Query
  require Logger

  alias Autoforge.Projects.{Docker, Project}

  def start_link(_arg) do
    Task.start_link(__MODULE__, :run, [])
  end

  def run do
    projects =
      Project
      |> Ash.Query.filter(state == :running and not is_nil(container_id))
      |> Ash.read!(authorize?: false)

    for project <- projects do
      Logger.info("Cleaning up orphaned processes in container for project #{project.id}")

      # In a Docker container, `kill -- -1` sends SIGTERM to every process
      # except PID 1. The main `sleep infinity` process (PID 1) is protected
      # from unhandled signals, so only orphaned exec children are killed.
      Docker.exec_run(project.container_id, ["sh", "-c", "kill -- -1 2>/dev/null; exit 0"])
    end

    :ok
  end
end
