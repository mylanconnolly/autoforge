defmodule AutoforgeWeb.VmTemplateFormLive do
  use AutoforgeWeb, :live_view

  alias Autoforge.Config.GoogleServiceAccountConfig
  alias Autoforge.Deployments.VmTemplate
  alias Autoforge.Google.{Auth, ComputeEngine}

  require Ash.Query

  on_mount {AutoforgeWeb.LiveUserAuth, :live_user_required}

  # Families that only support Hyperdisk (no Persistent Disk)
  @hyperdisk_only_families ~w(c4a c4d)
  # Families that only support Persistent Disk (no Hyperdisk)
  @pd_only_families ~w(e2 n1 c2 c2d t2d t2a a2)

  @impl true
  def mount(params, _session, socket) do
    user = socket.assigns.current_user

    {form, editing?, template_id, current_region, current_zone} =
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

            {form, true, id, template.region, template.zone}
          else
            {nil, false, nil, nil, nil}
          end

        _ ->
          form =
            VmTemplate
            |> AshPhoenix.Form.for_create(:create, actor: user)
            |> to_form()

          {form, false, nil, "us-central1", "us-central1-a"}
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
          # Loading states
          region_options: nil,
          zone_options: nil,
          machine_type_options: nil,
          disk_type_options: nil,
          all_disk_type_options: nil,
          os_image_options: nil,
          all_os_images: [],
          selected_arch: "X86_64",
          loading_images: true,
          regions_to_zones: %{},
          loading_regions: true,
          loading_zones: true,
          loading_machine_types: true,
          loading_disk_types: true,
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

          regions_result = Task.await(regions_task, 15_000)
          zones_result = Task.await(zones_task, 15_000)

          {regions_result, zones_result}
        end)
        |> start_async(:fetch_os_images, fn -> fetch_all_os_images(token) end)

      {:error, reason} ->
        assign(socket,
          loading_regions: false,
          loading_zones: false,
          loading_machine_types: false,
          loading_disk_types: false,
          loading_images: false,
          api_error: reason
        )
    end
  end

  defp get_gce_credentials do
    with {:ok, sa_config} <- get_service_account_config(),
         {:ok, token} <- Auth.get_access_token(sa_config, ComputeEngine.scopes()) do
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
  def handle_async(:fetch_regions_and_zones, {:ok, {regions_result, zones_result}}, socket) do
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

        socket =
          socket
          |> assign(
            region_options: region_options,
            zone_options: zone_options,
            regions_to_zones: regions_to_zones,
            loading_regions: false,
            loading_zones: false,
            current_zone: current_zone
          )
          |> fetch_zone_resources(current_zone)

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
    machine_type_options =
      case machine_types_result do
        {:ok, types} ->
          types
          |> Enum.reject(fn mt -> String.starts_with?(mt["name"], "custom-") end)
          |> Enum.sort_by(fn mt -> machine_type_sort_key(mt["name"]) end)
          |> Enum.map(fn mt ->
            memory_gb = Float.round(mt["memoryMb"] / 1024, 1)

            memory_label =
              if memory_gb == trunc(memory_gb),
                do: "#{trunc(memory_gb)} GB",
                else: "#{memory_gb} GB"

            {"#{mt["name"]} (#{mt["guestCpus"]} vCPU, #{memory_label})", mt["name"]}
          end)

        {:error, _} ->
          nil
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

    filtered_disk_types = filter_disk_types_for_machine(disk_type_options, current_machine_type)

    {:noreply,
     assign(socket,
       machine_type_options: machine_type_options,
       all_disk_type_options: disk_type_options,
       disk_type_options: filtered_disk_types,
       loading_machine_types: false,
       loading_disk_types: false
     )}
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
            arch: latest["architecture"] || "X86_64"
          }
        end)
      end)
      |> Enum.sort_by(& &1.label)

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
       selected_arch: selected_arch,
       loading_images: false
     )}
  end

  def handle_async(:fetch_os_images, {:exit, _reason}, socket) do
    {:noreply, assign(socket, loading_images: false)}
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

  defp filter_disk_types_for_machine(nil, _machine_type), do: nil

  defp filter_disk_types_for_machine(all_options, machine_type) do
    family = machine_family(machine_type)

    cond do
      family in @hyperdisk_only_families ->
        Enum.filter(all_options, fn {_label, value} ->
          String.starts_with?(value, "hyperdisk-")
        end)

      family in @pd_only_families ->
        Enum.filter(all_options, fn {_label, value} -> String.starts_with?(value, "pd-") end)

      true ->
        all_options
    end
  end

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

  defp handle_api_error(socket, reason) do
    assign(socket,
      loading_regions: false,
      loading_zones: false,
      loading_machine_types: false,
      loading_disk_types: false,
      loading_images: false,
      api_error: to_string(reason)
    )
  end

  defp build_zone_options(regions_to_zones, region) do
    regions_to_zones
    |> Map.get(region, [])
    |> Enum.map(fn z -> {z, z} end)
  end

  @impl true
  def handle_event("set_arch", %{"arch" => arch}, socket) do
    options = filter_images_by_arch(socket.assigns.all_os_images, arch)
    {:noreply, assign(socket, selected_arch: arch, os_image_options: options)}
  end

  def handle_event("validate", %{"form" => params}, socket) do
    new_region = params["region"]
    old_region = socket.assigns.current_region
    new_zone = params["zone"]
    old_zone = socket.assigns.current_zone

    {params, socket} =
      cond do
        new_region != old_region and new_region != nil and new_region != "" ->
          zone_options = build_zone_options(socket.assigns.regions_to_zones, new_region)
          zone_values = Enum.map(zone_options, fn {_l, v} -> v end)

          resolved_zone =
            if new_zone in zone_values,
              do: new_zone,
              else: List.first(zone_values)

          params = Map.put(params, "zone", resolved_zone)

          socket =
            socket
            |> assign(
              zone_options: zone_options,
              current_region: new_region,
              current_zone: resolved_zone
            )
            |> fetch_zone_resources(resolved_zone)

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

    form =
      socket.assigns.form.source
      |> AshPhoenix.Form.validate(params)
      |> to_form()

    # Re-filter disk types when machine type changes
    disk_type_options =
      filter_disk_types_for_machine(
        socket.assigns.all_disk_type_options,
        params["machine_type"]
      )

    {:noreply, assign(socket, form: form, disk_type_options: disk_type_options)}
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
                />

                <.async_select
                  field={@form[:os_image]}
                  label="OS Image"
                  placeholder="Select an OS image..."
                  options={@os_image_options}
                  loading={@loading_images}
                  searchable
                  search_input_placeholder="Search OS images..."
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
                />

                <.async_select
                  field={@form[:zone]}
                  label="Zone"
                  placeholder="Select a zone..."
                  options={@zone_options}
                  loading={@loading_zones}
                  searchable
                  search_input_placeholder="Search zones..."
                />
              </div>

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
    ~H"""
    <.select
      field={@field}
      label={@label}
      placeholder={@placeholder}
      options={@options}
      searchable={assigns[:searchable] || false}
      search_input_placeholder={assigns[:search_input_placeholder] || ""}
    />
    """
  end
end
