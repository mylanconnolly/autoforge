defmodule Autoforge.Projects.Tailscale do
  @moduledoc """
  Manages Tailscale sidecar containers for project HTTPS exposure on a tailnet.

  Each project gets a `tailscale/tailscale` sidecar container that shares the
  app container's network namespace and runs `tailscale serve` to proxy HTTPS
  traffic to the dev server on `127.0.0.1:4000`.
  """

  alias Autoforge.Config.TailscaleConfig
  alias Autoforge.Projects.Docker

  require Logger

  @doc """
  Returns true if Tailscale integration is configured and enabled.
  """
  def enabled? do
    case get_config() do
      {:ok, _config} -> true
      :disabled -> false
    end
  end

  @doc """
  Returns the current TailscaleConfig if one exists and is enabled.
  Returns `{:ok, config}` or `:disabled`.
  """
  def get_config do
    case Ash.read(TailscaleConfig, authorize?: false) do
      {:ok, [%{enabled: true} = config | _]} -> {:ok, config}
      _ -> :disabled
    end
  end

  @doc """
  Returns the tailnet name from the current config.
  Returns `{:ok, tailnet_name}` or `:disabled`.
  """
  def get_tailnet_name do
    case get_config() do
      {:ok, config} -> {:ok, config.tailnet_name}
      :disabled -> :disabled
    end
  end

  @doc """
  Creates and starts a Tailscale sidecar container for the given project.

  The sidecar shares the app container's network stack via
  `NetworkMode: container:<app_container_id>` and exposes the project as an
  HTTPS endpoint on the tailnet.

  Returns `{:ok, container_id, hostname}` or `:disabled`.
  """
  def create_sidecar(project, app_container_id) do
    case get_config() do
      {:ok, config} ->
        hostname = build_hostname(project)
        volume_name = "autoforge-ts-#{project.id}"

        # Remove stale container from a previous failed attempt
        container_name = "autoforge-ts-#{project.id}"
        Docker.remove_container(container_name, force: true)

        with {:ok, auth_key} <- create_auth_key(config),
             :ok <- Docker.pull_image("tailscale/tailscale:latest"),
             {:ok, _} <- Docker.create_volume(volume_name),
             {:ok, container_id} <-
               create_sidecar_container(
                 config,
                 hostname,
                 volume_name,
                 auth_key,
                 app_container_id,
                 project
               ),
             :ok <- upload_serve_config(container_id),
             :ok <- Docker.start_container(container_id),
             :ok <- wait_for_tailscale(container_id) do
          warm_up_cert(container_id, hostname, config.tailnet_name)
          {:ok, container_id, hostname}
        else
          {:error, reason} ->
            Logger.error(
              "Failed to create Tailscale sidecar for project #{project.id}: #{inspect(reason)}"
            )

            # Clean up failed container, keep volume for retry
            Docker.remove_container(container_name, force: true)
            {:error, reason}
        end

      :disabled ->
        :disabled
    end
  end

  @doc """
  Restarts the Tailscale sidecar without re-registering the device.

  Creates a new container without `TS_AUTHKEY` so it reconnects using
  the persisted state in the volume. Falls back to full re-provisioning
  via `create_sidecar/2` if the state is invalid.
  """
  def restart_sidecar(project, app_container_id) do
    case get_config() do
      {:ok, config} ->
        hostname = build_hostname(project)
        volume_name = "autoforge-ts-#{project.id}"
        container_name = "autoforge-ts-#{project.id}"

        Docker.remove_container(container_name, force: true)

        with {:ok, container_id} <-
               create_sidecar_container(
                 config,
                 hostname,
                 volume_name,
                 nil,
                 app_container_id,
                 project
               ),
             :ok <- upload_serve_config(container_id),
             :ok <- Docker.start_container(container_id),
             :ok <- wait_for_tailscale(container_id) do
          warm_up_cert(container_id, hostname, config.tailnet_name)
          {:ok, container_id, hostname}
        else
          {:error, reason} ->
            Logger.warning(
              "Tailscale sidecar restart from state failed (#{inspect(reason)}), re-provisioning"
            )

            Docker.remove_container(container_name, force: true)
            Docker.remove_volume(volume_name)
            delete_tailnet_device(hostname)
            create_sidecar(project, app_container_id)
        end

      :disabled ->
        :disabled
    end
  end

  @doc """
  Stops and removes the Tailscale sidecar container, its volume,
  and the device from the tailnet.
  """
  def remove_sidecar(project) do
    if project.tailscale_container_id do
      Docker.stop_container(project.tailscale_container_id, timeout: 5)
      Docker.remove_container(project.tailscale_container_id, force: true)
    end

    if project.tailscale_hostname do
      delete_tailnet_device(project.tailscale_hostname)
    end

    Docker.remove_volume("autoforge-ts-#{project.id}")
    :ok
  end

  @doc """
  Builds the full HTTPS URL for a project on the tailnet.
  """
  def build_url(hostname, tailnet_name) do
    "https://#{hostname}.#{tailnet_name}"
  end

  @doc """
  Deletes a device from the tailnet by hostname.

  Looks up the device via the Tailscale API and deletes it if found.
  Failures are logged but do not propagate — this is best-effort cleanup.
  """
  def delete_tailnet_device(hostname) do
    with {:ok, config} <- get_config(),
         {:ok, access_token} <- get_oauth_token(config),
         {:ok, device_id} <- find_device_by_hostname(access_token, hostname) do
      case Req.delete("https://api.tailscale.com/api/v2/device/#{device_id}",
             auth: {:bearer, access_token}
           ) do
        {:ok, %{status: status}} when status in [200, 204] ->
          Logger.info("Deleted Tailscale device #{hostname} (#{device_id})")
          :ok

        {:ok, %{status: status, body: body}} ->
          Logger.warning(
            "Failed to delete Tailscale device #{hostname}: status=#{status} body=#{inspect(body)}"
          )

          :ok

        {:error, reason} ->
          Logger.warning("Failed to delete Tailscale device #{hostname}: #{inspect(reason)}")
          :ok
      end
    else
      :disabled ->
        :ok

      {:error, :not_found} ->
        Logger.debug("Tailscale device #{hostname} not found in tailnet, nothing to delete")
        :ok

      {:error, reason} ->
        Logger.warning(
          "Failed to look up Tailscale device #{hostname} for deletion: #{inspect(reason)}"
        )

        :ok
    end
  end

  # Private helpers

  @cert_warmup_attempts 10
  @cert_warmup_delay_ms 2_000

  defp warm_up_cert(container_id, hostname, tailnet_name) do
    fqdn = "#{hostname}.#{tailnet_name}"
    do_warm_up_cert(container_id, fqdn, 1)
  end

  defp do_warm_up_cert(_container_id, fqdn, attempt) when attempt > @cert_warmup_attempts do
    Logger.warning(
      "Failed to provision TLS cert for #{fqdn} after #{@cert_warmup_attempts} attempts"
    )
  end

  defp do_warm_up_cert(container_id, fqdn, attempt) do
    case Docker.exec_run(container_id, [
           "tailscale",
           "--socket=/tmp/tailscaled.sock",
           "cert",
           fqdn
         ]) do
      {:ok, %{exit_code: 0}} ->
        Logger.info("TLS cert provisioned for #{fqdn}")

      {:ok, %{exit_code: _code, output: output}} ->
        Logger.debug("Cert warmup attempt #{attempt} for #{fqdn}: #{output}")
        Process.sleep(@cert_warmup_delay_ms)
        do_warm_up_cert(container_id, fqdn, attempt + 1)

      {:error, reason} ->
        Logger.debug("Cert warmup attempt #{attempt} for #{fqdn}: #{inspect(reason)}")
        Process.sleep(@cert_warmup_delay_ms)
        do_warm_up_cert(container_id, fqdn, attempt + 1)
    end
  end

  @tailscale_ready_attempts 15
  @tailscale_ready_delay_ms 2_000

  defp wait_for_tailscale(container_id) do
    do_wait_for_tailscale(container_id, 1)
  end

  defp do_wait_for_tailscale(_container_id, attempt)
       when attempt > @tailscale_ready_attempts do
    {:error, :tailscale_not_ready}
  end

  defp do_wait_for_tailscale(container_id, attempt) do
    case Docker.exec_run(container_id, [
           "tailscale",
           "--socket=/tmp/tailscaled.sock",
           "status",
           "--json"
         ]) do
      {:ok, %{exit_code: 0, output: output}} ->
        case Jason.decode(output) do
          {:ok, %{"BackendState" => "Running"}} ->
            :ok

          _ ->
            Process.sleep(@tailscale_ready_delay_ms)
            do_wait_for_tailscale(container_id, attempt + 1)
        end

      _ ->
        Process.sleep(@tailscale_ready_delay_ms)
        do_wait_for_tailscale(container_id, attempt + 1)
    end
  end

  defp find_device_by_hostname(access_token, hostname) do
    case Req.get("https://api.tailscale.com/api/v2/tailnet/-/devices",
           auth: {:bearer, access_token}
         ) do
      {:ok, %{status: 200, body: %{"devices" => devices}}} ->
        case Enum.find(devices, fn d -> d["hostname"] == hostname end) do
          %{"nodeId" => node_id} -> {:ok, node_id}
          _ -> {:error, :not_found}
        end

      {:ok, %{status: status, body: body}} ->
        {:error, {:tailscale_api, status, body}}

      {:error, reason} ->
        {:error, {:tailscale_api, reason}}
    end
  end

  defp build_hostname(project) do
    slug =
      project.name
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "-")
      |> String.trim("-")

    short_id = String.slice(project.id, 0..7)
    "#{slug}-#{short_id}"
  end

  defp create_auth_key(config) do
    with {:ok, access_token} <- get_oauth_token(config) do
      case Req.post("https://api.tailscale.com/api/v2/tailnet/-/keys",
             auth: {:bearer, access_token},
             json: %{
               "capabilities" => %{
                 "devices" => %{
                   "create" => %{
                     "reusable" => false,
                     "ephemeral" => true,
                     "preauthorized" => true,
                     "tags" => [config.tag]
                   }
                 }
               },
               "expirySeconds" => 300
             }
           ) do
        {:ok, %{status: 200, body: %{"key" => key}}} ->
          {:ok, key}

        {:ok, %{status: status, body: body}} ->
          {:error, {:tailscale_api, status, body}}

        {:error, reason} ->
          {:error, {:tailscale_api, reason}}
      end
    end
  end

  defp get_oauth_token(config) do
    case Req.post("https://api.tailscale.com/api/v2/oauth/token",
           form: [
             client_id: config.oauth_client_id,
             client_secret: config.oauth_client_secret,
             grant_type: "client_credentials"
           ]
         ) do
      {:ok, %{status: 200, body: %{"access_token" => token}}} ->
        {:ok, token}

      {:ok, %{status: status, body: body}} ->
        {:error, {:tailscale_oauth, status, body}}

      {:error, reason} ->
        {:error, {:tailscale_oauth, reason}}
    end
  end

  defp create_sidecar_container(
         config,
         hostname,
         volume_name,
         auth_key,
         app_container_id,
         project
       ) do
    fqdn = "#{hostname}.#{config.tailnet_name}"

    env = [
      "TS_HOSTNAME=#{hostname}",
      "TS_STATE_DIR=/var/lib/tailscale",
      "TS_SERVE_CONFIG=/etc/tailscale/serve.json",
      "TS_USERSPACE=false",
      "TS_EXTRA_ARGS=--advertise-tags=#{config.tag}"
    ]

    env = if auth_key, do: ["TS_AUTHKEY=#{auth_key}" | env], else: env

    container_config = %{
      "Image" => "tailscale/tailscale:latest",
      "Env" => env,
      "Healthcheck" => %{
        "Test" => [
          "CMD",
          "tailscale",
          "--socket=/tmp/tailscaled.sock",
          "cert",
          fqdn
        ],
        # 10 second interval
        "Interval" => 10_000_000_000,
        # 30 second timeout for cert provisioning
        "Timeout" => 30_000_000_000,
        # Wait 5 seconds before first check
        "StartPeriod" => 5_000_000_000,
        "Retries" => 3
      },
      "HostConfig" => %{
        "NetworkMode" => "container:#{app_container_id}",
        "Binds" => ["#{volume_name}:/var/lib/tailscale"],
        "CapAdd" => ["NET_ADMIN"],
        "Devices" => [
          %{
            "PathOnHost" => "/dev/net/tun",
            "PathInContainer" => "/dev/net/tun",
            "CgroupPermissions" => "rwm"
          }
        ]
      }
    }

    Docker.create_container(container_config, name: "autoforge-ts-#{project.id}")
  end

  defp upload_serve_config(container_id) do
    serve_config =
      Jason.encode!(%{
        "TCP" => %{
          "443" => %{"HTTPS" => true},
          "8443" => %{"HTTPS" => true}
        },
        "Web" => %{
          "${TS_CERT_DOMAIN}:443" => %{
            "Handlers" => %{
              "/" => %{"Proxy" => "http://127.0.0.1:4000"}
            }
          },
          "${TS_CERT_DOMAIN}:8443" => %{
            "Handlers" => %{
              "/" => %{"Proxy" => "http://127.0.0.1:8080"}
            }
          }
        }
      })

    # Build a tar archive containing etc/tailscale/serve.json
    tar_binary = build_tar([{"etc/tailscale/serve.json", serve_config}])
    Docker.put_archive(container_id, "/", tar_binary)
  end

  defp build_tar(files) do
    entries =
      Enum.map(files, fn {path, content} ->
        content_binary = if is_binary(content), do: content, else: to_string(content)
        {to_charlist(path), content_binary}
      end)

    tmp_path =
      Path.join(System.tmp_dir!(), "autoforge_ts_#{System.unique_integer([:positive])}.tar")

    try do
      :ok = :erl_tar.create(to_charlist(tmp_path), entries, [])
      File.read!(tmp_path)
    after
      File.rm(tmp_path)
    end
  end
end
