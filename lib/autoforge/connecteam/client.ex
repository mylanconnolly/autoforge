defmodule Autoforge.Connecteam.Client do
  @moduledoc """
  Thin Req wrapper over the Connecteam REST API.

  Every function takes `api_key` and `region` as the first two arguments
  and returns `{:ok, body}` or `{:error, term}`.
  """

  @base_urls %{
    global: "https://api.connecteam.com",
    australia: "https://api-au.connecteam.com"
  }

  # ── Users ──────────────────────────────────────────────────────────────

  def list_users(api_key, region, opts \\ []) do
    params =
      opts
      |> Keyword.take([:limit, :offset])
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)

    connecteam_req(api_key, region, :get, "/users/v1/users", params: params)
  end

  def create_user(api_key, region, attrs) do
    connecteam_req(api_key, region, :post, "/users/v1/users", json: attrs)
  end

  def create_custom_fields(api_key, region, attrs) do
    connecteam_req(api_key, region, :post, "/users/v1/custom-fields", json: attrs)
  end

  # ── Scheduler ──────────────────────────────────────────────────────────

  def list_schedulers(api_key, region) do
    connecteam_req(api_key, region, :get, "/scheduler/v1/schedulers")
  end

  def list_shifts(api_key, region, scheduler_id, opts \\ []) do
    params =
      opts
      |> Keyword.take([:start_date, :end_date, :limit, :offset])
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)

    connecteam_req(api_key, region, :get, "/scheduler/v1/schedulers/#{scheduler_id}/shifts",
      params: params
    )
  end

  def get_shift(api_key, region, scheduler_id, shift_id) do
    connecteam_req(
      api_key,
      region,
      :get,
      "/scheduler/v1/schedulers/#{scheduler_id}/shifts/#{shift_id}"
    )
  end

  def create_shift(api_key, region, scheduler_id, attrs) do
    connecteam_req(api_key, region, :post, "/scheduler/v1/schedulers/#{scheduler_id}/shifts",
      json: attrs
    )
  end

  def delete_shift(api_key, region, scheduler_id, shift_id) do
    connecteam_req(
      api_key,
      region,
      :delete,
      "/scheduler/v1/schedulers/#{scheduler_id}/shifts/#{shift_id}"
    )
  end

  def get_shift_layers(api_key, region, scheduler_id) do
    connecteam_req(
      api_key,
      region,
      :get,
      "/scheduler/v1/schedulers/#{scheduler_id}/shift_layers"
    )
  end

  # ── Jobs ───────────────────────────────────────────────────────────────

  def list_jobs(api_key, region, opts \\ []) do
    params =
      opts
      |> Keyword.take([:limit, :offset])
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)

    connecteam_req(api_key, region, :get, "/jobs/v1/jobs", params: params)
  end

  # ── Onboarding ─────────────────────────────────────────────────────────

  def list_onboarding_packs(api_key, region, opts \\ []) do
    params =
      opts
      |> Keyword.take([:limit, :offset])
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)

    connecteam_req(api_key, region, :get, "/onboarding/v1/packs", params: params)
  end

  def get_pack_assignments(api_key, region, pack_id, opts \\ []) do
    params =
      opts
      |> Keyword.take([:limit, :offset])
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)

    connecteam_req(api_key, region, :get, "/onboarding/v1/packs/#{pack_id}/assignments",
      params: params
    )
  end

  def assign_users_to_pack(api_key, region, pack_id, attrs) do
    connecteam_req(api_key, region, :post, "/onboarding/v1/packs/#{pack_id}/assignments",
      json: attrs
    )
  end

  # ── Internal ───────────────────────────────────────────────────────────

  defp connecteam_req(api_key, region, method, path, opts \\ []) do
    {json_opt, opts} = Keyword.pop(opts, :json)
    base_url = Map.fetch!(@base_urls, region)

    req_opts =
      [
        base_url: base_url,
        url: path,
        method: method,
        headers: [{"X-API-KEY", api_key}],
        max_retries: 2,
        retry_delay: 1_000,
        receive_timeout: 30_000
      ] ++ opts

    req_opts = if json_opt, do: Keyword.put(req_opts, :json, json_opt), else: req_opts

    case Req.request(req_opts) do
      {:ok, %Req.Response{status: 204}} ->
        :ok

      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        {:ok, body}

      {:ok, %Req.Response{status: status, body: body}} ->
        message =
          case body do
            %{"message" => msg} -> msg
            %{"error" => msg} when is_binary(msg) -> msg
            msg when is_binary(msg) -> msg
            _ -> "HTTP #{status}"
          end

        {:error, "Connecteam API error (#{status}): #{message}"}

      {:error, reason} ->
        {:error, "Connecteam request failed: #{inspect(reason)}"}
    end
  end
end
