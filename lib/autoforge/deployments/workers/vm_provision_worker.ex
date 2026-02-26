defmodule Autoforge.Deployments.Workers.VmProvisionWorker do
  @moduledoc """
  Oban worker that provisions a VM instance on GCE.
  """

  use Oban.Worker, queue: :deployments, max_attempts: 5

  alias Autoforge.Deployments.{VmInstance, VmProvisioner}

  require Ash.Query
  require Logger

  @impl Oban.Worker
  def backoff(%Oban.Job{attempt: attempt}) do
    # Longer exponential backoff: ~30s, ~120s, ~270s, ~480s
    attempt * attempt * 30
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"vm_instance_id" => vm_instance_id}}) do
    vm_instance =
      VmInstance
      |> Ash.Query.filter(id == ^vm_instance_id)
      |> Ash.read_one!(authorize?: false)

    case vm_instance do
      nil ->
        Logger.warning("VmProvisionWorker: VM instance #{vm_instance_id} not found")
        :ok

      %{state: state} when state in [:running, :destroying, :destroyed] ->
        Logger.info(
          "VmProvisionWorker: VM instance #{vm_instance_id} already in #{state} state, skipping"
        )

        :ok

      %{state: :error} ->
        Logger.info("VmProvisionWorker: VM instance #{vm_instance_id} in error state, retrying")
        do_provision(vm_instance)

      vm_instance ->
        do_provision(vm_instance)
    end
  end

  defp do_provision(vm_instance) do
    case VmProvisioner.provision(vm_instance) do
      {:ok, _vm_instance} ->
        Logger.info("VmProvisionWorker: VM instance #{vm_instance.id} provisioned successfully")
        :ok

      {:error, reason} ->
        Logger.error(
          "VmProvisionWorker: failed to provision #{vm_instance.id}: #{inspect(reason)}"
        )

        if rate_limited?(reason), do: {:snooze, 120}, else: {:error, reason}
    end
  end

  defp rate_limited?(reason) when is_binary(reason) do
    String.contains?(reason, "Rate Limit") or String.contains?(reason, "rateLimitExceeded")
  end

  defp rate_limited?(_), do: false
end
