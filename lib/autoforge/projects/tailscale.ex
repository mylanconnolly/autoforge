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
             :ok <- Docker.start_container(container_id) do
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
  Stops and removes the Tailscale sidecar container and its volume.
  """
  def remove_sidecar(project) do
    if project.tailscale_container_id do
      Docker.stop_container(project.tailscale_container_id, timeout: 5)
      Docker.remove_container(project.tailscale_container_id, force: true)
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

  # Private helpers

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
    container_config = %{
      "Image" => "tailscale/tailscale:latest",
      "Env" => [
        "TS_AUTHKEY=#{auth_key}",
        "TS_HOSTNAME=#{hostname}",
        "TS_STATE_DIR=/var/lib/tailscale",
        "TS_SERVE_CONFIG=/etc/tailscale/serve.json",
        "TS_USERSPACE=false",
        "TS_EXTRA_ARGS=--advertise-tags=#{config.tag}"
      ],
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
        "TCP" => %{"443" => %{"HTTPS" => true}},
        "Web" => %{
          "${TS_CERT_DOMAIN}:443" => %{
            "Handlers" => %{
              "/" => %{"Proxy" => "http://127.0.0.1:4000"}
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
