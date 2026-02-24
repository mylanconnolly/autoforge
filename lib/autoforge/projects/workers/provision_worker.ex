defmodule Autoforge.Projects.Workers.ProvisionWorker do
  @moduledoc """
  Oban worker that provisions a project sandbox.
  """

  use Oban.Worker, queue: :sandbox, max_attempts: 3

  alias Autoforge.Projects.{Project, Sandbox}

  require Ash.Query
  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"project_id" => project_id}}) do
    project =
      Project
      |> Ash.Query.filter(id == ^project_id)
      |> Ash.read_one!(authorize?: false)

    case project do
      nil ->
        Logger.warning("ProvisionWorker: project #{project_id} not found")
        :ok

      %{state: state} when state in [:running, :destroying, :destroyed] ->
        Logger.info("ProvisionWorker: project #{project_id} already in #{state} state, skipping")
        :ok

      %{state: :provisioning} ->
        Logger.warning(
          "ProvisionWorker: project #{project_id} stuck in provisioning, cleaning up and retrying"
        )

        cleanup_partial(project)
        reprovision(project)

      %{state: :error} ->
        Logger.info(
          "ProvisionWorker: project #{project_id} in error state, cleaning up and retrying"
        )

        cleanup_partial(project)
        reprovision(project)

      project ->
        case Sandbox.provision(project) do
          {:ok, _project} ->
            Logger.info("ProvisionWorker: project #{project_id} provisioned successfully")
            :ok

          {:error, reason} ->
            Logger.error("ProvisionWorker: failed to provision #{project_id}: #{inspect(reason)}")
            {:error, reason}
        end
    end
  end

  defp reprovision(project) do
    case Sandbox.provision(project) do
      {:ok, _project} ->
        Logger.info("ProvisionWorker: project #{project.id} provisioned successfully")
        :ok

      {:error, reason} ->
        Logger.error("ProvisionWorker: failed to provision #{project.id}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp cleanup_partial(project) do
    alias Autoforge.Projects.Docker

    # Clean up by stored ID if available
    if project.container_id do
      Docker.stop_container(project.container_id, timeout: 5)
      Docker.remove_container(project.container_id, force: true)
    end

    if project.db_container_id do
      Docker.stop_container(project.db_container_id, timeout: 5)
      Docker.remove_container(project.db_container_id, force: true)
    end

    if project.network_id do
      Docker.remove_network(project.network_id)
    end

    # Also clean up by name in case IDs were never persisted (failed mid-provision)
    Docker.remove_container("autoforge-app-#{project.id}", force: true)
    Docker.remove_container("autoforge-db-#{project.id}", force: true)
    Docker.remove_network("autoforge-#{project.id}")
  end
end
