defmodule Autoforge.Projects.TarBuilder do
  @moduledoc """
  Builds in-memory tar archives from template file trees.
  """

  alias Autoforge.Projects.TemplateRenderer

  @doc """
  Builds a tar archive binary from a list of `%{path: String.t(), content: String.t()}` entries.
  """
  def build(entries) when is_list(entries) do
    file_list =
      Enum.map(entries, fn %{path: path, content: content} ->
        {to_charlist(path), content}
      end)

    tmp_path =
      Path.join(System.tmp_dir!(), "autoforge_tar_#{System.unique_integer([:positive])}.tar")

    try do
      case :erl_tar.create(to_charlist(tmp_path), file_list, []) do
        :ok -> File.read(tmp_path)
        {:error, reason} -> {:error, reason}
      end
    after
      File.rm(tmp_path)
    end
  end

  @doc """
  Recursively walks a template file tree, rendering each file's content
  with the given variables, and returns a flat list of `%{path, content}` entries.
  """
  def flatten_tree(files, variables, base_path \\ "") do
    files
    |> Enum.sort_by(fn f -> {!f.is_directory, f.sort_order, f.name} end)
    |> Enum.flat_map(fn file ->
      path = Path.join(base_path, file.name)

      if file.is_directory do
        children = Enum.filter(files, fn f -> f.parent_id == file.id end)
        flatten_tree(children, variables, path)
      else
        content =
          case TemplateRenderer.render_file(file.content || "", variables) do
            {:ok, rendered} -> rendered
            _ -> file.content || ""
          end

        [%{path: path, content: content}]
      end
    end)
  end

  @doc """
  Builds a tar archive from a list of template files and variables.

  Accepts all files for a template (flat list from DB), organizes the tree
  by parent_id, renders content, and creates the tar.
  """
  def build_from_template_files(all_files, variables) do
    root_files = Enum.filter(all_files, fn f -> is_nil(f.parent_id) end)
    entries = flatten_tree_from_all(root_files, all_files, variables, "")
    build(entries)
  end

  defp flatten_tree_from_all(files, all_files, variables, base_path) do
    files
    |> Enum.sort_by(fn f -> {!f.is_directory, f.sort_order, f.name} end)
    |> Enum.flat_map(fn file ->
      path = Path.join(base_path, file.name)

      if file.is_directory do
        children = Enum.filter(all_files, fn f -> f.parent_id == file.id end)
        flatten_tree_from_all(children, all_files, variables, path)
      else
        content =
          case TemplateRenderer.render_file(file.content || "", variables) do
            {:ok, rendered} -> rendered
            _ -> file.content || ""
          end

        [%{path: path, content: content}]
      end
    end)
  end
end
