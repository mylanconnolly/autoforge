defmodule Autoforge.Projects.ProjectFiles do
  @moduledoc """
  Orchestrates file uploads, downloads, deletions, and container sync for project files.

  Files are stored in Google Cloud Storage and synced to the running container at `/uploads`.
  """

  alias Autoforge.Config.GcsStorageConfig
  alias Autoforge.Google.{Auth, CloudStorage}
  alias Autoforge.Projects.{Docker, ProjectFile, TarBuilder}

  require Ash.Query
  require Logger

  @doc """
  Uploads a file to GCS and creates a ProjectFile record.
  Optionally syncs the file to the container if the project is running.
  """
  def upload(project, filename, content, content_type, opts \\ []) do
    actor = Keyword.get(opts, :actor)
    %{bucket: bucket, path_prefix: prefix, token: token} = get_storage_config!()

    file_uuid = Ash.UUID.generate()
    gcs_key = "#{prefix}#{project.id}/#{file_uuid}/#{filename}"

    with {:ok, _} <- CloudStorage.upload_object(token, bucket, gcs_key, content, content_type),
         {:ok, project_file} <-
           ProjectFile
           |> Ash.Changeset.for_create(:create, %{
             filename: filename,
             content_type: content_type,
             size: byte_size(content),
             gcs_object_key: gcs_key,
             project_id: project.id
           })
           |> Ash.create(actor: actor) do
      if project.state == :running && project.container_id do
        Task.Supervisor.start_child(Autoforge.TaskSupervisor, fn ->
          case sync_file_to_container(project, project_file) do
            :ok -> Logger.info("Synced file #{filename} to container for project #{project.id}")
            {:error, reason} -> Logger.warning("Failed to sync file #{filename} to container: #{inspect(reason)}")
          end
        end)
      end

      {:ok, project_file}
    end
  end

  @doc """
  Deletes a file from GCS and destroys the ProjectFile record.
  Best-effort removal from the container if running.
  """
  def delete(project_file, opts \\ []) do
    actor = Keyword.get(opts, :actor)

    try do
      %{bucket: bucket, token: token} = get_storage_config!()
      CloudStorage.delete_object(token, bucket, project_file.gcs_object_key)
    rescue
      _ -> :ok
    end

    project_file = Ash.load!(project_file, :project, authorize?: false)

    if project_file.project.state == :running && project_file.project.container_id do
      delete_file_from_container(project_file.project, project_file.filename)
    end

    Ash.destroy(project_file, actor: actor)
  end

  @doc """
  Downloads a file's content from GCS.
  """
  def download(project_file) do
    %{bucket: bucket, token: token} = get_storage_config!()
    CloudStorage.download_object(token, bucket, project_file.gcs_object_key)
  end

  @doc """
  Syncs all project files from GCS to the container at `/uploads`.
  Creates the `/uploads` directory and uploads all files via a tar archive.
  """
  def sync_to_container(project) do
    project = Ash.load!(project, :files, authorize?: false)
    files = project.files

    if files == [] do
      ensure_uploads_dir(project)
    else
      %{bucket: bucket, token: token} = get_storage_config!()

      entries =
        Enum.reduce(files, [], fn file, acc ->
          case CloudStorage.download_object(token, bucket, file.gcs_object_key) do
            {:ok, content} ->
              [%{path: "uploads/#{file.filename}", content: content} | acc]

            {:error, reason} ->
              Logger.warning(
                "Failed to download file #{file.filename} for project #{project.id}: #{inspect(reason)}"
              )

              acc
          end
        end)

      case entries do
        [] ->
          ensure_uploads_dir(project)

        entries ->
          case TarBuilder.build(entries) do
            {:ok, tar_binary} ->
              Docker.put_archive(project.container_id, "/", tar_binary)

            {:error, reason} ->
              Logger.warning("Failed to build tar for project #{project.id}: #{inspect(reason)}")
              ensure_uploads_dir(project)
          end
      end
    end
  end

  @doc """
  Syncs a single file to the container at `/uploads/{filename}`.
  """
  def sync_file_to_container(project, project_file) do
    %{bucket: bucket, token: token} = get_storage_config!()

    case CloudStorage.download_object(token, bucket, project_file.gcs_object_key) do
      {:ok, content} ->
        entries = [%{path: "uploads/#{project_file.filename}", content: content}]

        case TarBuilder.build(entries) do
          {:ok, tar_binary} -> Docker.put_archive(project.container_id, "/", tar_binary)
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Removes a file from the container. Best-effort, errors are ignored.
  """
  def delete_file_from_container(project, filename) do
    Docker.exec_run(project.container_id, ["rm", "-f", "/uploads/#{filename}"])
    :ok
  rescue
    _ -> :ok
  end

  defp ensure_uploads_dir(project) do
    if project.container_id do
      Docker.exec_run(project.container_id, ["mkdir", "-p", "/uploads"])
    end

    :ok
  end

  defp get_storage_config! do
    config =
      GcsStorageConfig
      |> Ash.Query.filter(enabled == true)
      |> Ash.Query.load(:service_account_config)
      |> Ash.Query.limit(1)
      |> Ash.read!(authorize?: false)
      |> List.first()

    unless config do
      raise "No enabled GCS storage configuration found"
    end

    {:ok, token} = Auth.get_access_token(config.service_account_config)

    prefix =
      case config.path_prefix do
        nil -> ""
        "" -> ""
        p -> String.trim_trailing(p, "/") <> "/"
      end

    %{bucket: config.bucket_name, path_prefix: prefix, token: token}
  end
end
