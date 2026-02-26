defmodule AutoforgeWeb.VmTemplateFormLive do
  use AutoforgeWeb, :live_view

  alias Autoforge.Config.GoogleServiceAccountConfig
  alias Autoforge.Deployments.VmTemplate
  alias Autoforge.Google.{Auth, ComputeEngine, Pricing}

  require Ash.Query
  require Logger

  on_mount {AutoforgeWeb.LiveUserAuth, :live_user_required}

  # Per-family disk type rules: allowed prefixes and minimum vCPU gates.
  # Families not listed here allow all disk types (safe default).
  @family_disk_rules %{
    # Hyperdisk-only families
    "c4a" => %{prefixes: ["hyperdisk-"], min_vcpus: %{"hyperdisk-extreme" => 64}},
    "c4d" => %{prefixes: ["hyperdisk-"], min_vcpus: %{"hyperdisk-extreme" => 64}},
    # PD-only families
    "e2" => %{prefixes: ["pd-"]},
    "n1" => %{prefixes: ["pd-"]},
    "c2" => %{prefixes: ["pd-"]},
    "c2d" => %{prefixes: ["pd-"]},
    "t2d" => %{prefixes: ["pd-"]},
    "t2a" => %{prefixes: ["pd-"]},
    "a2" => %{prefixes: ["pd-"]},
    # Families supporting both, with hyperdisk-extreme vCPU gates
    "c3" => %{prefixes: ["pd-", "hyperdisk-"], min_vcpus: %{"hyperdisk-extreme" => 88}},
    "c3d" => %{prefixes: ["pd-", "hyperdisk-"], min_vcpus: %{"hyperdisk-extreme" => 60}},
    "n2" => %{prefixes: ["pd-", "hyperdisk-"], min_vcpus: %{"hyperdisk-extreme" => 80}},
    "n2d" => %{prefixes: ["pd-", "hyperdisk-"], min_vcpus: %{"hyperdisk-extreme" => 64}},
    "c4" => %{prefixes: ["pd-", "hyperdisk-"], min_vcpus: %{"hyperdisk-extreme" => 96}},
    "m3" => %{prefixes: ["pd-", "hyperdisk-"], min_vcpus: %{"hyperdisk-extreme" => 128}}
  }

  @impl true
  def mount(params, _session, socket) do
    user = socket.assigns.current_user

    {form, editing?, template_id, current_region, current_zone, current_network} =
      case params do
        %{"id" => id} ->
          template =
            VmTemplate
            |> Ash.Query.filter(id == ^id)
            |> Ash.read_one!(actor: user)

          if template do
            form =
              template
              |> AshPhoenix.Form.for_update(:update, actor: user)
              |> to_form()

            {form, true, id, template.region, template.zone, template.network}
          else
            {nil, false, nil, nil, nil, nil}
          end

        _ ->
          form =
            VmTemplate
            |> AshPhoenix.Form.for_create(:create, actor: user)
            |> to_form()

          {form, false, nil, "us-central1", "us-central1-a", nil}
      end

    if is_nil(form) do
      {:ok,
       socket
       |> put_flash(:error, "VM template not found.")
       |> push_navigate(to: ~p"/vm-templates")}
    else
      socket =
        socket
        |> assign(
          page_title: if(editing?, do: "Edit VM Template", else: "New VM Template"),
          form: form,
          editing?: editing?,
          template_id: template_id,
          current_region: current_region,
          current_zone: current_zone,
          current_network: current_network,
          # Loading states
          region_options: nil,
          region_base_options: nil,
          zone_options: nil,
          zone_base_options: nil,
          machine_type_options: nil,
          machine_type_base_options: nil,
          disk_type_options: nil,
          disk_type_base_options: nil,
          all_disk_type_options: nil,
          os_image_options: nil,
          os_image_base_options: nil,
          all_os_images: [],
          selected_arch: "X86_64",
          loading_images: true,
          premium_image_values: MapSet.new(),
          latest_image_values: MapSet.new(),
          pricing: nil,
          price_estimate: nil,
          machine_type_specs: %{},
          regions_to_zones: %{},
          loading_regions: true,
          loading_zones: true,
          loading_machine_types: true,
          loading_disk_types: true,
          # Network / subnetwork
          network_options: nil,
          network_base_options: nil,
          all_networks: [],
          subnetwork_options: nil,
          subnetwork_base_options: nil,
          all_subnetworks: [],
          loading_networks: true,
          loading_subnetworks: true,
          api_error: nil
        )
        |> maybe_fetch_gce_options()

      {:ok, socket}
    end
  end

  defp maybe_fetch_gce_options(socket) do
    case get_gce_credentials() do
      {:ok, token, project_id} ->
        socket
        |> assign(token: token, project_id: project_id)
        |> start_async(:fetch_regions_and_zones, fn ->
          regions_task = Task.async(fn -> ComputeEngine.list_regions(token, project_id) end)
          zones_task = Task.async(fn -> ComputeEngine.list_zones(token, project_id) end)
          networks_task = Task.async(fn -> ComputeEngine.list_networks(token, project_id) end)

          regions_result = Task.await(regions_task, 15_000)
          zones_result = Task.await(zones_task, 15_000)
          networks_result = Task.await(networks_task, 15_000)

          {regions_result, zones_result, networks_result}
        end)
        |> start_async(:fetch_os_images, fn -> fetch_all_os_images(token) end)
        |> start_async(:fetch_pricing, fn -> Pricing.get_or_fetch(token) end)

      {:error, reason} ->
        assign(socket,
          loading_regions: false,
          loading_zones: false,
          loading_machine_types: false,
          loading_disk_types: false,
          loading_images: false,
          loading_networks: false,
          loading_subnetworks: false,
          api_error: reason
        )
    end
  end

  defp get_gce_credentials do
    scopes = ComputeEngine.scopes() ++ Pricing.scopes()

    with {:ok, sa_config} <- get_service_account_config(),
         {:ok, token} <- Auth.get_access_token(sa_config, scopes) do
      {:ok, token, sa_config.project_id}
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

  @impl true
  def handle_async(
        :fetch_regions_and_zones,
        {:ok, {regions_result, zones_result, networks_result}},
        socket
      ) do
    case {regions_result, zones_result} do
      {{:ok, regions}, {:ok, zones}} ->
        region_options =
          regions
          |> Enum.map(fn r -> {r["name"], r["name"]} end)
          |> Enum.sort_by(&elem(&1, 0))

        regions_to_zones =
          zones
          |> Enum.filter(fn z -> z["status"] == "UP" end)
          |> Enum.group_by(
            fn z ->
              z["region"]
              |> String.split("/")
              |> List.last()
            end,
            fn z -> z["name"] end
          )
          |> Map.new(fn {region, zone_names} -> {region, Enum.sort(zone_names)} end)

        current_region = socket.assigns.current_region
        current_zone = socket.assigns.current_zone

        zone_options = build_zone_options(regions_to_zones, current_region)

        # If saved zone is not in the list, pick the first available
        zone_values = Enum.map(zone_options, fn {_l, v} -> v end)

        current_zone =
          if current_zone in zone_values,
            do: current_zone,
            else: List.first(zone_values) || current_zone

        # Process networks
        {all_networks, network_options} =
          case networks_result do
            {:ok, nets} ->
              sorted =
                nets
                |> Enum.sort_by(fn n -> n["name"] end)

              options =
                Enum.map(sorted, fn n ->
                  mode = if n["autoCreateSubnetworks"], do: "auto", else: "custom"
                  {"#{n["name"]} (#{mode})", n["name"]}
                end)

              {sorted, options}

            {:error, _} ->
              {[], nil}
          end

        socket =
          socket
          |> assign(
            region_options: region_options,
            region_base_options: region_options,
            zone_options: zone_options,
            zone_base_options: zone_options,
            regions_to_zones: regions_to_zones,
            loading_regions: false,
            loading_zones: false,
            current_zone: current_zone,
            all_networks: all_networks,
            network_options: network_options,
            network_base_options: network_options,
            loading_networks: false
          )
          |> fetch_zone_resources(current_zone)
          |> fetch_subnetworks(current_region)

        {:noreply, socket}

      {{:error, reason}, _} ->
        {:noreply, handle_api_error(socket, reason)}

      {_, {:error, reason}} ->
        {:noreply, handle_api_error(socket, reason)}
    end
  end

  def handle_async(:fetch_regions_and_zones, {:exit, reason}, socket) do
    {:noreply, handle_api_error(socket, "Failed to fetch regions: #{inspect(reason)}")}
  end

  def handle_async(
        :fetch_zone_resources,
        {:ok, {machine_types_result, disk_types_result}},
        socket
      ) do
    {machine_type_options, machine_type_specs} =
      case machine_types_result do
        {:ok, types} ->
          filtered =
            types
            |> Enum.reject(fn mt -> String.starts_with?(mt["name"], "custom-") end)
            |> Enum.sort_by(fn mt -> machine_type_sort_key(mt["name"]) end)

          options =
            Enum.map(filtered, fn mt ->
              memory_gb = Float.round(mt["memoryMb"] / 1024, 1)

              memory_label =
                if memory_gb == trunc(memory_gb),
                  do: "#{trunc(memory_gb)} GB",
                  else: "#{memory_gb} GB"

              {"#{mt["name"]} (#{mt["guestCpus"]} vCPU, #{memory_label})", mt["name"]}
            end)

          specs =
            Map.new(filtered, fn mt ->
              {mt["name"],
               %{vcpus: mt["guestCpus"], ram_gb: Float.round(mt["memoryMb"] / 1024, 2)}}
            end)

          {options, specs}

        {:error, _} ->
          {nil, %{}}
      end

    disk_type_options =
      case disk_types_result do
        {:ok, types} ->
          types
          |> Enum.sort_by(fn dt -> dt["name"] end)
          |> Enum.map(fn dt ->
            {"#{dt["description"]} (#{dt["name"]})", dt["name"]}
          end)

        {:error, _} ->
          nil
      end

    current_machine_type =
      AshPhoenix.Form.value(socket.assigns.form.source, :machine_type)

    filtered_disk_types =
      filter_disk_types_for_machine(disk_type_options, current_machine_type, machine_type_specs)

    {:noreply,
     socket
     |> assign(
       machine_type_options: machine_type_options,
       machine_type_base_options: machine_type_options,
       machine_type_specs: machine_type_specs,
       all_disk_type_options: disk_type_options,
       disk_type_options: filtered_disk_types,
       disk_type_base_options: filtered_disk_types,
       loading_machine_types: false,
       loading_disk_types: false
     )
     |> recalculate_price_estimate()}
  end

  def handle_async(:fetch_zone_resources, {:exit, reason}, socket) do
    {:noreply,
     assign(socket,
       machine_type_options: nil,
       all_disk_type_options: nil,
       disk_type_options: nil,
       loading_machine_types: false,
       loading_disk_types: false,
       api_error: "Failed to fetch zone resources: #{inspect(reason)}"
     )}
  end

  def handle_async(:fetch_subnetworks, {:ok, {:ok, subnetworks}}, socket) do
    current_network = socket.assigns.current_network

    all_subnetworks =
      subnetworks
      |> Enum.sort_by(fn s -> s["name"] end)

    options = build_subnetwork_options(all_subnetworks, current_network)

    {:noreply,
     assign(socket,
       all_subnetworks: all_subnetworks,
       subnetwork_options: options,
       subnetwork_base_options: options,
       loading_subnetworks: false
     )}
  end

  def handle_async(:fetch_subnetworks, {:ok, {:error, reason}}, socket) do
    Logger.warning("Failed to fetch subnetworks: #{reason}")

    {:noreply,
     assign(socket,
       all_subnetworks: [],
       subnetwork_options: nil,
       subnetwork_base_options: nil,
       loading_subnetworks: false
     )}
  end

  def handle_async(:fetch_subnetworks, {:exit, reason}, socket) do
    Logger.warning("Subnetwork fetch crashed: #{inspect(reason)}")

    {:noreply,
     assign(socket,
       all_subnetworks: [],
       subnetwork_options: nil,
       subnetwork_base_options: nil,
       loading_subnetworks: false
     )}
  end

  def handle_async(:fetch_os_images, {:ok, results}, socket) do
    project_map =
      Map.new(ComputeEngine.image_projects(), fn {label, name} -> {name, label} end)

    all_images =
      results
      |> Enum.flat_map(fn {project, images} ->
        label = Map.get(project_map, project, project)

        images
        |> Enum.reject(&image_deprecated?/1)
        |> Enum.filter(& &1["family"])
        |> Enum.group_by(& &1["family"])
        |> Enum.map(fn {family, family_images} ->
          latest = Enum.max_by(family_images, & &1["creationTimestamp"])

          %{
            label: "#{label} - #{family}",
            value: "projects/#{project}/global/images/family/#{family}",
            arch: latest["architecture"] || "X86_64",
            project: project
          }
        end)
      end)
      |> Enum.sort_by(& &1.label)

    premium_values =
      all_images
      |> Enum.filter(fn img -> image_license_key(img.value) != nil end)
      |> Enum.map(& &1.value)
      |> MapSet.new()

    latest_values =
      all_images
      |> Enum.group_by(fn img ->
        family = image_family_from_value(img.value)
        {img.project, img.arch, image_family_base(family)}
      end)
      |> Enum.flat_map(fn {_key, imgs} ->
        if length(imgs) > 1 do
          newest =
            Enum.max_by(imgs, fn img ->
              img.value |> image_family_from_value() |> natural_sort_key()
            end)

          [newest.value]
        else
          []
        end
      end)
      |> MapSet.new()

    # Auto-detect architecture from the current form value when editing
    current_image = AshPhoenix.Form.value(socket.assigns.form.source, :os_image)

    selected_arch =
      case Enum.find(all_images, fn img -> img.value == current_image end) do
        %{arch: arch} -> arch
        nil -> socket.assigns.selected_arch
      end

    options = filter_images_by_arch(all_images, selected_arch)

    {:noreply,
     assign(socket,
       all_os_images: all_images,
       os_image_options: options,
       os_image_base_options: options,
       selected_arch: selected_arch,
       loading_images: false,
       premium_image_values: premium_values,
       latest_image_values: latest_values
     )}
  end

  def handle_async(:fetch_os_images, {:exit, _reason}, socket) do
    {:noreply, assign(socket, loading_images: false)}
  end

  def handle_async(:fetch_pricing, {:ok, {:ok, pricing}}, socket) do
    {:noreply,
     socket
     |> assign(pricing: pricing)
     |> recalculate_price_estimate()}
  end

  def handle_async(:fetch_pricing, {:ok, {:error, reason}}, socket) do
    Logger.warning("Failed to fetch GCE pricing: #{reason}")
    {:noreply, socket}
  end

  def handle_async(:fetch_pricing, {:exit, reason}, socket) do
    Logger.warning("Pricing fetch crashed: #{inspect(reason)}")
    {:noreply, socket}
  end

  defp fetch_all_os_images(token) do
    ComputeEngine.image_projects()
    |> Task.async_stream(
      fn {_label, project} ->
        case ComputeEngine.list_images(token, project) do
          {:ok, images} -> {project, images}
          {:error, _} -> {project, []}
        end
      end,
      max_concurrency: 4,
      timeout: 30_000
    )
    |> Enum.map(fn {:ok, result} -> result end)
  end

  defp image_deprecated?(%{"deprecated" => %{"state" => state}})
       when state in ["DEPRECATED", "OBSOLETE", "DELETED"],
       do: true

  defp image_deprecated?(_), do: false

  defp machine_type_sort_key(name) do
    case Regex.run(~r/^(.+?)-(\d+)$/, name) do
      [_, family, cores] -> {family, String.to_integer(cores)}
      _ -> {name, 0}
    end
  end

  defp machine_family(machine_type) when is_binary(machine_type) do
    case Regex.run(~r/^([a-z]\d+[a-z]?)-/, machine_type) do
      [_, family] -> family
      _ -> nil
    end
  end

  defp machine_family(_), do: nil

  defp filter_disk_types_for_machine(nil, _machine_type, _specs), do: nil

  defp filter_disk_types_for_machine(all_options, machine_type, specs) do
    family = machine_family(machine_type)
    vcpus = get_in(specs, [machine_type, :vcpus])

    case Map.get(@family_disk_rules, family) do
      nil ->
        all_options

      %{prefixes: prefixes} = rules ->
        min_vcpus = Map.get(rules, :min_vcpus, %{})

        Enum.filter(all_options, fn {_label, value} ->
          prefix_allowed?(value, prefixes) and vcpu_allowed?(value, vcpus, min_vcpus)
        end)
    end
  end

  defp prefix_allowed?(value, prefixes) do
    Enum.any?(prefixes, &String.starts_with?(value, &1))
  end

  defp vcpu_allowed?(_value, nil, _min_vcpus), do: true

  defp vcpu_allowed?(value, vcpus, min_vcpus) do
    case Map.get(min_vcpus, value) do
      nil -> true
      min -> vcpus >= min
    end
  end

  @hours_per_month 730

  defp recalculate_price_estimate(socket, params \\ nil) do
    pricing = socket.assigns.pricing

    if is_nil(pricing) do
      assign(socket, price_estimate: nil)
    else
      form = socket.assigns.form.source

      machine_type =
        (params && params["machine_type"]) || AshPhoenix.Form.value(form, :machine_type)

      disk_type = (params && params["disk_type"]) || AshPhoenix.Form.value(form, :disk_type)
      disk_size = (params && params["disk_size_gb"]) || AshPhoenix.Form.value(form, :disk_size_gb)
      region = (params && params["region"]) || AshPhoenix.Form.value(form, :region)
      os_image = (params && params["os_image"]) || AshPhoenix.Form.value(form, :os_image)
      specs = Map.get(socket.assigns.machine_type_specs, machine_type)

      disk_size = parse_disk_size(disk_size)

      compute_hourly =
        if specs do
          case Pricing.estimate_machine_hourly(
                 pricing,
                 machine_type,
                 region,
                 specs.vcpus,
                 specs.ram_gb
               ) do
            {:ok, h} -> h
            _ -> nil
          end
        end

      disk_monthly =
        if disk_type && disk_size && region do
          case Pricing.estimate_disk_monthly(pricing, disk_type, region, disk_size) do
            {:ok, d} -> d
            _ -> nil
          end
        end

      os_key = image_license_key(os_image)

      license_hourly =
        if os_key && specs do
          case Pricing.estimate_license_hourly(pricing, os_key, specs.vcpus) do
            {:ok, h} when h > 0 -> h
            _ -> nil
          end
        end

      compute_monthly = if compute_hourly, do: compute_hourly * @hours_per_month
      license_monthly = if license_hourly, do: license_hourly * @hours_per_month

      total =
        [compute_monthly, disk_monthly, license_monthly]
        |> Enum.reject(&is_nil/1)
        |> case do
          [] -> nil
          costs -> Enum.sum(costs)
        end

      estimate =
        if total do
          %{
            compute_hourly: compute_hourly,
            compute_monthly: compute_monthly,
            disk_monthly: disk_monthly,
            license_hourly: license_hourly,
            license_monthly: license_monthly,
            total_monthly: total
          }
        end

      assign(socket, price_estimate: estimate)
    end
  end

  defp image_family_from_value(value) do
    value |> String.split("/") |> List.last()
  end

  # Strips version numbers and arch suffixes to get the product line base name.
  # e.g. "ubuntu-pro-2404-lts-amd64" -> "ubuntu-pro-lts"
  #      "debian-12"                  -> "debian"
  defp image_family_base(family) do
    family
    |> String.replace(~r/-(amd64|arm64|x86-64)$/, "")
    |> String.replace(~r/\d+/, "")
    |> String.replace(~r/-+/, "-")
    |> String.trim("-")
  end

  # Natural sort key — splits a string into text/number segments so that
  # "9" sorts before "10" and "2204" before "2404".
  defp natural_sort_key(string) do
    Regex.split(~r/(\d+)/, string, include_captures: true)
    |> Enum.map(fn part ->
      case Integer.parse(part) do
        {n, ""} -> {1, n, ""}
        _ -> {0, 0, part}
      end
    end)
  end

  defp image_license_key(os_image) when is_binary(os_image) do
    cond do
      String.contains?(os_image, "ubuntu-os-pro-cloud") -> "ubuntu-pro"
      String.contains?(os_image, "rhel-cloud") -> "rhel"
      String.contains?(os_image, "suse-cloud") -> "sles"
      true -> nil
    end
  end

  defp image_license_key(_), do: nil

  defp parse_disk_size(n) when is_integer(n), do: n

  defp parse_disk_size(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, _} -> n
      :error -> nil
    end
  end

  defp parse_disk_size(_), do: nil

  defp filter_images_by_arch(images, arch) do
    images
    |> Enum.filter(fn img -> img.arch == arch end)
    |> Enum.map(fn img -> {img.label, img.value} end)
  end

  defp fetch_zone_resources(socket, zone) when is_binary(zone) and zone != "" do
    token = socket.assigns.token
    project_id = socket.assigns.project_id

    socket
    |> assign(loading_machine_types: true, loading_disk_types: true)
    |> start_async(:fetch_zone_resources, fn ->
      mt_task = Task.async(fn -> ComputeEngine.list_machine_types(token, project_id, zone) end)
      dt_task = Task.async(fn -> ComputeEngine.list_disk_types(token, project_id, zone) end)

      mt_result = Task.await(mt_task, 15_000)
      dt_result = Task.await(dt_task, 15_000)

      {mt_result, dt_result}
    end)
  end

  defp fetch_zone_resources(socket, _zone), do: socket

  defp fetch_subnetworks(socket, region) when is_binary(region) and region != "" do
    token = socket.assigns.token
    project_id = socket.assigns.project_id

    socket
    |> assign(loading_subnetworks: true)
    |> start_async(:fetch_subnetworks, fn ->
      ComputeEngine.list_subnetworks(token, project_id, region)
    end)
  end

  defp fetch_subnetworks(socket, _region), do: socket

  defp handle_api_error(socket, reason) do
    assign(socket,
      loading_regions: false,
      loading_zones: false,
      loading_machine_types: false,
      loading_disk_types: false,
      loading_images: false,
      loading_networks: false,
      loading_subnetworks: false,
      api_error: to_string(reason)
    )
  end

  defp build_zone_options(regions_to_zones, region) do
    regions_to_zones
    |> Map.get(region, [])
    |> Enum.map(fn z -> {z, z} end)
  end

  defp build_subnetwork_options(all_subnetworks, network_name) do
    filtered =
      if network_name do
        Enum.filter(all_subnetworks, fn s ->
          s["network"] |> String.split("/") |> List.last() == network_name
        end)
      else
        all_subnetworks
      end

    Enum.map(filtered, fn s ->
      {"#{s["name"]} (#{s["ipCidrRange"]})", s["name"]}
    end)
  end

  @impl true
  def handle_event("set_arch", %{"arch" => arch}, socket) do
    options = filter_images_by_arch(socket.assigns.all_os_images, arch)

    {:noreply,
     assign(socket,
       selected_arch: arch,
       os_image_options: options,
       os_image_base_options: options
     )}
  end

  def handle_event("search_machine_types", %{"query" => q}, socket) do
    {:noreply,
     search_field(socket, q, :machine_type, :machine_type_base_options, :machine_type_options)}
  end

  def handle_event("search_disk_types", %{"query" => q}, socket) do
    {:noreply, search_field(socket, q, :disk_type, :disk_type_base_options, :disk_type_options)}
  end

  def handle_event("search_os_images", %{"query" => q}, socket) do
    {:noreply, search_field(socket, q, :os_image, :os_image_base_options, :os_image_options)}
  end

  def handle_event("search_networks", %{"query" => q}, socket) do
    {:noreply, search_field(socket, q, :network, :network_base_options, :network_options)}
  end

  def handle_event("search_subnetworks", %{"query" => q}, socket) do
    {:noreply,
     search_field(socket, q, :subnetwork, :subnetwork_base_options, :subnetwork_options)}
  end

  def handle_event("search_regions", %{"query" => q}, socket) do
    {:noreply, search_field(socket, q, :region, :region_base_options, :region_options)}
  end

  def handle_event("search_zones", %{"query" => q}, socket) do
    {:noreply, search_field(socket, q, :zone, :zone_base_options, :zone_options)}
  end

  def handle_event("validate", %{"form" => params}, socket) do
    new_region = params["region"]
    old_region = socket.assigns.current_region
    new_zone = params["zone"]
    old_zone = socket.assigns.current_zone
    new_network = params["network"]
    old_network = socket.assigns.current_network

    {params, socket} =
      cond do
        new_region != old_region and new_region != nil and new_region != "" ->
          zone_options = build_zone_options(socket.assigns.regions_to_zones, new_region)
          zone_values = Enum.map(zone_options, fn {_l, v} -> v end)

          resolved_zone =
            if new_zone in zone_values,
              do: new_zone,
              else: List.first(zone_values)

          # Clear subnetwork when region changes (subnetworks are per-region)
          params =
            params
            |> Map.put("zone", resolved_zone)
            |> Map.put("subnetwork", nil)

          socket =
            socket
            |> assign(
              zone_options: zone_options,
              zone_base_options: zone_options,
              current_region: new_region,
              current_zone: resolved_zone
            )
            |> fetch_zone_resources(resolved_zone)
            |> fetch_subnetworks(new_region)

          {params, socket}

        new_zone != old_zone and new_zone != nil and new_zone != "" ->
          socket =
            socket
            |> assign(current_zone: new_zone)
            |> fetch_zone_resources(new_zone)

          {params, socket}

        true ->
          {params, socket}
      end

    # Re-filter subnetworks when network changes
    {params, socket} =
      if new_network != old_network do
        options = build_subnetwork_options(socket.assigns.all_subnetworks, new_network)

        # Clear subnetwork if the current selection is not in the new list
        sub_values = Enum.map(options, fn {_l, v} -> v end)
        current_sub = params["subnetwork"]

        params =
          if current_sub not in sub_values,
            do: Map.put(params, "subnetwork", nil),
            else: params

        socket =
          socket
          |> assign(
            current_network: new_network,
            subnetwork_options: options,
            subnetwork_base_options: options
          )

        {params, socket}
      else
        {params, socket}
      end

    form =
      socket.assigns.form.source
      |> AshPhoenix.Form.validate(params)
      |> to_form()

    # Re-filter disk types when machine type changes
    disk_type_options =
      filter_disk_types_for_machine(
        socket.assigns.all_disk_type_options,
        params["machine_type"],
        socket.assigns.machine_type_specs
      )

    {:noreply,
     socket
     |> assign(
       form: form,
       disk_type_options: disk_type_options,
       disk_type_base_options: disk_type_options
     )
     |> recalculate_price_estimate(params)}
  end

  def handle_event("save", %{"form" => params}, socket) do
    case AshPhoenix.Form.submit(socket.assigns.form.source, params: params) do
      {:ok, _template} ->
        action = if socket.assigns.editing?, do: "updated", else: "created"

        {:noreply,
         socket
         |> put_flash(:info, "VM template #{action} successfully.")
         |> push_navigate(to: ~p"/vm-templates")}

      {:error, form} ->
        {:noreply, assign(socket, form: to_form(form))}
    end
  end

  defp search_field(socket, query, field, base_key, options_key) do
    current_value = AshPhoenix.Form.value(socket.assigns.form.source, field)
    base = Map.get(socket.assigns, base_key)
    filtered = fuzzy_filter_options(base, query, current_value)
    assign(socket, [{options_key, filtered}])
  end

  defp fuzzy_filter_options(nil, _query, _current_value), do: nil

  defp fuzzy_filter_options(options, query, current_value) do
    query = String.trim(query)

    if query == "" do
      options
    else
      tokens = query |> String.downcase() |> String.split(~r/\s+/, trim: true)

      Enum.filter(options, fn {label, value} ->
        value == current_value or
          Enum.all?(tokens, fn token -> String.contains?(String.downcase(label), token) end)
      end)
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user} active_page={:vm_templates}>
      <div>
        <div class="mb-6">
          <.link
            navigate={~p"/vm-templates"}
            class="text-sm text-base-content/60 hover:text-base-content transition-colors"
          >
            <.icon name="hero-arrow-left" class="w-4 h-4 inline-block mr-1" /> Back to VM Templates
          </.link>
          <h1 class="text-2xl font-bold tracking-tight mt-2">
            {if @editing?, do: "Edit VM Template", else: "New VM Template"}
          </h1>
          <p class="mt-2 text-base-content/70">
            {if @editing?,
              do: "Update your VM template configuration.",
              else: "Configure a reusable GCE VM template."}
          </p>
        </div>

        <div :if={@api_error} class="alert alert-warning mb-4">
          <.icon name="hero-exclamation-triangle" class="w-5 h-5" />
          <span>
            Could not load GCE options: {@api_error}. You can still fill in values manually.
          </span>
        </div>

        <div class="card bg-base-200 shadow-sm">
          <div class="card-body">
            <.form for={@form} phx-change="validate" phx-submit="save" class="space-y-4">
              <.input field={@form[:name]} label="Name" placeholder="Production Web Server" />

              <.textarea
                field={@form[:description]}
                label="Description"
                placeholder="A VM template for production web servers..."
                rows={3}
              />

              <div class="flex items-center gap-3">
                <span class="text-sm font-medium text-base-content/70">Architecture</span>
                <div class="flex gap-1">
                  <button
                    type="button"
                    phx-click="set_arch"
                    phx-value-arch="X86_64"
                    class={"btn btn-xs transition-colors " <> if(@selected_arch == "X86_64", do: "btn-primary", else: "btn-ghost")}
                  >
                    x86_64
                  </button>
                  <button
                    type="button"
                    phx-click="set_arch"
                    phx-value-arch="ARM64"
                    class={"btn btn-xs transition-colors " <> if(@selected_arch == "ARM64", do: "btn-primary", else: "btn-ghost")}
                  >
                    ARM64
                  </button>
                </div>
              </div>

              <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
                <.async_select
                  field={@form[:machine_type]}
                  label="Machine Type"
                  placeholder="Select a machine type..."
                  options={@machine_type_options}
                  loading={@loading_machine_types}
                  searchable
                  search_input_placeholder="Search machine types..."
                  on_search="search_machine_types"
                />

                <.os_image_select
                  field={@form[:os_image]}
                  options={@os_image_options}
                  loading={@loading_images}
                  premium_values={@premium_image_values}
                  latest_values={@latest_image_values}
                />
              </div>

              <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
                <.input
                  field={@form[:disk_size_gb]}
                  label="Disk Size (GB)"
                  type="number"
                  placeholder="50"
                  min="50"
                />

                <.async_select
                  field={@form[:disk_type]}
                  label="Disk Type"
                  placeholder="Select a disk type..."
                  options={@disk_type_options}
                  loading={@loading_disk_types}
                  searchable
                  search_input_placeholder="Search disk types..."
                  on_search="search_disk_types"
                />
              </div>

              <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
                <.async_select
                  field={@form[:region]}
                  label="Region"
                  placeholder="Select a region..."
                  options={@region_options}
                  loading={@loading_regions}
                  searchable
                  search_input_placeholder="Search regions..."
                  on_search="search_regions"
                />

                <.async_select
                  field={@form[:zone]}
                  label="Zone"
                  placeholder="Select a zone..."
                  options={@zone_options}
                  loading={@loading_zones}
                  searchable
                  search_input_placeholder="Search zones..."
                  on_search="search_zones"
                />
              </div>

              <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
                <.async_select
                  field={@form[:network]}
                  label="Network"
                  placeholder="Select a VPC network..."
                  options={@network_options}
                  loading={@loading_networks}
                  searchable
                  search_input_placeholder="Search networks..."
                  on_search="search_networks"
                />

                <.async_select
                  field={@form[:subnetwork]}
                  label="Subnetwork"
                  placeholder="Select a subnetwork..."
                  options={@subnetwork_options}
                  loading={@loading_subnetworks}
                  searchable
                  search_input_placeholder="Search subnetworks..."
                  on_search="search_subnetworks"
                />
              </div>

              <.price_estimate_card :if={@price_estimate} estimate={@price_estimate} />

              <.textarea
                field={@form[:startup_script]}
                label="Startup Script"
                placeholder="#!/bin/bash&#10;# Custom initialization commands..."
                rows={8}
                class="font-mono text-sm bg-base-300 border-base-300 rounded-lg px-3 py-2 w-full max-h-80 overflow-y-auto"
              />
              <p class="text-xs text-base-content/50 -mt-2">
                Additional cloud-init script appended after Docker, Caddy, and Tailscale setup.
              </p>

              <div class="flex items-center gap-3 pt-2">
                <.button type="submit" variant="solid" color="primary">
                  {if @editing?, do: "Save Changes", else: "Create Template"}
                </.button>
                <.link navigate={~p"/vm-templates"}>
                  <.button type="button" variant="ghost">
                    Cancel
                  </.button>
                </.link>
              </div>
            </.form>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp os_image_select(%{loading: true} = assigns) do
    ~H"""
    <div>
      <label class="fieldset-label mb-1">OS Image</label>
      <div class="flex items-center gap-2 h-10 px-3 bg-base-300 rounded-lg animate-pulse">
        <span class="loading loading-spinner loading-sm text-base-content/40"></span>
        <span class="text-sm text-base-content/40">Loading...</span>
      </div>
    </div>
    """
  end

  defp os_image_select(%{options: nil} = assigns) do
    ~H"""
    <div>
      <label class="fieldset-label mb-1">OS Image</label>
      <.input field={@field} placeholder="Select an OS image..." />
    </div>
    """
  end

  defp os_image_select(assigns) do
    ~H"""
    <div>
      <.select
        field={@field}
        label="OS Image"
        placeholder="Select an OS image..."
        options={@options}
        searchable
        search_input_placeholder="Search OS images..."
        on_search="search_os_images"
      >
        <:option :let={{label, value}}>
          <div class={[
            "flex items-center justify-between gap-2 px-3 py-1.5 rounded-lg",
            "in-data-highlighted:bg-base-200",
            "in-data-selected:bg-primary/10 in-data-selected:font-medium"
          ]}>
            <span class="truncate">{label}</span>
            <div class="flex items-center gap-1 shrink-0">
              <span
                :if={value in @latest_values}
                class="text-success"
                title="Latest for this distribution"
              >
                <.icon name="hero-star-solid" class="w-3.5 h-3.5" />
              </span>
              <span
                :if={value in @premium_values}
                class="text-warning"
                title="Premium image (license fee applies)"
              >
                <.icon name="hero-currency-dollar-solid" class="w-3.5 h-3.5" />
              </span>
            </div>
          </div>
        </:option>
      </.select>
      <p class="text-xs text-base-content/50 mt-1 flex items-center gap-3">
        <span class="inline-flex items-center gap-1">
          <.icon name="hero-star-solid" class="w-3 h-3 text-success" /> Latest
        </span>
        <span class="inline-flex items-center gap-1">
          <.icon name="hero-currency-dollar-solid" class="w-3 h-3 text-warning" /> License fee
        </span>
      </p>
    </div>
    """
  end

  defp async_select(%{loading: true} = assigns) do
    ~H"""
    <div>
      <label class="fieldset-label mb-1">{@label}</label>
      <div class="flex items-center gap-2 h-10 px-3 bg-base-300 rounded-lg animate-pulse">
        <span class="loading loading-spinner loading-sm text-base-content/40"></span>
        <span class="text-sm text-base-content/40">Loading...</span>
      </div>
    </div>
    """
  end

  defp async_select(%{options: nil} = assigns) do
    ~H"""
    <div>
      <label class="fieldset-label mb-1">{@label}</label>
      <.input field={@field} placeholder={@placeholder} />
    </div>
    """
  end

  defp async_select(assigns) do
    extra =
      if assigns[:on_search],
        do: %{on_search: assigns[:on_search]},
        else: %{}

    assigns = assign(assigns, :extra, extra)

    ~H"""
    <.select
      field={@field}
      label={@label}
      placeholder={@placeholder}
      options={@options}
      searchable={assigns[:searchable] || false}
      search_input_placeholder={assigns[:search_input_placeholder] || ""}
      {@extra}
    />
    """
  end

  defp price_estimate_card(assigns) do
    ~H"""
    <div class="rounded-lg border border-primary/20 bg-primary/5 px-4 py-3">
      <div class="flex items-center gap-2 mb-2">
        <.icon name="hero-calculator" class="w-4 h-4 text-primary" />
        <span class="text-sm font-semibold text-primary">Estimated Monthly Cost</span>
        <span class="text-xs text-base-content/50">(on-demand pricing)</span>
      </div>

      <div class="flex flex-wrap gap-x-6 gap-y-2 text-sm">
        <div :if={@estimate.compute_monthly}>
          <span class="text-base-content/60">Compute</span>
          <div class="font-mono font-medium">
            {format_price(@estimate.compute_monthly)}/mo
          </div>
          <div class="text-xs text-base-content/50">
            {format_price(@estimate.compute_hourly)}/hr
          </div>
        </div>

        <div :if={@estimate.disk_monthly}>
          <span class="text-base-content/60">Storage</span>
          <div class="font-mono font-medium">
            {format_price(@estimate.disk_monthly)}/mo
          </div>
        </div>

        <div :if={@estimate[:license_monthly]}>
          <span class="text-base-content/60">Image license</span>
          <div class="font-mono font-medium">
            {format_price(@estimate.license_monthly)}/mo
          </div>
          <div class="text-xs text-base-content/50">
            {format_price(@estimate.license_hourly)}/hr
          </div>
        </div>

        <div>
          <span class="text-base-content/60">Total</span>
          <div class="font-mono font-semibold text-base">
            ~{format_price(@estimate.total_monthly)}/mo
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp format_price(nil), do: "—"

  defp format_price(amount) when amount < 0.01 do
    "$" <> :erlang.float_to_binary(amount * 1.0, decimals: 4)
  end

  defp format_price(amount) do
    "$" <> :erlang.float_to_binary(amount * 1.0, decimals: 2)
  end
end
