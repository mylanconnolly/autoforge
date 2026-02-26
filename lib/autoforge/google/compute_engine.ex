defmodule Autoforge.Google.ComputeEngine do
  @moduledoc """
  Thin Req wrapper over the Google Compute Engine API.

  Every function takes a `token` (OAuth2 access token) as the first argument
  and returns `{:ok, body}` or `{:error, term}`.
  """

  @compute_scopes ["https://www.googleapis.com/auth/compute"]

  @image_projects [
    {"Debian", "debian-cloud"},
    {"Ubuntu", "ubuntu-os-cloud"},
    {"Ubuntu Pro", "ubuntu-os-pro-cloud"},
    {"Rocky Linux", "rocky-linux-cloud"},
    {"RHEL", "rhel-cloud"},
    {"SUSE", "suse-cloud"},
    {"Fedora CoreOS", "fedora-coreos-cloud"},
    {"CentOS", "centos-cloud"}
  ]

  @doc """
  Returns the OAuth2 scopes required for Compute Engine operations.
  """
  def scopes, do: @compute_scopes

  @doc """
  Returns the list of `{label, project_name}` tuples for public OS image projects.
  """
  def image_projects, do: @image_projects

  # ── Listing ──────────────────────────────────────────────────────────────

  @doc """
  Lists all regions available in the given project.

  Returns `{:ok, [%{"name" => ..., "description" => ..., "zones" => [...]}]}`.
  """
  def list_regions(token, project_id) do
    with {:ok, body} <-
           gce_req(token, :get, "/compute/v1/projects/#{project_id}/regions",
             params: [maxResults: 500]
           ) do
      {:ok, Map.get(body, "items", [])}
    end
  end

  @doc """
  Lists all zones available in the given project.

  Returns `{:ok, [%{"name" => ..., "region" => ..., "status" => ...}]}`.
  """
  def list_zones(token, project_id) do
    with {:ok, body} <-
           gce_req(token, :get, "/compute/v1/projects/#{project_id}/zones",
             params: [maxResults: 500]
           ) do
      {:ok, Map.get(body, "items", [])}
    end
  end

  @doc """
  Lists machine types available in the given zone.

  Returns `{:ok, [%{"name" => ..., "description" => ..., "guestCpus" => ..., "memoryMb" => ...}]}`.
  """
  def list_machine_types(token, project_id, zone) do
    with {:ok, body} <-
           gce_req(
             token,
             :get,
             "/compute/v1/projects/#{project_id}/zones/#{zone}/machineTypes",
             params: [maxResults: 500]
           ) do
      {:ok, Map.get(body, "items", [])}
    end
  end

  @doc """
  Lists disk types available in the given zone.

  Returns `{:ok, [%{"name" => ..., "description" => ...}]}`.
  """
  def list_disk_types(token, project_id, zone) do
    with {:ok, body} <-
           gce_req(
             token,
             :get,
             "/compute/v1/projects/#{project_id}/zones/#{zone}/diskTypes",
             params: [maxResults: 500]
           ) do
      {:ok, Map.get(body, "items", [])}
    end
  end

  @doc """
  Lists VPC networks available in the given project.

  Returns `{:ok, [%{"name" => ..., "autoCreateSubnetworks" => ..., ...}]}`.
  """
  def list_networks(token, project_id) do
    with {:ok, body} <-
           gce_req(token, :get, "/compute/v1/projects/#{project_id}/global/networks",
             params: [maxResults: 500]
           ) do
      {:ok, Map.get(body, "items", [])}
    end
  end

  @doc """
  Lists subnetworks available in the given project and region.

  Returns `{:ok, [%{"name" => ..., "network" => ..., "ipCidrRange" => ..., ...}]}`.
  """
  def list_subnetworks(token, project_id, region) do
    with {:ok, body} <-
           gce_req(
             token,
             :get,
             "/compute/v1/projects/#{project_id}/regions/#{region}/subnetworks",
             params: [maxResults: 500]
           ) do
      {:ok, Map.get(body, "items", [])}
    end
  end

  @doc """
  Lists images available in the given public image project.

  Returns `{:ok, [%{"name" => ..., "family" => ..., "architecture" => ..., ...}]}`.
  """
  def list_images(token, image_project) do
    with {:ok, body} <-
           gce_req(token, :get, "/compute/v1/projects/#{image_project}/global/images",
             params: [maxResults: 500]
           ) do
      {:ok, Map.get(body, "items", [])}
    end
  end

  # ── Instances ──────────────────────────────────────────────────────────────

  @doc """
  Creates a new VM instance in the given project and zone.
  """
  def create_instance(token, project_id, zone, config) do
    gce_req(token, :post, "/compute/v1/projects/#{project_id}/zones/#{zone}/instances",
      json: config
    )
  end

  @doc """
  Deletes a VM instance.
  """
  def delete_instance(token, project_id, zone, name) do
    gce_req(token, :delete, "/compute/v1/projects/#{project_id}/zones/#{zone}/instances/#{name}")
  end

  @doc """
  Starts a stopped VM instance.
  """
  def start_instance(token, project_id, zone, name) do
    gce_req(
      token,
      :post,
      "/compute/v1/projects/#{project_id}/zones/#{zone}/instances/#{name}/start"
    )
  end

  @doc """
  Stops a running VM instance.
  """
  def stop_instance(token, project_id, zone, name) do
    gce_req(
      token,
      :post,
      "/compute/v1/projects/#{project_id}/zones/#{zone}/instances/#{name}/stop"
    )
  end

  @doc """
  Gets the current state and metadata of a VM instance.
  """
  def get_instance(token, project_id, zone, name) do
    gce_req(token, :get, "/compute/v1/projects/#{project_id}/zones/#{zone}/instances/#{name}")
  end

  @doc """
  Polls a zone operation until it reaches DONE status.
  Returns `{:ok, operation}` on success or `{:error, reason}` on timeout/failure.
  """
  def wait_for_operation(token, project_id, zone, operation_name, opts \\ []) do
    max_attempts = Keyword.get(opts, :max_attempts, 60)
    delay_ms = Keyword.get(opts, :delay_ms, 5_000)

    do_wait_for_operation(token, project_id, zone, operation_name, max_attempts, delay_ms, 1)
  end

  defp do_wait_for_operation(
         _token,
         _project_id,
         _zone,
         operation_name,
         max_attempts,
         _delay_ms,
         attempt
       )
       when attempt > max_attempts do
    {:error, "Operation #{operation_name} timed out after #{max_attempts} attempts"}
  end

  defp do_wait_for_operation(
         token,
         project_id,
         zone,
         operation_name,
         max_attempts,
         delay_ms,
         attempt
       ) do
    case gce_req(
           token,
           :get,
           "/compute/v1/projects/#{project_id}/zones/#{zone}/operations/#{operation_name}"
         ) do
      {:ok, %{"status" => "DONE", "error" => %{"errors" => errors}}} when errors != [] ->
        {:error, "Operation failed: #{inspect(errors)}"}

      {:ok, %{"status" => "DONE"} = op} ->
        {:ok, op}

      {:ok, _op} ->
        Process.sleep(delay_ms)

        do_wait_for_operation(
          token,
          project_id,
          zone,
          operation_name,
          max_attempts,
          delay_ms,
          attempt + 1
        )

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Builds a GCE instance configuration map from a VmTemplate and instance name.

  The startup_script is injected as metadata if provided.
  """
  def build_instance_config(vm_template, instance_name, startup_script \\ nil) do
    config = %{
      "name" => instance_name,
      "machineType" => "zones/#{vm_template.zone}/machineTypes/#{vm_template.machine_type}",
      "disks" => [
        %{
          "boot" => true,
          "autoDelete" => true,
          "initializeParams" => %{
            "sourceImage" => vm_template.os_image,
            "diskSizeGb" => to_string(vm_template.disk_size_gb),
            "diskType" => "zones/#{vm_template.zone}/diskTypes/#{vm_template.disk_type}"
          }
        }
      ],
      "networkInterfaces" => [
        build_network_interface(vm_template)
      ],
      "shieldedInstanceConfig" => %{
        "enableSecureBoot" => true,
        "enableVtpm" => true,
        "enableIntegrityMonitoring" => true
      }
    }

    config =
      if vm_template.network_tags != [] do
        Map.put(config, "tags", %{"items" => vm_template.network_tags})
      else
        config
      end

    config =
      if vm_template.labels != %{} do
        Map.put(config, "labels", vm_template.labels)
      else
        config
      end

    startup = startup_script || vm_template.startup_script

    if startup do
      Map.put(config, "metadata", %{
        "items" => [
          %{"key" => "startup-script", "value" => startup}
        ]
      })
    else
      config
    end
  end

  defp build_network_interface(vm_template) do
    network = Map.get(vm_template, :network) || "default"

    interface = %{
      "network" => "global/networks/#{network}",
      "accessConfigs" => [
        %{
          "type" => "ONE_TO_ONE_NAT",
          "name" => "External NAT"
        }
      ]
    }

    case Map.get(vm_template, :subnetwork) do
      nil -> interface
      "" -> interface
      sub -> Map.put(interface, "subnetwork", "regions/#{vm_template.region}/subnetworks/#{sub}")
    end
  end

  # ── Private ──────────────────────────────────────────────────────────────

  defp gce_req(token, method, path, opts \\ []) do
    {json_body, opts} = Keyword.pop(opts, :json)

    req_opts =
      [
        base_url: "https://compute.googleapis.com",
        url: path,
        method: method,
        auth: {:bearer, token},
        max_retries: 3,
        retry_delay: &gce_retry_delay/1,
        retry: &gce_retryable?/2,
        receive_timeout: 60_000
      ] ++ opts

    req_opts = if json_body, do: Keyword.put(req_opts, :json, json_body), else: req_opts

    case Req.request(req_opts) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        {:ok, body}

      {:ok, %Req.Response{status: 204}} ->
        :ok

      {:ok, %Req.Response{status: status, body: body}} ->
        message =
          case body do
            %{"error" => %{"message" => msg}} -> msg
            msg when is_binary(msg) -> msg
            _ -> "HTTP #{status}"
          end

        {:error, "GCE API error (#{status}): #{message}"}

      {:error, reason} ->
        {:error, "GCE request failed: #{inspect(reason)}"}
    end
  end

  defp gce_retryable?(_request, %Req.Response{status: 429}), do: true
  defp gce_retryable?(_request, %Req.Response{status: status}) when status >= 500, do: true

  defp gce_retryable?(_request, %Req.Response{
         status: 403,
         body: %{"error" => %{"message" => msg}}
       }) do
    String.contains?(msg, "Rate Limit")
  end

  defp gce_retryable?(_request, %{__exception__: true}), do: true
  defp gce_retryable?(_request, _response), do: false

  # Exponential backoff: ~2s, ~4s, ~8s (with jitter)
  defp gce_retry_delay(attempt) do
    delay = Integer.pow(2, attempt) * 1_000
    jitter = :rand.uniform(1_000)
    delay + jitter
  end
end
