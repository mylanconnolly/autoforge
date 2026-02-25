defmodule Autoforge.Projects.OpenVsx do
  @moduledoc """
  Client for the Open VSX extension registry API.
  """

  @base_url "https://open-vsx.org/api"

  @doc """
  Fetches details for a single extension by its ID (e.g. `"bradlc.vscode-tailwindcss"`).

  Returns `{:ok, details_map}` or `{:error, reason}`.
  """
  def get_details(extension_id) do
    case String.split(extension_id, ".", parts: 2) do
      [namespace, name] ->
        case Req.get("#{@base_url}/#{namespace}/#{name}") do
          {:ok, %{status: 200, body: body}} ->
            {:ok,
             %{
               "id" => extension_id,
               "display_name" => body["displayName"] || body["name"] || name,
               "description" => body["description"] || "",
               "version" => body["version"],
               "download_count" => body["downloadCount"] || 0,
               "license" => body["license"],
               "repository" => body["repository"],
               "categories" => body["categories"] || [],
               "publisher" => get_in(body, ["publishedBy", "loginName"]),
               "verified" => body["verified"] || false
             }}

          {:ok, %{status: status}} ->
            {:error, "Open VSX API returned #{status}"}

          {:error, reason} ->
            {:error, reason}
        end

      _ ->
        {:error, "Invalid extension ID: #{extension_id}"}
    end
  end

  @doc """
  Searches the Open VSX registry for extensions matching the given query.

  Returns a list of maps with `id`, `display_name`, `description`, and
  `download_count` keys.
  """
  def search(query, opts \\ []) do
    size = Keyword.get(opts, :size, 10)

    case Req.get("#{@base_url}/-/search", params: [query: query, size: size]) do
      {:ok, %{status: 200, body: %{"extensions" => extensions}}} ->
        results =
          Enum.map(extensions, fn ext ->
            namespace = get_in(ext, ["namespace"]) || ""
            name = get_in(ext, ["name"]) || ""
            display_name = get_in(ext, ["displayName"]) || name

            %{
              "id" => "#{namespace}.#{name}",
              "display_name" => display_name,
              "description" => get_in(ext, ["description"]) || "",
              "download_count" => get_in(ext, ["downloadCount"]) || 0
            }
          end)

        {:ok, results}

      {:ok, %{status: status, body: body}} ->
        {:error, "Open VSX API returned #{status}: #{inspect(body)}"}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
