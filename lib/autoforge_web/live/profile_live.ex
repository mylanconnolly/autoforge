defmodule AutoforgeWeb.ProfileLive do
  use AutoforgeWeb, :live_view

  on_mount {AutoforgeWeb.LiveUserAuth, :live_user_required}

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user

    form =
      user
      |> AshPhoenix.Form.for_update(:update_profile,
        actor: user,
        forms: [auto?: true]
      )
      |> to_form()

    timezone_options =
      TzExtra.time_zone_ids()
      |> Enum.map(&{&1, &1})

    {:ok,
     assign(socket,
       page_title: "Profile",
       form: form,
       timezone_options: timezone_options
     )}
  end

  @impl true
  def handle_event("validate", %{"form" => params}, socket) do
    form =
      socket.assigns.form.source
      |> AshPhoenix.Form.validate(params)
      |> to_form()

    {:noreply, assign(socket, form: form)}
  end

  def handle_event("save", %{"form" => params}, socket) do
    case AshPhoenix.Form.submit(socket.assigns.form.source, params: params) do
      {:ok, user} ->
        form =
          user
          |> AshPhoenix.Form.for_update(:update_profile,
            actor: user,
            forms: [auto?: true]
          )
          |> to_form()

        socket =
          socket
          |> put_flash(:info, "Profile updated successfully.")
          |> assign(form: form)

        {:noreply, socket}

      {:error, form} ->
        {:noreply, assign(socket, form: to_form(form))}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user} active_page={:profile}>
      <div class="max-w-2xl mx-auto">
        <div class="mb-6">
          <h1 class="text-2xl font-bold tracking-tight">Profile Settings</h1>
          <p class="mt-2 text-base-content/70">
            Manage your display name and timezone preferences.
          </p>
        </div>

        <div class="card bg-base-200 shadow-sm">
          <div class="card-body">
            <.form for={@form} phx-change="validate" phx-submit="save" class="space-y-4">
              <.input field={@form[:name]} label="Display Name" placeholder="Enter your name" />

              <.autocomplete
                field={@form[:timezone]}
                label="Timezone"
                options={@timezone_options}
                placeholder="Search for a timezone..."
                search_mode="contains"
                clearable
              />

              <div class="pt-2">
                <.button type="submit" variant="solid" color="primary">
                  Save Changes
                </.button>
              </div>
            </.form>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
