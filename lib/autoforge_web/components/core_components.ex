defmodule AutoforgeWeb.CoreComponents do
  @moduledoc """
  Provides core UI components.

  At first glance, this module may seem daunting, but its goal is to provide
  core building blocks for your application, such as tables, forms, and
  inputs. The components consist mostly of markup and are well-documented
  with doc strings and declarative assigns. You may customize and style
  them in any way you want, based on your application growth and needs.

  The foundation for styling is Tailwind CSS, a utility-first CSS framework,
  augmented with daisyUI, a Tailwind CSS plugin that provides UI components
  and themes. Here are useful references:

    * [daisyUI](https://daisyui.com/docs/intro/) - a good place to get
      started and see the available components.

    * [Tailwind CSS](https://tailwindcss.com) - the foundational framework
      we build on. You will use it for layout, sizing, flexbox, grid, and
      spacing.

    * [Heroicons](https://heroicons.com) - see `icon/1` for usage.

    * [Phoenix.Component](https://hexdocs.pm/phoenix_live_view/Phoenix.Component.html) -
      the component system used by Phoenix. Some components, such as `<.link>`
      and `<.form>`, are defined there.

  """
  use Phoenix.Component
  use Gettext, backend: AutoforgeWeb.Gettext
  use Fluxon, only: [:button, :input]

  import Fluxon.Components.Alert

  alias Phoenix.LiveView.JS

  @doc """
  Renders flash notices.

  ## Examples

      <.flash kind={:info} flash={@flash} />
      <.flash kind={:info} phx-mounted={show("#flash")}>Welcome Back!</.flash>
  """
  attr :id, :string, doc: "the optional id of flash container"
  attr :flash, :map, default: %{}, doc: "the map of flash messages to display"
  attr :title, :string, default: nil
  attr :kind, :atom, values: [:info, :error], doc: "used for styling and flash lookup"
  attr :rest, :global, doc: "the arbitrary HTML attributes to add to the flash container"

  slot :inner_block, doc: "the optional inner block that renders the flash message"

  def flash(assigns) do
    assigns = assign_new(assigns, :id, fn -> "flash-#{assigns.kind}" end)

    ~H"""
    <div
      :if={msg = render_slot(@inner_block) || Phoenix.Flash.get(@flash, @kind)}
      id={@id}
      {@rest}
    >
      <.alert
        id={"#{@id}-alert"}
        color={if @kind == :error, do: "danger", else: "info"}
        title={@title}
        class="w-80 sm:w-96 shadow-lg"
        on_close={JS.push("lv:clear-flash", value: %{key: @kind}) |> hide("##{@id}")}
      >
        {msg}
      </.alert>
    </div>
    """
  end

  @doc """
  Renders a header with title.
  """
  slot :inner_block, required: true
  slot :subtitle
  slot :actions

  def header(assigns) do
    ~H"""
    <header class={[@actions != [] && "flex items-center justify-between gap-6", "pb-4"]}>
      <div>
        <h1 class="text-lg font-semibold leading-8">
          {render_slot(@inner_block)}
        </h1>
        <p :if={@subtitle != []} class="text-sm text-base-content/70">
          {render_slot(@subtitle)}
        </p>
      </div>
      <div class="flex-none">{render_slot(@actions)}</div>
    </header>
    """
  end

  @doc """
  Renders a data list.

  ## Examples

      <.list>
        <:item title="Title">{@post.title}</:item>
        <:item title="Views">{@post.views}</:item>
      </.list>
  """
  slot :item, required: true do
    attr :title, :string, required: true
  end

  def list(assigns) do
    ~H"""
    <ul class="list">
      <li :for={item <- @item} class="list-row">
        <div class="list-col-grow">
          <div class="font-bold">{item.title}</div>
          <div>{render_slot(item)}</div>
        </div>
      </li>
    </ul>
    """
  end

  @doc """
  Renders a [Heroicon](https://heroicons.com).

  Heroicons come in three styles – outline, solid, and mini.
  By default, the outline style is used, but solid and mini may
  be applied by using the `-solid` and `-mini` suffix.

  You can customize the size and colors of the icons by setting
  width, height, and background color classes.

  Icons are extracted from the `deps/heroicons` directory and bundled within
  your compiled app.css by the plugin in `assets/vendor/heroicons.js`.

  ## Examples

      <.icon name="hero-x-mark" />
      <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
  """
  attr :name, :string, required: true
  attr :class, :any, default: "size-4"

  def icon(%{name: "hero-" <> _} = assigns) do
    ~H"""
    <span class={[@name, @class]} />
    """
  end

  @doc """
  Renders a datetime in the user's local timezone.

  Accepts a `DateTime`, `NaiveDateTime`, or any struct with datetime fields.
  The `user` must have a `timezone` field. Falls back to UTC if the timezone
  is invalid.

  ## Formats

    * `:date` — medium date, e.g. "Feb 23, 2026" (default)
    * `:time` — short time, e.g. "5:00 PM"
    * `:datetime` — medium datetime, e.g. "Feb 23, 2026, 5:00 PM"

  ## Examples

      <.local_time value={@message.inserted_at} user={@current_user} />
      <.local_time value={@message.inserted_at} user={@current_user} format={:time} />
  """
  attr :value, :any, required: true
  attr :user, :any, required: true
  attr :format, :atom, default: :date, values: [:date, :time, :datetime]
  attr :class, :any, default: nil

  def local_time(assigns) do
    tz = (assigns.user && assigns.user.timezone) || "Etc/UTC"
    shifted = shift_to_zone(assigns.value, tz)

    formatted =
      case assigns.format do
        :date -> Autoforge.Cldr.Date.to_string!(shifted, format: :medium)
        :time -> Autoforge.Cldr.Time.to_string!(shifted, format: :short)
        :datetime -> Autoforge.Cldr.DateTime.to_string!(shifted, format: :medium)
      end

    assigns = assign(assigns, formatted: formatted, iso: DateTime.to_iso8601(shifted))

    ~H"""
    <time datetime={@iso} class={@class}>{@formatted}</time>
    """
  end

  defp shift_to_zone(%DateTime{} = dt, tz) do
    case DateTime.shift_zone(dt, tz) do
      {:ok, shifted} -> shifted
      _ -> dt
    end
  end

  defp shift_to_zone(%NaiveDateTime{} = ndt, tz) do
    ndt
    |> DateTime.from_naive!("Etc/UTC")
    |> shift_to_zone(tz)
  end

  defp shift_to_zone(other, _tz), do: other

  ## JS Commands

  def show(js \\ %JS{}, selector) do
    JS.show(js,
      to: selector,
      time: 300,
      transition:
        {"transition-all ease-out duration-300",
         "opacity-0 translate-y-4 sm:translate-y-0 sm:scale-95",
         "opacity-100 translate-y-0 sm:scale-100"}
    )
  end

  def hide(js \\ %JS{}, selector) do
    JS.hide(js,
      to: selector,
      time: 200,
      transition:
        {"transition-all ease-in duration-200", "opacity-100 translate-y-0 sm:scale-100",
         "opacity-0 translate-y-4 sm:translate-y-0 sm:scale-95"}
    )
  end

  @doc """
  Renders a search bar with a magnifying glass icon and debounced input.

  ## Examples

      <.search_bar query={@query} />
      <.search_bar query={@query} placeholder="Search bots..." />
  """
  attr :query, :string, default: ""
  attr :placeholder, :string, default: "Search..."

  def search_bar(assigns) do
    ~H"""
    <.form for={%{}} phx-change="search" phx-submit="search" class="w-full max-w-sm">
      <.input type="search" name="q" value={@query} placeholder={@placeholder} phx-debounce="300">
        <:inner_prefix>
          <.icon name="hero-magnifying-glass" class="w-4 h-4 text-base-content/40" />
        </:inner_prefix>
      </.input>
    </.form>
    """
  end

  @doc """
  Renders offset pagination controls showing "Showing X–Y of Z" with prev/next buttons.

  Expects an `%Ash.Page.Offset{}` struct as the `page` assign.

  ## Examples

      <.pagination page={@page} />
  """
  attr :page, :any, required: true

  def pagination(assigns) do
    assigns =
      assigns
      |> assign(:has_prev, AshPhoenix.LiveView.prev_page?(assigns.page))
      |> assign(:has_next, AshPhoenix.LiveView.next_page?(assigns.page))
      |> assign(:from, (assigns.page.offset || 0) + 1)
      |> assign(
        :to,
        min((assigns.page.offset || 0) + length(assigns.page.results), assigns.page.count || 0)
      )

    ~H"""
    <div :if={@page.count && @page.count > 0} class="flex items-center justify-between mt-6 text-sm">
      <span class="text-base-content/60">
        Showing {@from}–{@to} of {@page.count}
      </span>
      <div class="flex items-center gap-2">
        <.button
          size="sm"
          variant="soft"
          disabled={!@has_prev}
          phx-click="paginate"
          phx-value-direction="prev"
        >
          <.icon name="hero-chevron-left" class="w-4 h-4 mr-1" /> Prev
        </.button>
        <.button
          size="sm"
          variant="soft"
          disabled={!@has_next}
          phx-click="paginate"
          phx-value-direction="next"
        >
          Next <.icon name="hero-chevron-right" class="w-4 h-4 ml-1" />
        </.button>
      </div>
    </div>
    """
  end

  @doc """
  Renders a clickable table column header that toggles sort direction.

  Fires a `phx-click="sort"` event with the column name. Displays an icon
  indicating the current sort direction: up for ascending, down for descending,
  or a neutral up-down icon when unsorted.

  ## Examples

      <.sort_header column="name" sort={@sort}>Name</.sort_header>
      <.sort_header column="inserted_at" sort={@sort}>Created</.sort_header>
  """
  attr :column, :string, required: true
  attr :sort, :string, default: nil

  slot :inner_block, required: true

  def sort_header(assigns) do
    {icon_name, icon_class} =
      cond do
        assigns.sort == assigns.column ->
          {"hero-chevron-up", "w-3.5 h-3.5 text-primary"}

        assigns.sort == "-" <> assigns.column ->
          {"hero-chevron-down", "w-3.5 h-3.5 text-primary"}

        true ->
          {"hero-chevron-up-down",
           "w-3.5 h-3.5 text-base-content/30 group-hover:text-base-content/60"}
      end

    assigns = assign(assigns, icon_name: icon_name, icon_class: icon_class)

    ~H"""
    <button
      type="button"
      phx-click="sort"
      phx-value-column={@column}
      class="group inline-flex items-center gap-1 cursor-pointer select-none hover:text-base-content transition-colors"
    >
      {render_slot(@inner_block)}
      <.icon name={@icon_name} class={@icon_class} />
    </button>
    """
  end

  @doc """
  Computes the next sort value for a 3-state toggle cycle.

  - No active sort → ascending (`"column"`)
  - Ascending → descending (`"-column"`)
  - Descending → cleared (`nil`)
  - Different column → ascending on new column

  ## Examples

      iex> next_sort("name", nil)
      "name"
      iex> next_sort("name", "name")
      "-name"
      iex> next_sort("name", "-name")
      nil
      iex> next_sort("name", "email")
      "name"
  """
  def next_sort(column, current_sort) do
    cond do
      current_sort == column -> "-" <> column
      current_sort == "-" <> column -> nil
      true -> column
    end
  end

  @doc """
  Translates an error message using gettext.
  """
  def translate_error({msg, opts}) do
    # When using gettext, we typically pass the strings we want
    # to translate as a static argument:
    #
    #     # Translate the number of files with plural rules
    #     dngettext("errors", "1 file", "%{count} files", count)
    #
    # However the error messages in our forms and APIs are generated
    # dynamically, so we need to translate them by calling Gettext
    # with our gettext backend as first argument. Translations are
    # available in the errors.po file (as we use the "errors" domain).
    if count = opts[:count] do
      Gettext.dngettext(AutoforgeWeb.Gettext, "errors", msg, msg, count, opts)
    else
      Gettext.dgettext(AutoforgeWeb.Gettext, "errors", msg, opts)
    end
  end

  @doc """
  Translates the errors for a field from a keyword list of errors.
  """
  def translate_errors(errors, field) when is_list(errors) do
    for {^field, {msg, opts}} <- errors, do: translate_error({msg, opts})
  end
end
