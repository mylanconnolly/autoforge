defmodule Autoforge.Ai.ToolRegistry do
  @moduledoc """
  Maps tool name strings to `ReqLLM.Tool` structs with executable callbacks.

  Tools are code-defined; the database `tools` table exists only for
  join/UI purposes. This module is the source of truth for what each
  tool actually does at runtime.
  """

  @max_body_bytes 50_000
  @max_meta_redirects 3

  @doc "Returns all registered tools as a map of name => ReqLLM.Tool."
  @spec all() :: %{String.t() => ReqLLM.Tool.t()}
  def all, do: tools()

  @doc "Returns a single ReqLLM.Tool by name, or nil."
  @spec get(String.t()) :: ReqLLM.Tool.t() | nil
  def get(name), do: Map.get(tools(), name)

  @doc "Returns a list of ReqLLM.Tool structs for the given names."
  @spec get_many([String.t()]) :: [ReqLLM.Tool.t()]
  def get_many(names) do
    registry = tools()

    names
    |> Enum.map(&Map.get(registry, &1))
    |> Enum.reject(&is_nil/1)
  end

  defp tools do
    %{
      "get_time" =>
        ReqLLM.Tool.new!(
          name: "get_time",
          description: "Get the current UTC time in ISO8601 format.",
          parameter_schema: [],
          callback: fn _args ->
            {:ok, DateTime.utc_now() |> DateTime.to_iso8601()}
          end
        ),
      "get_url" =>
        ReqLLM.Tool.new!(
          name: "get_url",
          description: "Fetch the contents of a URL via HTTP GET.",
          parameter_schema: [
            url: [type: :string, required: true, doc: "The URL to fetch"]
          ],
          callback: fn %{url: url} ->
            fetch_url(url, @max_meta_redirects)
          end
        ),
      "delegate_task" =>
        ReqLLM.Tool.new!(
          name: "delegate_task",
          description: """
          Delegate a task or question to another bot you have access to. \
          The bot will process the request (with full tool access) and return its response. \
          Use this whenever another bot's expertise would help — whether you need code written, \
          a question answered, an architecture reviewed, a test designed, or any other task \
          that falls within another bot's specialty. \
          When a user asks you to consult, ask, or involve another bot by name, use this tool.\
          """,
          parameter_schema: [
            bot_name: [
              type: :string,
              required: true,
              doc: "Name of the bot to delegate to"
            ],
            task: [
              type: :string,
              required: true,
              doc: "Clear description of what the bot should do"
            ]
          ],
          callback: fn _args ->
            {:error, "delegate_task requires conversation context — this is a bug"}
          end
        )
    }
  end

  defp fetch_url(url, redirects_remaining) do
    case Req.get(url, max_retries: 2, retry_delay: 500, receive_timeout: 15_000) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        text = to_string(body)

        case extract_meta_refresh(text, url) do
          {:redirect, target} when redirects_remaining > 0 ->
            fetch_url(target, redirects_remaining - 1)

          _ ->
            if byte_size(text) > @max_body_bytes do
              {:ok, binary_part(text, 0, @max_body_bytes) <> "\n[truncated]"}
            else
              {:ok, text}
            end
        end

      {:ok, %Req.Response{status: status}} ->
        {:ok, "HTTP #{status}"}

      {:error, reason} ->
        {:ok, "Error fetching URL: #{inspect(reason)}"}
    end
  end

  defp extract_meta_refresh(html, base_url) do
    case Regex.run(
           ~r/<meta\s[^>]*http-equiv\s*=\s*["']refresh["'][^>]*content\s*=\s*["']\d+;\s*url=([^"']+)["']/i,
           html
         ) do
      [_, relative_url] ->
        base_uri = URI.parse(base_url)

        base_uri =
          if String.ends_with?(base_uri.path || "/", "/"),
            do: base_uri,
            else: %{base_uri | path: base_uri.path <> "/"}

        target = URI.merge(base_uri, relative_url) |> to_string()
        {:redirect, target}

      nil ->
        :none
    end
  end
end
