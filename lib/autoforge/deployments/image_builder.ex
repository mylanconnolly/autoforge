defmodule Autoforge.Deployments.ImageBuilder do
  @moduledoc """
  Builds Docker images on the target VM and pushes them to Google Artifact Registry.

  The workflow:
  1. Extract source code from the project's local dev container as a tar archive
  2. Strip the `app/` prefix from the archive (Docker's `/archive` endpoint adds it)
  3. Ensure a Dockerfile exists — use the project's own, the template's `dockerfile_template`, or a simple fallback
  4. Send the tar context to the remote VM's Docker daemon via the `/build` API
  5. Push the built image to Artifact Registry

  Build progress is broadcast via PubSub for real-time log streaming.
  """

  alias Autoforge.Config.GoogleServiceAccountConfig
  alias Autoforge.Deployments.RemoteDocker
  alias Autoforge.Google.{ArtifactRegistry, Auth}
  alias Autoforge.Projects.Docker, as: LocalDocker
  alias Autoforge.Projects.TemplateRenderer

  require Logger

  @doc """
  Builds a Docker image from the project's source and pushes it to Artifact Registry.

  The project must have a running local container with source code. If no Dockerfile
  is found in the source, one will be generated from the project template's
  `dockerfile_template` or a simple fallback.

  Returns `{:ok, image_reference}` or `{:error, reason}`.
  """
  def build_and_push(deployment, opts \\ []) do
    deployment =
      Ash.load!(deployment, [:vm_instance, project: [:project_template, :env_vars]],
        authorize?: false
      )

    project = deployment.project
    vm = deployment.vm_instance
    ip = vm.tailscale_ip
    tag = Keyword.get(opts, :tag, generate_tag())

    with {:ok, sa_config} <- get_service_account_config(),
         {:ok, token} <- Auth.get_access_token(sa_config, ArtifactRegistry.scopes()),
         location <- extract_location(vm),
         repo_id <- build_repo_id(deployment),
         _ <- broadcast_log(deployment, "Ensuring Artifact Registry repository..."),
         :ok <- ensure_repository(token, sa_config.project_id, location, repo_id),
         registry <- "#{location}-docker.pkg.dev",
         image_ref <- "#{registry}/#{sa_config.project_id}/#{repo_id}/app:#{tag}",
         _ <- broadcast_log(deployment, "Extracting source from project container..."),
         {:ok, tar_context} <- extract_source(project),
         _ <- broadcast_log(deployment, "Preparing build context..."),
         {:ok, tar_context} <- ensure_dockerfile(tar_context, deployment),
         _ <- broadcast_log(deployment, "Building image #{image_ref}..."),
         callback <- build_log_callback(deployment),
         :ok <- RemoteDocker.build_image(ip, tar_context, image_ref, callback: callback),
         _ <- broadcast_log(deployment, "Pushing image to registry..."),
         auth_header <- build_registry_auth(token),
         :ok <- RemoteDocker.push_image(ip, image_ref, auth: auth_header, callback: callback) do
      broadcast_log(deployment, "Build complete: #{image_ref}")
      {:ok, image_ref}
    else
      {:error, reason} ->
        broadcast_log(deployment, "Build failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp get_service_account_config do
    case Ash.read(GoogleServiceAccountConfig, authorize?: false) do
      {:ok, configs} when configs != [] ->
        default =
          Enum.find(configs, fn c -> c.default_compute and c.enabled end) ||
            Enum.find(configs, fn c -> c.enabled end)

        if default,
          do: {:ok, default},
          else: {:error, "No enabled Google service account configured"}

      _ ->
        {:error, "No enabled Google service account configured"}
    end
  end

  defp extract_location(vm) do
    case vm.gce_zone do
      nil -> "us-central1"
      zone -> zone |> String.split("-") |> Enum.slice(0..-2//1) |> Enum.join("-")
    end
  end

  defp build_repo_id(deployment) do
    short_id = String.slice(deployment.project_id, 0..7)
    "autoforge-#{short_id}"
  end

  defp ensure_repository(token, project_id, location, repo_id) do
    case ArtifactRegistry.list_repositories(token, project_id, location) do
      {:ok, repos} ->
        exists? =
          Enum.any?(repos, fn r ->
            String.ends_with?(Map.get(r, "name", ""), "/#{repo_id}")
          end)

        if exists? do
          :ok
        else
          case ArtifactRegistry.create_repository(token, project_id, location, repo_id) do
            {:ok, _} -> :ok
            {:error, reason} -> {:error, reason}
          end
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc false
  def extract_source(project) do
    if project.container_id do
      case LocalDocker.get_archive(project.container_id, "/app") do
        {:ok, tar_binary} ->
          strip_tar_prefix(tar_binary, "app")

        {:error, reason} ->
          {:error, "Failed to extract source: #{inspect(reason)}"}
      end
    else
      {:error, "Project has no running container — cannot extract source"}
    end
  end

  @doc """
  Strips a directory prefix from all entries in a tar archive.

  Docker's `/containers/{id}/archive?path=/app` returns entries like
  `app/Dockerfile`, `app/lib/`, etc. This rewrites them to `Dockerfile`,
  `lib/`, etc. so the build context has the expected structure.
  """
  def strip_tar_prefix(tar_binary, prefix) do
    prefix_with_slash = prefix <> "/"

    tmp_in =
      Path.join(System.tmp_dir!(), "autoforge_tar_in_#{System.unique_integer([:positive])}.tar")

    tmp_out =
      Path.join(System.tmp_dir!(), "autoforge_tar_out_#{System.unique_integer([:positive])}.tar")

    try do
      File.write!(tmp_in, tar_binary)

      case :erl_tar.extract(to_charlist(tmp_in), [:memory]) do
        {:ok, entries} ->
          rewritten =
            entries
            |> Enum.map(fn {name, content} ->
              name_str = to_string(name)

              stripped =
                cond do
                  name_str == prefix ->
                    nil

                  name_str == prefix_with_slash ->
                    nil

                  String.starts_with?(name_str, prefix_with_slash) ->
                    String.replace_prefix(name_str, prefix_with_slash, "")

                  true ->
                    name_str
                end

              if stripped && stripped != "", do: {to_charlist(stripped), content}, else: nil
            end)
            |> Enum.reject(&is_nil/1)

          case :erl_tar.create(to_charlist(tmp_out), rewritten, []) do
            :ok -> File.read(tmp_out)
            {:error, reason} -> {:error, "Failed to create rewritten tar: #{inspect(reason)}"}
          end

        {:error, reason} ->
          {:error, "Failed to extract tar: #{inspect(reason)}"}
      end
    after
      File.rm(tmp_in)
      File.rm(tmp_out)
    end
  end

  @doc """
  Checks if the tar context contains a Dockerfile. If not, generates one from the
  project template's `dockerfile_template` or a simple fallback, and adds it to the archive.
  """
  def ensure_dockerfile(tar_binary, deployment) do
    tmp_path =
      Path.join(System.tmp_dir!(), "autoforge_tar_df_#{System.unique_integer([:positive])}.tar")

    try do
      File.write!(tmp_path, tar_binary)

      case :erl_tar.extract(to_charlist(tmp_path), [:memory]) do
        {:ok, entries} ->
          has_dockerfile? =
            Enum.any?(entries, fn {name, _} -> to_string(name) == "Dockerfile" end)

          if has_dockerfile? do
            {:ok, tar_binary}
          else
            add_generated_dockerfile(entries, deployment, tmp_path)
          end

        {:error, reason} ->
          {:error, "Failed to read build context: #{inspect(reason)}"}
      end
    after
      File.rm(tmp_path)
    end
  end

  defp add_generated_dockerfile(entries, deployment, tmp_path) do
    project = deployment.project
    template = project.project_template

    dockerfile_content =
      cond do
        template && is_binary(template.dockerfile_template) &&
            template.dockerfile_template != "" ->
          Logger.info("No Dockerfile in project source — using template's dockerfile_template")

          variables = TemplateRenderer.build_variables(project)

          variables =
            Map.merge(variables, %{
              "container_port" => to_string(deployment.container_port)
            })

          case TemplateRenderer.render_file(template.dockerfile_template, variables) do
            {:ok, rendered} -> rendered
            _ -> fallback_dockerfile(template.base_image, deployment.container_port)
          end

        true ->
          Logger.warning(
            "No Dockerfile in project source and no dockerfile_template on template — using fallback"
          )

          base_image =
            if template, do: template.base_image, else: "ubuntu:22.04"

          fallback_dockerfile(base_image, deployment.container_port)
      end

    broadcast_log(deployment, "Generated Dockerfile (no Dockerfile found in project source)")

    new_entries = entries ++ [{~c"Dockerfile", dockerfile_content}]

    case :erl_tar.create(to_charlist(tmp_path), new_entries, []) do
      :ok -> File.read(tmp_path)
      {:error, reason} -> {:error, "Failed to add Dockerfile to context: #{inspect(reason)}"}
    end
  end

  defp fallback_dockerfile(base_image, container_port) do
    """
    FROM #{base_image}
    WORKDIR /app
    COPY . .
    EXPOSE #{container_port}
    CMD ["sleep", "infinity"]
    """
  end

  defp build_registry_auth(token) do
    Jason.encode!(%{"username" => "oauth2accesstoken", "password" => token})
    |> Base.encode64()
  end

  defp generate_tag do
    DateTime.utc_now()
    |> Calendar.strftime("%Y%m%d%H%M%S")
  end

  defp broadcast_log(deployment, message) do
    Phoenix.PubSub.broadcast(
      Autoforge.PubSub,
      "deployment:build_log:#{deployment.id}",
      {:build_log, message}
    )
  end

  defp build_log_callback(deployment) do
    fn message -> broadcast_log(deployment, message) end
  end
end
