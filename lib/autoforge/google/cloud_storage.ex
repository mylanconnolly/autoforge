defmodule Autoforge.Google.CloudStorage do
  @moduledoc """
  Thin Req wrapper over the Google Cloud Storage JSON API.

  Every function takes a `token` (OAuth2 access token) as the first argument
  and returns `{:ok, body}` or `{:error, term}`.
  """

  # ── Objects ──────────────────────────────────────────────────────────────────

  def upload_object(token, bucket, object_name, content, content_type) do
    gcs_req(token, :post, "/upload/storage/v1/b/#{bucket}/o",
      params: [uploadType: "media", name: object_name],
      body: content,
      headers: [{"content-type", content_type}]
    )
  end

  def download_object(token, bucket, object_name) do
    name = URI.encode(object_name, &URI.char_unreserved?/1)

    gcs_req(token, :get, "/storage/v1/b/#{bucket}/o/#{name}",
      params: [alt: "media"],
      decode_body: false
    )
  end

  def delete_object(token, bucket, object_name) do
    name = URI.encode(object_name, &URI.char_unreserved?/1)
    gcs_req(token, :delete, "/storage/v1/b/#{bucket}/o/#{name}")
  end

  def get_object_metadata(token, bucket, object_name) do
    name = URI.encode(object_name, &URI.char_unreserved?/1)
    gcs_req(token, :get, "/storage/v1/b/#{bucket}/o/#{name}")
  end

  def list_objects(token, bucket, opts \\ []) do
    params =
      opts
      |> Keyword.take([:prefix, :delimiter, :maxResults, :pageToken])
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)

    gcs_req(token, :get, "/storage/v1/b/#{bucket}/o", params: params)
  end

  # ── Private ──────────────────────────────────────────────────────────────────

  defp gcs_req(token, method, path, opts \\ []) do
    {body_opt, opts} = Keyword.pop(opts, :body)
    {raw, opts} = Keyword.pop(opts, :decode_body)
    {extra_headers, opts} = Keyword.pop(opts, :headers, [])

    req_opts =
      [
        base_url: "https://storage.googleapis.com",
        url: path,
        method: method,
        auth: {:bearer, token},
        headers: extra_headers,
        max_retries: 2,
        retry_delay: 1_000,
        receive_timeout: 60_000
      ] ++ opts

    req_opts = if body_opt, do: Keyword.put(req_opts, :body, body_opt), else: req_opts
    req_opts = if raw == false, do: Keyword.put(req_opts, :decode_body, false), else: req_opts

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

        {:error, "GCS API error (#{status}): #{message}"}

      {:error, reason} ->
        {:error, "GCS request failed: #{inspect(reason)}"}
    end
  end
end
