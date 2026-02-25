defmodule Autoforge.GitHub.RepoSetup do
  @moduledoc """
  Orchestrates GitHub repository creation, git remote configuration,
  and initial push for Autoforge projects.
  """

  alias Autoforge.GitHub.Client
  alias Autoforge.Projects.Docker

  require Logger

  @doc """
  Creates a new GitHub repository, links it to the project, configures the
  git remote, and performs an initial push.

  `opts` may include:
    - `:private` — whether the repo should be private (default: true)
    - `:description` — repo description
  """
  def create_and_link(project, token, repo_name, org \\ nil, opts \\ []) do
    private? = Keyword.get(opts, :private, true)
    description = Keyword.get(opts, :description, "Created by Autoforge")

    params = %{
      "name" => repo_name,
      "private" => private?,
      "description" => description,
      "auto_init" => false
    }

    create_result =
      if org && org != "" do
        Client.create_org_repo(token, org, params)
      else
        Client.create_repo(token, params)
      end

    with {:ok, repo_data} <- create_result,
         owner = repo_data["owner"]["login"],
         :ok <- configure_remote(project.container_id, owner, repo_name),
         {:ok, _project} <- link_project(project, owner, repo_name) do
      # Push is best-effort — the repo may have no commits yet
      case initial_push(project.container_id) do
        :ok ->
          Logger.info("Initial push to #{owner}/#{repo_name} succeeded")

        {:error, reason} ->
          Logger.warning("Initial push to #{owner}/#{repo_name} skipped: #{reason}")
      end

      {:ok, %{owner: owner, repo: repo_name}}
    end
  end

  @doc """
  Validates that a repo exists, links it to the project, and configures the remote.
  """
  def link_existing(project, token, owner, repo) do
    with {:ok, _repo_data} <- Client.get_repo(token, owner, repo),
         :ok <- configure_remote(project.container_id, owner, repo),
         {:ok, _project} <- link_project(project, owner, repo) do
      {:ok, %{owner: owner, repo: repo}}
    end
  end

  @doc """
  Configures the git remote origin in the project's container.
  Removes any existing origin first (idempotent).
  """
  def configure_remote(container_id, owner, repo) do
    exec_opts = [user: "app", working_dir: "/app"]

    # Remove existing origin (ignore errors if it doesn't exist)
    Docker.exec_run(container_id, ["git", "remote", "remove", "origin"], exec_opts)

    case Docker.exec_run(
           container_id,
           ["git", "remote", "add", "origin", "git@github.com:#{owner}/#{repo}.git"],
           exec_opts
         ) do
      {:ok, %{exit_code: 0}} ->
        :ok

      {:ok, %{exit_code: _, output: output}} ->
        {:error, "Failed to add git remote: #{output}"}

      {:error, reason} ->
        {:error, "Failed to configure remote: #{inspect(reason)}"}
    end
  end

  @doc """
  Pushes the current branch to origin.
  """
  def initial_push(container_id) do
    exec_opts = [user: "app", working_dir: "/app"]

    case Docker.exec_run(
           container_id,
           ["git", "push", "-u", "origin", "main"],
           exec_opts
         ) do
      {:ok, %{exit_code: 0}} ->
        :ok

      {:ok, %{exit_code: _, output: output}} ->
        Logger.warning("Initial push failed (may be expected if no commits): #{output}")
        {:error, "Push failed: #{output}"}

      {:error, reason} ->
        {:error, "Push failed: #{inspect(reason)}"}
    end
  end

  defp link_project(project, owner, repo) do
    project
    |> Ash.Changeset.for_update(
      :link_github_repo,
      %{github_repo_owner: owner, github_repo_name: repo},
      authorize?: false
    )
    |> Ash.update()
  end
end
