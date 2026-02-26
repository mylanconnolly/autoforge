defmodule Autoforge.Google.Pricing do
  @moduledoc """
  Fetches and caches Google Cloud Compute Engine pricing from the
  Cloud Billing Catalog API.

  Pricing is decomposed into per-vCPU and per-GB-RAM hourly rates
  (indexed by machine family and region), per-GB monthly rates
  for disk types, and per-vCPU / per-instance hourly rates for
  premium OS image licenses.
  """

  require Logger

  @billing_scopes ["https://www.googleapis.com/auth/cloud-billing.readonly"]
  @compute_service_id "6F81-5844-456A"
  @ets_table :gce_pricing_cache
  @cache_ttl_ms :timer.hours(24)

  # Maps SKU description prefixes to machine family identifiers.
  # Order matters: longer/more-specific prefixes must come first.
  @sku_family_patterns [
    {"N2D AMD Instance", "n2d"},
    {"N2 Instance", "n2"},
    {"N4 Instance", "n4"},
    {"N1 Predefined Instance", "n1"},
    {"E2 Instance", "e2"},
    {"C2D AMD Instance", "c2d"},
    {"C3D AMD Instance", "c3d"},
    {"C3 Instance", "c3"},
    {"C4A Arm Instance", "c4a"},
    {"C4D AMD Instance", "c4d"},
    {"C4 Instance", "c4"},
    {"T2D AMD Instance", "t2d"},
    {"T2A Arm Instance", "t2a"},
    {"Memory-optimized Instance", "m1"},
    {"M2 Instance", "m2"},
    {"M3 Instance", "m3"},
    {"G2 Instance", "g2"},
    {"A2 Instance", "a2"},
    {"A3 Instance", "a3"},
    {"H3 Instance", "h3"}
  ]

  @disk_type_patterns [
    {"Storage PD Capacity", "pd-standard"},
    {"Balanced PD Capacity", "pd-balanced"},
    {"SSD backed PD Capacity", "pd-ssd"},
    {"Extreme PD Capacity", "pd-extreme"},
    {"Hyperdisk Balanced Capacity", "hyperdisk-balanced"},
    {"Hyperdisk Extreme Capacity", "hyperdisk-extreme"},
    {"Hyperdisk Throughput Capacity", "hyperdisk-throughput"}
  ]

  # Maps license SKU description fragments to OS identifiers.
  @license_patterns [
    {"Ubuntu Pro", "ubuntu-pro"},
    {"Red Hat Enterprise Linux", "rhel"},
    {"RHEL", "rhel"},
    {"SUSE Linux Enterprise", "sles"},
    {"SLES", "sles"}
  ]

  @doc """
  Returns the OAuth2 scopes needed for the Billing Catalog API.
  """
  def scopes, do: @billing_scopes

  @doc """
  Returns cached pricing data, or fetches it if the cache is empty/expired.

  Returns `{:ok, pricing_map}` or `{:error, reason}`.
  The pricing map has keys `:machine`, `:disk`, and `:license`.
  """
  def get_or_fetch(token) do
    ensure_table()

    case :ets.lookup(@ets_table, :pricing) do
      [{:pricing, data, expires_at}] ->
        if System.monotonic_time(:millisecond) < expires_at do
          {:ok, data}
        else
          fetch_and_cache(token)
        end

      [] ->
        fetch_and_cache(token)
    end
  end

  @doc """
  Calculates estimated hourly cost for a machine type.

  Returns `{:ok, hourly_cost}` or `:unknown` if pricing data is missing
  for the given family/region.
  """
  def estimate_machine_hourly(pricing, machine_type, region, vcpus, ram_gb) do
    family = machine_family(machine_type)

    with %{machine: machine_map} <- pricing,
         %{vcpu: vcpu_price, ram_gb: ram_price} <-
           find_machine_pricing(machine_map, family, region) do
      {:ok, vcpu_price * vcpus + ram_price * ram_gb}
    else
      _ -> :unknown
    end
  end

  @doc """
  Calculates estimated monthly cost for disk storage.

  Returns `{:ok, monthly_cost}` or `:unknown`.
  """
  def estimate_disk_monthly(pricing, disk_type, region, size_gb) do
    with %{disk: disk_map} <- pricing,
         price_per_gb when is_number(price_per_gb) <-
           find_disk_pricing(disk_map, disk_type, region) do
      {:ok, price_per_gb * size_gb}
    else
      _ -> :unknown
    end
  end

  @doc """
  Calculates estimated hourly license cost for a premium OS image.

  `os_key` is one of `"ubuntu-pro"`, `"rhel"`, or `"sles"`.
  Returns `{:ok, hourly_cost}` or `:unknown`.
  """
  def estimate_license_hourly(pricing, os_key, vcpus) do
    with %{license: license_map} <- pricing,
         %{} = rates <- Map.get(license_map, os_key) do
      per_vcpu_cost = if rates.per_vcpu, do: rates.per_vcpu * vcpus, else: 0
      per_instance_cost = rates.per_instance || 0
      {:ok, per_vcpu_cost + per_instance_cost}
    else
      _ -> :unknown
    end
  end

  # --- Private ---

  defp ensure_table do
    if :ets.whereis(@ets_table) == :undefined do
      :ets.new(@ets_table, [:named_table, :set, :public, read_concurrency: true])
    end

    :ok
  rescue
    ArgumentError -> :ok
  end

  defp fetch_and_cache(token) do
    case fetch_all_skus(token) do
      {:ok, skus} ->
        pricing = parse_skus(skus)
        expires_at = System.monotonic_time(:millisecond) + @cache_ttl_ms
        :ets.insert(@ets_table, {:pricing, pricing, expires_at})
        {:ok, pricing}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_all_skus(token) do
    fetch_skus_page(token, nil, [])
  end

  defp fetch_skus_page(token, page_token, acc) do
    params =
      [pageSize: 5000, currencyCode: "USD"]
      |> then(fn p -> if page_token, do: Keyword.put(p, :pageToken, page_token), else: p end)

    url = "https://cloudbilling.googleapis.com/v1/services/#{@compute_service_id}/skus"

    case Req.get(url, params: params, auth: {:bearer, token}, receive_timeout: 60_000) do
      {:ok, %{status: 200, body: body}} ->
        skus = Map.get(body, "skus", [])
        all = acc ++ skus

        case body["nextPageToken"] do
          nil -> {:ok, all}
          "" -> {:ok, all}
          next -> fetch_skus_page(token, next, all)
        end

      {:ok, %{status: status, body: body}} ->
        message =
          case body do
            %{"error" => %{"message" => msg}} -> msg
            _ -> "HTTP #{status}"
          end

        {:error, "Billing API error (#{status}): #{message}"}

      {:error, reason} ->
        {:error, "Billing API request failed: #{inspect(reason)}"}
    end
  end

  defp parse_skus(skus) do
    {machine_pricing, disk_pricing, license_pricing} =
      Enum.reduce(skus, {%{}, %{}, %{}}, fn sku, {mp, dp, lp} ->
        category = sku["category"] || %{}
        description = sku["description"] || ""
        usage_type = category["usageType"]
        resource_family = category["resourceFamily"]
        resource_group = category["resourceGroup"]
        regions = sku["serviceRegions"] || []
        price = extract_price(sku)

        cond do
          # Machine vCPU pricing
          resource_family == "Compute" and
            resource_group == "CPU" and
            usage_type == "OnDemand" and
              is_number(price) ->
            case match_machine_family(description) do
              nil ->
                {mp, dp, lp}

              family ->
                mp =
                  Enum.reduce(regions, mp, fn region, acc ->
                    key = {family, region}
                    existing = Map.get(acc, key, %{vcpu: nil, ram_gb: nil})
                    Map.put(acc, key, %{existing | vcpu: price})
                  end)

                {mp, dp, lp}
            end

          # Machine RAM pricing
          resource_family == "Compute" and
            resource_group == "RAM" and
            usage_type == "OnDemand" and
              is_number(price) ->
            case match_machine_family(description) do
              nil ->
                {mp, dp, lp}

              family ->
                mp =
                  Enum.reduce(regions, mp, fn region, acc ->
                    key = {family, region}
                    existing = Map.get(acc, key, %{vcpu: nil, ram_gb: nil})
                    Map.put(acc, key, %{existing | ram_gb: price})
                  end)

                {mp, dp, lp}
            end

          # Disk pricing
          resource_family == "Storage" and
            usage_type == "OnDemand" and
              is_number(price) ->
            case match_disk_type(description) do
              nil ->
                {mp, dp, lp}

              disk_type ->
                dp =
                  Enum.reduce(regions, dp, fn region, acc ->
                    Map.put(acc, {disk_type, region}, price)
                  end)

                {mp, dp, lp}
            end

          # License pricing (premium OS images)
          resource_family == "License" and
            usage_type == "OnDemand" and
            is_number(price) and price > 0 ->
            case match_license(description) do
              nil ->
                {mp, dp, lp}

              os_key ->
                model = if resource_group == "CPU", do: :per_vcpu, else: :per_instance
                existing = Map.get(lp, os_key, %{per_vcpu: nil, per_instance: nil})
                lp = Map.put(lp, os_key, Map.put(existing, model, price))
                {mp, dp, lp}
            end

          true ->
            {mp, dp, lp}
        end
      end)

    %{machine: machine_pricing, disk: disk_pricing, license: license_pricing}
  end

  defp extract_price(sku) do
    rates =
      get_in(sku, ["pricingInfo", Access.at(0), "pricingExpression", "tieredRates"]) || []

    # Use the last tiered rate — the first tier is often a free-tier $0 placeholder
    case List.last(rates) do
      %{"unitPrice" => %{"units" => units, "nanos" => nanos}} ->
        parse_units(units) + nanos / 1_000_000_000

      _ ->
        nil
    end
  end

  defp parse_units(units) when is_integer(units), do: units / 1
  defp parse_units(units) when is_binary(units), do: String.to_integer(units) / 1
  defp parse_units(_), do: 0

  defp match_machine_family(description) do
    Enum.find_value(@sku_family_patterns, fn {prefix, family} ->
      if String.starts_with?(description, prefix), do: family
    end)
  end

  defp match_disk_type(description) do
    Enum.find_value(@disk_type_patterns, fn {prefix, disk_type} ->
      if String.contains?(description, prefix), do: disk_type
    end)
  end

  defp match_license(description) do
    Enum.find_value(@license_patterns, fn {fragment, os_key} ->
      if String.contains?(description, fragment), do: os_key
    end)
  end

  defp machine_family(machine_type) when is_binary(machine_type) do
    case Regex.run(~r/^([a-z]\d+[a-z]?)-/, machine_type) do
      [_, family] -> family
      _ -> nil
    end
  end

  defp machine_family(_), do: nil

  defp find_machine_pricing(machine_map, family, region)
       when is_binary(family) and is_binary(region) do
    case Map.get(machine_map, {family, region}) do
      %{vcpu: v, ram_gb: r} = pricing when is_number(v) and is_number(r) -> pricing
      _ -> nil
    end
  end

  defp find_machine_pricing(_, _, _), do: nil

  defp find_disk_pricing(disk_map, disk_type, region)
       when is_binary(disk_type) and is_binary(region) do
    Map.get(disk_map, {disk_type, region})
  end

  defp find_disk_pricing(_, _, _), do: nil
end
