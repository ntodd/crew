defmodule CrewWeb.CoreComponents do
  @moduledoc """
  Provides core UI components.

  At first glance, this module may seem daunting, but its goal is to provide
  core building blocks for your application, such as tables, forms, and
  inputs. The components consist mostly of markup and are well-documented
  with doc strings and declarative assigns. You may customize and style
  them in any way you want, based on your application growth and needs.

  The foundation for styling is Tailwind CSS over the role tokens in
  `assets/css/app.css` (canvas, subtle, muted, line, ink, accent, and
  the status colors). Components use those names rather than palette
  hues, so the dark theme flows through without per-component variants.
  Here are useful references:

    * [Tailwind CSS](https://tailwindcss.com) - the foundational framework
      we build on. You will use it for layout, sizing, flexbox, grid, and
      spacing.

    * [Heroicons](https://heroicons.com) - see `icon/1` for usage.

    * [Phoenix.Component](https://phoenix-live-view.hexdocs.pm/Phoenix.Component.html) -
      the component system used by Phoenix. Some components, such as `<.link>`
      and `<.form>`, are defined there.

  """
  use Phoenix.Component

  use Phoenix.VerifiedRoutes,
    endpoint: CrewWeb.Endpoint,
    router: CrewWeb.Router,
    statics: CrewWeb.static_paths()

  alias Phoenix.LiveView.JS

  @doc """
  Renders flash notices.

  ## Examples

      <.flash kind={:info} flash={@flash} />
      <.flash
        id="welcome-back"
        kind={:info}
        phx-mounted={show("#welcome-back") |> JS.remove_attribute("hidden")}
        hidden
      >
        Welcome Back!
      </.flash>
  """
  attr :id, :string, doc: "the optional id of flash container"
  attr :flash, :map, default: %{}, doc: "the map of flash messages to display"
  attr :title, :string, default: nil
  attr :kind, :atom, values: [:info, :error], doc: "used for styling and flash lookup"

  attr :autohide, :any,
    default: 6000,
    doc: "ms before it dismisses itself (paused while hovered); nil to stay until clicked"

  attr :rest, :global, doc: "the arbitrary HTML attributes to add to the flash container"

  slot :inner_block, doc: "the optional inner block that renders the flash message"

  def flash(assigns) do
    assigns = assign_new(assigns, :id, fn -> "flash-#{assigns.kind}" end)

    ~H"""
    <div
      :if={msg = render_slot(@inner_block) || Phoenix.Flash.get(@flash, @kind)}
      id={@id}
      phx-click={JS.push("lv:clear-flash", value: %{key: @kind}) |> hide("##{@id}")}
      phx-hook=".AutoHide"
      data-autohide={@autohide}
      role={if @kind == :error, do: "alert", else: "status"}
      class="pointer-events-auto flex w-full max-w-sm cursor-pointer items-start gap-3 rounded-xl border border-line bg-raised p-3.5 pr-3 text-sm shadow-overlay animate-fade-up"
      {@rest}
    >
      <span class={[
        "mt-0.5 grid size-5 shrink-0 place-items-center rounded-full",
        @kind == :info && "bg-success-soft text-success",
        @kind == :error && "bg-danger-soft text-danger"
      ]}>
        <.icon :if={@kind == :info} name="hero-check-micro" class="size-3.5" />
        <.icon :if={@kind == :error} name="hero-exclamation-triangle-micro" class="size-3.5" />
      </span>
      <div class="min-w-0 flex-1">
        <p :if={notice_title(msg, @title)} class="font-semibold text-ink">
          {notice_title(msg, @title)}
        </p>
        <p class="line-clamp-3 text-ink-2 [overflow-wrap:anywhere]">{notice_text(msg)}</p>
        <.link
          :if={notice_path(msg)}
          navigate={notice_path(msg)}
          class="mt-1 inline-block font-medium text-ink underline-offset-2 hover:underline"
        >
          Open
        </.link>
      </div>
      <button
        type="button"
        class="-m-1 rounded-md p-1 text-ink-3 transition-colors hover:text-ink"
        aria-label="close"
      >
        <.icon name="hero-x-mark-micro" class="size-4" />
      </button>
    </div>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".AutoHide">
      // Dismisses the notice the way a click does, after data-autohide ms
      // (none: it stays).
      // Hovering pauses it so a long message can be read; a new message in
      // the same notice starts the wait over.
      export default {
        mounted() {
          this.el.addEventListener("mouseenter", () => this.stop())
          this.el.addEventListener("mouseleave", () => this.start())
          this.start()
        },
        updated() { this.start() },
        destroyed() { this.stop() },
        start() {
          this.stop()
          if (!this.el.dataset.autohide || this.el.matches(":hover")) return
          this.timer = setTimeout(
            () => this.liveSocket.execJS(this.el, this.el.getAttribute("phx-click")),
            Number(this.el.dataset.autohide)
          )
        },
        stop() { clearTimeout(this.timer) }
      }
    </script>
    """
  end

  # A flash is a string, or a notice map from CrewWeb.ActivityNotice
  # with its own title and a link.
  defp notice_title(%{title: title}, _title), do: title
  defp notice_title(_msg, title), do: title
  defp notice_text(%{text: text}), do: text
  defp notice_text(msg), do: msg
  defp notice_path(%{path: path}), do: path
  defp notice_path(_msg), do: nil

  @doc """
  Renders a button with navigation support.

  Variants map to intent: `primary` is the page's one main action
  (org brand fill), `secondary` (the default) is everything else,
  `ghost` is a quiet in-row action, and the danger pair marks
  destructive actions. Sizes are the 32px (`sm`) and 36px (`md`)
  controls. Custom classes extend the variant, so width and alignment
  tweaks (`w-full`, `shrink-0`) compose without restating the style.

  ## Examples

      <.button phx-click="save" variant="primary">Save</.button>
      <.button icon="hero-arrow-up-tray" size="sm">Upload</.button>
      <.button navigate={~p"/"}>Home</.button>
      <.button variant="danger_outline" href={~p"/users/log-out"} method="delete">
        Sign out everywhere
      </.button>
  """
  attr :rest, :global,
    include: ~w(href navigate patch method download name value type disabled target rel)

  attr :variant, :string,
    default: "secondary",
    values: ~w(primary secondary ghost danger danger_outline)

  attr :size, :string, default: "md", values: ~w(sm md)
  attr :icon, :string, default: nil, doc: "a leading heroicon name"

  attr :wrap, :boolean,
    default: false,
    doc:
      "lets a label that names something (a title, an email) wrap onto more lines rather than run past a narrow screen"

  attr :class, :any, default: nil, doc: "extra classes appended to the variant classes"
  slot :inner_block, required: true

  def button(%{rest: rest} = assigns) do
    if rest[:href] || rest[:navigate] || rest[:patch] do
      ~H"""
      <.link class={[button_class(@variant, @size, @wrap), @class]} {@rest}>
        <.icon :if={@icon} name={@icon} class="size-4 shrink-0" />
        {render_slot(@inner_block)}
      </.link>
      """
    else
      ~H"""
      <button class={[button_class(@variant, @size, @wrap), @class]} {@rest}>
        <.icon :if={@icon} name={@icon} class="size-4 shrink-0" />
        {render_slot(@inner_block)}
      </button>
      """
    end
  end

  defp button_class(variant, size, wrap) do
    [
      "relative inline-flex select-none items-center justify-center gap-2 rounded-lg font-medium",
      # A wrapping label reads from the left, avoids a lone last word,
      # and breaks inside a long one (an email) when it has to.
      if(wrap, do: "max-w-full text-left text-pretty wrap-anywhere", else: "whitespace-nowrap"),
      "transition-[background-color,box-shadow,color,transform] duration-150 ease-(--ease-out-expo) active:translate-y-px",
      # A disabled button that looks enabled is a promise the page
      # can't keep; the pointer-events rule also stops the hover
      # treatment from firing on a control that will not respond.
      "disabled:pointer-events-none disabled:opacity-50 aria-disabled:pointer-events-none aria-disabled:opacity-50",
      "phx-submit-loading:opacity-80 phx-click-loading:opacity-80",
      button_size_class(size, wrap),
      button_variant_class(variant)
    ]
  end

  # One line is the same height either way; a wrapping label grows a
  # line at a time from there.
  defp button_size_class("sm", false), do: "h-8 px-3 text-[13px]"
  defp button_size_class("md", false), do: "h-9 px-3.5 text-sm"
  defp button_size_class("sm", true), do: "min-h-8 px-3 py-1.5 text-[13px]"
  defp button_size_class("md", true), do: "min-h-9 px-3.5 py-2 text-sm"

  defp button_variant_class("primary"),
    do: "bg-accent text-accent-fg shadow-control hover:bg-accent-hover"

  defp button_variant_class("secondary"),
    do: "border border-line-strong bg-canvas text-ink shadow-control hover:bg-subtle"

  defp button_variant_class("ghost"), do: "text-ink-2 hover:bg-muted hover:text-ink"

  defp button_variant_class("danger"),
    do: "bg-danger text-white shadow-control hover:brightness-95"

  defp button_variant_class("danger_outline"),
    do: "border border-line-strong bg-canvas text-danger shadow-control hover:bg-danger-soft"

  @doc """
  Renders a ghost icon-only button: ink-3 at rest, a well-gray wash
  on hover, and an accessible name via `label`. Renders a link when
  navigation attributes are present.

  ## Examples

      <.icon_button icon="hero-bell" label="Notifications" />
      <.icon_button
        icon="hero-arrow-right-start-on-rectangle"
        label="Log out"
        href={~p"/users/log-out"}
        method="delete"
      />
  """
  attr :icon, :string, required: true
  attr :label, :string, required: true, doc: "the accessible name; also the hover title"
  attr :size, :string, default: "md", values: ~w(sm md)
  attr :class, :any, default: nil, doc: "extra classes appended to the base classes"
  attr :rest, :global, include: ~w(href navigate patch method disabled target rel)

  def icon_button(%{rest: rest} = assigns) do
    if rest[:href] || rest[:navigate] || rest[:patch] do
      ~H"""
      <.link
        class={[icon_button_class(@size), @class]}
        aria-label={@label}
        title={@label}
        {@rest}
      >
        <.icon name={@icon} class={icon_button_icon_class(@size)} />
      </.link>
      """
    else
      ~H"""
      <button
        type="button"
        class={[icon_button_class(@size), @class]}
        aria-label={@label}
        title={@label}
        {@rest}
      >
        <.icon name={@icon} class={icon_button_icon_class(@size)} />
      </button>
      """
    end
  end

  defp icon_button_class(size) do
    [
      "inline-flex shrink-0 items-center justify-center rounded-lg text-ink-3 transition-colors duration-150",
      "hover:bg-muted hover:text-ink disabled:pointer-events-none disabled:opacity-50",
      if(size == "sm", do: "size-7", else: "size-9")
    ]
  end

  defp icon_button_icon_class("sm"), do: "size-4"
  defp icon_button_icon_class("md"), do: "size-[18px]"

  @doc """
  Renders a small status pill.

  Colors are the state vocabulary, not decoration: `zinc` is neutral,
  `emerald` done or visible, `running` work in flight (blue), `amber`
  in progress or partial, `rose` failed or destructive, and `brand` the
  org accent for the one emphasized label. `sky` is kept for
  compatibility and renders neutral. `soft` (the default)
  fills from the soft tint; `outline` is a hairline pill for drafts
  and not-yet states. `dot` leads the label with a status dot, and
  `pulse` breathes it while work is in flight.

  ## Examples

      <.badge>Viewer</.badge>
      <.badge color="emerald" dot>Ready</.badge>
      <.badge color="amber" dot pulse>Processing</.badge>
      <.badge color="brand">Super admin</.badge>
      <.badge size="sm" variant="outline">Yes/no</.badge>
  """
  attr :variant, :string, default: "soft", values: ~w(soft outline)
  attr :dot, :boolean, default: false, doc: "lead with a status dot"
  attr :pulse, :boolean, default: false, doc: "pulse the dot; for work still in flight"

  attr :color, :string,
    default: "zinc",
    values: ~w(zinc brand emerald running amber sky rose)

  attr :size, :string,
    default: "md",
    values: ~w(sm md),
    doc: "`sm` is the chip for narrow rails, where the default crowds the row it labels"

  attr :class, :any, default: nil, doc: "extra classes appended to the variant classes"
  attr :rest, :global
  slot :inner_block, required: true

  def badge(assigns) do
    ~H"""
    <span
      class={[
        "inline-flex shrink-0 items-center gap-1.5 whitespace-nowrap rounded-full font-medium",
        badge_size_class(@size),
        badge_class(@variant, @color),
        @class
      ]}
      {@rest}
    >
      <span
        :if={@dot}
        data-dot
        class={["size-1.5 shrink-0 rounded-full bg-current", @pulse && "animate-status-pulse"]}
        aria-hidden="true"
      />
      {render_slot(@inner_block)}
    </span>
    """
  end

  defp badge_size_class("sm"), do: "h-5 px-2 text-[11px]"
  defp badge_size_class("md"), do: "h-6 px-2.5 text-xs"

  defp badge_class("soft", "zinc"), do: "bg-muted text-ink-2"
  defp badge_class("soft", "sky"), do: "bg-muted text-ink-2"
  defp badge_class("soft", "brand"), do: "bg-accent-soft text-accent-ink"
  defp badge_class("soft", "emerald"), do: "bg-success-soft text-success"
  defp badge_class("soft", "running"), do: "bg-running/10 text-running-ink"
  defp badge_class("soft", "amber"), do: "bg-warning-soft text-warning"
  defp badge_class("soft", "rose"), do: "bg-danger-soft text-danger"

  defp badge_class("outline", "brand"),
    do: "border border-accent/40 text-accent-ink"

  defp badge_class("outline", "emerald"), do: "border border-success/35 text-success"
  defp badge_class("outline", "running"), do: "border border-running/35 text-running-ink"
  defp badge_class("outline", "amber"), do: "border border-warning/35 text-warning"
  defp badge_class("outline", "rose"), do: "border border-danger/35 text-danger"
  defp badge_class("outline", _neutral), do: "border border-line-strong text-ink-2"

  @doc """
  Renders a moment in the viewer's own time zone.

  The server renders UTC, so the text is right before JavaScript runs;
  the hook then reformats it in the browser's zone and locale, and
  again after every patch puts the UTC text back. `relative` reads as
  "5 min ago" for the past week, then as a date, keeps itself current
  while the page is open, and carries the full time as its title.

  ## Examples

      <.local_time id="video-publish-time" at={@video.publish_at} />
      <.local_time id="card-date" at={@at} format="date" />
      <.local_time id="entry-at" at={@entry.at} format="relative" />
  """
  attr :id, :string, required: true
  attr :at, DateTime, required: true
  attr :format, :string, default: "datetime", values: ~w(datetime date relative)
  attr :class, :any, default: nil

  def local_time(assigns) do
    ~H"""
    <time
      id={@id}
      datetime={DateTime.to_iso8601(@at)}
      data-format={@format}
      phx-hook=".LocalTime"
      class={@class}
    >
      {utc_text(@at, @format)}
    </time>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".LocalTime">
      const formats = {
        datetime: {
          month: "short", day: "numeric", year: "numeric",
          hour: "numeric", minute: "2-digit", timeZoneName: "short"
        },
        date: { month: "short", day: "numeric" }
      }

      const relative = new Intl.RelativeTimeFormat(undefined, { numeric: "auto", style: "short" })
      const steps = [[60, "second"], [60, "minute"], [24, "hour"], [7, "day"]]

      // "just now", "5 min ago", "yesterday"; past a week, a date.
      function sinceNow(at) {
        let amount = (at - Date.now()) / 1000
        if (Math.abs(amount) < 45) return relative.format(0, "second")

        for (const [size, unit] of steps) {
          if (Math.abs(amount) < size) return relative.format(Math.round(amount), unit)
          amount /= size
        }

        const date = at.getFullYear() === new Date().getFullYear()
          ? { month: "short", day: "numeric" }
          : { month: "short", day: "numeric", year: "numeric" }
        return new Intl.DateTimeFormat(undefined, date).format(at)
      }

      export default {
        mounted() {
          this.localize()
          if (this.el.dataset.format === "relative") {
            this.timer = setInterval(() => this.localize(), 30_000)
          }
        },
        updated() { this.localize() },
        destroyed() { clearInterval(this.timer) },
        localize() {
          const at = new Date(this.el.getAttribute("datetime"))
          if (isNaN(at)) return
          const format = this.el.dataset.format
          this.el.textContent = format === "relative"
            ? sinceNow(at)
            : new Intl.DateTimeFormat(undefined, formats[format] || formats.datetime).format(at)
          this.el.title = new Intl.DateTimeFormat(undefined, formats.datetime).format(at)
        }
      }
    </script>
    """
  end

  defp utc_text(at, "date"), do: Calendar.strftime(at, "%b %-d")
  defp utc_text(at, _datetime), do: Calendar.strftime(at, "%b %-d, %Y %H:%M UTC")

  @doc """
  Renders a secondary section navigation: a horizontal, scrollable
  pill row on small screens that becomes a sticky vertical rail on
  desktop. Pair with `subnav_link/1` children.

  ## Examples

      <.subnav id="asset-subnav" label="Asset sections">
        <.subnav_link patch={~p"/assets/1"} icon="hero-squares-2x2" active>
          Details
        </.subnav_link>
      </.subnav>
  """
  attr :id, :string, required: true
  attr :label, :string, default: "Sections"
  slot :inner_block, required: true

  def subnav(assigns) do
    ~H"""
    <nav
      id={@id}
      aria-label={@label}
      class="-mx-1 -my-1 flex gap-1 overflow-x-auto p-1 lg:sticky lg:top-20 lg:m-0 lg:flex-col lg:overflow-visible lg:p-0"
    >
      {render_slot(@inner_block)}
    </nav>
    """
  end

  @doc """
  A link inside `subnav/1`: leading icon, label, and an optional
  trailing count. The active item lifts onto a hairline-ringed
  surface in ink, icon included: section tabs never take the org
  accent, which stays on the sidebar's active icon, the primary
  action, focus, and selection. Announced via `aria-current`.
  """
  attr :icon, :string, required: true
  attr :count, :integer, default: nil
  attr :active, :boolean, default: false
  attr :rest, :global, include: ~w(id href navigate patch)
  slot :inner_block, required: true

  def subnav_link(assigns) do
    ~H"""
    <.link
      aria-current={@active && "page"}
      class={[
        "flex h-8 shrink-0 items-center gap-2.5 rounded-lg px-2.5 text-sm transition-colors duration-150",
        if(@active,
          do: "bg-subtle font-medium text-ink ring-1 ring-line",
          else: "text-ink-2 hover:bg-muted hover:text-ink"
        )
      ]}
      {@rest}
    >
      <.icon
        name={@icon}
        class={["size-4 shrink-0", if(@active, do: "text-ink", else: "text-ink-3")]}
      />
      <span class="truncate">{render_slot(@inner_block)}</span>
      <span :if={@count} class="ml-auto pl-2 text-xs tabular-nums text-ink-3">
        {@count}
      </span>
    </.link>
    """
  end

  @doc """
  Renders an empty state: a 48px icon well, an optional title, one or
  two sentences, and an optional action.

  ## Examples

      <.empty_state id="assets-empty" icon="hero-film">
        No assets yet — your first upload starts the catalog.
        <:action>
          <.button size="sm">Upload your first video</.button>
        </:action>
      </.empty_state>
  """
  attr :id, :string, default: nil
  attr :icon, :string, required: true
  attr :title, :string, default: nil
  attr :class, :any, default: nil, doc: "extra classes appended to the panel classes"
  slot :inner_block, required: true, doc: "the one-line explanation"
  slot :action

  def empty_state(assigns) do
    ~H"""
    <div
      id={@id}
      class={["flex flex-col items-center px-6 py-12 text-center", @class]}
    >
      <span class="grid size-12 place-items-center rounded-2xl bg-subtle text-ink-3 ring-1 ring-line">
        <.icon name={@icon} class="size-6" />
      </span>
      <p :if={@title} class="mt-4 text-[15px] font-semibold text-ink">{@title}</p>
      <p class={["max-w-sm text-sm text-ink-2", if(@title, do: "mt-1", else: "mt-4")]}>
        {render_slot(@inner_block)}
      </p>
      <div :if={@action != []} class="mt-5">{render_slot(@action)}</div>
    </div>
    """
  end

  @doc """
  Renders an input with label and error messages.

  A `Phoenix.HTML.FormField` may be passed as argument,
  which is used to retrieve the input name, id, and values.
  Otherwise all attributes may be passed explicitly.

  ## Types

  This function accepts all HTML input types, considering that:

    * You may also set `type="select"` to render a `<select>` tag

    * `type="checkbox"` is used exclusively to render boolean values

    * For live file uploads, see `Phoenix.Component.live_file_input/1`

  See https://developer.mozilla.org/en-US/docs/Web/HTML/Element/input
  for more information. Unsupported types, such as radio, are best
  written directly in your templates.

  ## Examples

  ```heex
  <.input field={@form[:email]} type="email" />
  <.input name="my-input" errors={["oh no!"]} />
  ```

  ## Select type

  When using `type="select"`, you must pass the `options` and optionally
  a `value` to mark which option should be preselected.

  ```heex
  <.input field={@form[:user_type]} type="select" options={["Admin": "admin", "User": "user"]} />
  ```

  For more information on what kind of data can be passed to `options` see
  [`options_for_select`](https://phoenix-html.hexdocs.pm/Phoenix.HTML.Form.html#options_for_select/2).
  """
  attr :id, :any, default: nil
  attr :name, :any
  attr :label, :string, default: nil
  attr :value, :any

  attr :type, :string,
    default: "text",
    values: ~w(checkbox color date datetime-local email file month number password
               search select tel text textarea time url week hidden)

  attr :field, Phoenix.HTML.FormField,
    doc: "a form field struct retrieved from the form, for example: @form[:email]"

  attr :errors, :list, default: []
  attr :checked, :boolean, doc: "the checked flag for checkbox inputs"
  attr :prompt, :string, default: nil, doc: "the prompt for select inputs"
  attr :options, :list, doc: "the options to pass to Phoenix.HTML.Form.options_for_select/2"
  attr :multiple, :boolean, default: false, doc: "the multiple flag for select inputs"
  attr :class, :any, default: nil, doc: "the input class to use over defaults"
  attr :error_class, :any, default: nil, doc: "the input error class to use over defaults"

  attr :rest, :global,
    include: ~w(accept autocomplete capture cols disabled form list max maxlength min minlength
                multiple pattern placeholder readonly required rows size step)

  def input(%{field: %Phoenix.HTML.FormField{} = field} = assigns) do
    errors = if Phoenix.Component.used_input?(field), do: field.errors, else: []

    assigns
    |> assign(field: nil, id: assigns.id || field.id)
    |> assign(:errors, Enum.map(errors, &translate_error(&1)))
    |> assign_new(:name, fn -> if assigns.multiple, do: field.name <> "[]", else: field.name end)
    |> assign_new(:value, fn -> field.value end)
    |> input()
  end

  # A label needs an id to point at: without one, the field's name serves.
  def input(%{id: nil, name: name} = assigns) when is_binary(name) and name != "" do
    assigns
    |> assign(:id, name |> String.replace(~r/[^A-Za-z0-9_-]/, "_") |> String.trim("_"))
    |> input()
  end

  def input(%{type: "hidden"} = assigns) do
    ~H"""
    <input type="hidden" id={@id} name={@name} value={@value} {@rest} />
    """
  end

  def input(%{type: "checkbox"} = assigns) do
    assigns =
      assign_new(assigns, :checked, fn ->
        Phoenix.HTML.Form.normalize_value("checkbox", assigns[:value])
      end)

    ~H"""
    <div class="mb-3">
      <label for={@id} class="flex cursor-pointer items-center gap-2.5 text-sm text-ink">
        <input
          type="hidden"
          name={@name}
          value="false"
          disabled={@rest[:disabled]}
          form={@rest[:form]}
        />
        <input
          type="checkbox"
          id={@id}
          name={@name}
          value="true"
          checked={@checked}
          aria-invalid={@errors != [] && "true"}
          class={@class || "checkbox"}
          {@rest}
        />
        <span :if={@label} class="font-medium">{@label}</span>
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  def input(%{type: "select"} = assigns) do
    ~H"""
    <div class="mb-3">
      <label :if={@label} for={@id} class="label">{@label}</label>
      <div class="relative">
        <select
          id={@id}
          name={@name}
          class={[@class || "input", @errors != [] && @error_class]}
          multiple={@multiple}
          aria-invalid={@errors != [] && "true"}
          {@rest}
        >
          <option :if={@prompt} value="">{@prompt}</option>
          {Phoenix.HTML.Form.options_for_select(@options, @value)}
        </select>
        <.icon
          :if={!@multiple}
          name="hero-chevron-up-down-micro"
          class="pointer-events-none absolute right-2.5 top-1/2 size-4 -translate-y-1/2 text-ink-3"
        />
      </div>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  def input(%{type: "textarea"} = assigns) do
    ~H"""
    <div class="mb-3">
      <label :if={@label} for={@id} class="label">{@label}</label>
      <textarea
        id={@id}
        name={@name}
        class={[@class || "input", @errors != [] && @error_class]}
        aria-invalid={@errors != [] && "true"}
        {@rest}
      >{Phoenix.HTML.Form.normalize_value("textarea", @value)}</textarea>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  # All other inputs text, datetime-local, url, password, etc. are handled here...
  def input(assigns) do
    ~H"""
    <div class="mb-3">
      <label :if={@label} for={@id} class="label">{@label}</label>
      <input
        type={@type}
        name={@name}
        id={@id}
        value={Phoenix.HTML.Form.normalize_value(@type, @value)}
        class={[@class || "input", @errors != [] && @error_class]}
        aria-invalid={@errors != [] && "true"}
        {@rest}
      />
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  @doc """
  Renders one form error message.

  `input/1` calls this for its own field errors. It is public because
  some errors have no input to hang off: an `{:array, :string}` field
  edited as a list of rows collects its errors on the field itself
  ("must not contain duplicate options"), and those still have to
  reach the page in the same voice as every other error.

  ## Examples

      <.error :for={msg <- Enum.map(@form[:options].errors, &translate_error/1)}>
        {msg}
      </.error>
  """
  attr :rest, :global
  slot :inner_block, required: true

  def error(assigns) do
    ~H"""
    <p class="mt-1.5 flex items-center gap-1.5 text-[13px] font-medium text-danger" {@rest}>
      <.icon name="hero-exclamation-circle-micro" class="size-4 shrink-0" />
      {render_slot(@inner_block)}
    </p>
    """
  end

  @doc """
  Renders one row of a definition list: a quiet term and its value.

  Built for read-only fact panels — media metadata, the record ids and
  timestamps on a settings page. Wrap a group of these in a `<dl>`.

  ## Examples

      <dl class="space-y-3">
        <.fact term="Added">{format_date(@asset.inserted_at)}</.fact>
      </dl>
  """
  attr :term, :string, required: true
  slot :inner_block, required: true

  def fact(assigns) do
    ~H"""
    <div class="flex items-center justify-between gap-4 text-sm">
      <dt class="shrink-0 text-ink-2">{@term}</dt>
      <dd class="flex min-w-0 items-center font-medium text-ink tabular-nums">
        {render_slot(@inner_block)}
      </dd>
    </div>
    """
  end

  @doc """
  Renders a page header: title, optional subtitle, and the page's
  actions on the right.
  """
  attr :class, :any, default: nil
  slot :inner_block, required: true
  slot :subtitle
  slot :actions

  def header(assigns) do
    ~H"""
    <header class={["flex flex-wrap items-end justify-between gap-x-6 gap-y-3 pb-4", @class]}>
      <div class="min-w-0">
        <h1 class="text-2xl/8 font-semibold tracking-[-0.02em] text-ink">
          {render_slot(@inner_block)}
        </h1>
        <p :if={@subtitle != []} class="mt-1 text-sm text-ink-2">
          {render_slot(@subtitle)}
        </p>
      </div>
      <div :if={@actions != []} class="flex flex-wrap items-center gap-2">
        {render_slot(@actions)}
      </div>
    </header>
    """
  end

  @doc """
  Renders a table with generic styling.

  ## Examples

      <.table id="users" rows={@users}>
        <:col :let={user} label="id">{user.id}</:col>
        <:col :let={user} label="username">{user.username}</:col>
      </.table>
  """
  attr :id, :string, required: true
  attr :rows, :list, required: true
  attr :row_id, :any, default: nil, doc: "the function for generating the row id"
  attr :row_click, :any, default: nil, doc: "the function for handling phx-click on each row"

  attr :row_item, :any,
    default: &Function.identity/1,
    doc: "the function for mapping each row before calling the :col and :action slots"

  slot :col, required: true do
    attr :label, :string
    attr :class, :any, doc: "extra classes for the column's header and cells"
    attr :align, :string, values: ~w(left right), doc: "right-aligns counts and other numbers"
  end

  slot :action, doc: "the slot for showing user actions in the last table column"

  def table(assigns) do
    assigns =
      with %{rows: %Phoenix.LiveView.LiveStream{}} <- assigns do
        assign(assigns, row_id: assigns.row_id || fn {id, _item} -> id end)
      end

    # Clickable rows wash the whole row on hover, so their cells pad
    # both outer edges and the table pulls out by the same amount: the
    # wash runs past the content while the content still lines up with
    # the page.
    ~H"""
    <div class={["overflow-x-auto", @row_click && "-mx-3"]}>
      <table class="w-full border-separate border-spacing-0 text-sm">
        <thead>
          <tr>
            <th
              :for={col <- @col}
              class={[
                "border-b border-line px-3 py-2 text-xs font-medium text-ink-2",
                !@row_click && "first:pl-0",
                if(col[:align] == "right", do: "text-right", else: "text-left"),
                col[:class]
              ]}
            >
              {col[:label]}
            </th>
            <th :if={@action != []} class={["border-b border-line py-2 pl-3", @row_click && "pr-3"]}>
              <span class="sr-only">{"Actions"}</span>
            </th>
          </tr>
        </thead>
        <tbody id={@id} phx-update={is_struct(@rows, Phoenix.LiveView.LiveStream) && "stream"}>
          <tr :for={row <- @rows} id={@row_id && @row_id.(row)} class="group">
            <td
              :for={col <- @col}
              phx-click={@row_click && @row_click.(row)}
              class={[
                "border-b border-line px-3 py-3 align-middle text-ink transition-colors",
                if(@row_click, do: "cursor-pointer group-hover:bg-subtle", else: "first:pl-0"),
                col[:align] == "right" && "text-right",
                col[:class]
              ]}
            >
              {render_slot(col, @row_item.(row))}
            </td>
            <td
              :if={@action != []}
              class={[
                "w-0 border-b border-line py-3 pl-3 text-right transition-colors",
                @row_click && "pr-3 group-hover:bg-subtle"
              ]}
            >
              <div class="flex items-center justify-end gap-1">
                <%= for action <- @action do %>
                  {render_slot(action, @row_item.(row))}
                <% end %>
              </div>
            </td>
          </tr>
        </tbody>
      </table>
    </div>
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
    <dl class="divide-y divide-line text-sm">
      <div :for={item <- @item} class="flex items-baseline justify-between gap-4 py-2.5">
        <dt class="text-ink-2">{item.title}</dt>
        <dd class="text-right font-medium text-ink tabular-nums">{render_slot(item)}</dd>
      </div>
    </dl>
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
  Renders a user's avatar: the profile photo stored at SSO login, an
  external avatar URL as a fallback, or the first letter of their
  email.

  ## Examples

      <.avatar user={@current_scope.user} />
      <.avatar user={user} class="size-8 text-sm" />
  """
  attr :user, Crew.Accounts.User, required: true
  attr :class, :string, default: "size-10"

  def avatar(%{user: %{avatar_url: url}} = assigns) when is_binary(url) do
    ~H"""
    <img src={@user.avatar_url} class={[@class, "shrink-0 rounded-full object-cover"]} alt="" />
    """
  end

  def avatar(assigns) do
    ~H"""
    <div class={[
      @class,
      "flex shrink-0 select-none items-center justify-center rounded-full bg-muted font-semibold text-ink-2"
    ]}>
      {@user.login |> String.first() |> String.upcase()}
    </div>
    """
  end

  @doc """
  Renders a modal dialog.

  Open it from anywhere with `show_modal/2`; it closes on escape,
  click-away, or its close button.

  ## Examples

      <.modal id="upload-modal">
        <h2 id="upload-modal-title">Upload videos</h2>
        ...
      </.modal>

      <.button phx-click={show_modal("upload-modal")}>Upload</.button>

  An element with id `"\#{id}-title"` inside the modal labels the
  dialog for assistive technology.
  """
  attr :id, :string, required: true
  attr :show, :boolean, default: false, doc: "opens the modal on mount"

  attr :on_cancel, JS,
    default: %JS{},
    doc: "extra JS commands to run when the modal is dismissed"

  slot :inner_block, required: true

  def modal(assigns) do
    ~H"""
    <div
      id={@id}
      phx-mounted={@show && show_modal(@id)}
      phx-remove={hide_modal(@id)}
      data-cancel={JS.exec(@on_cancel, "phx-remove")}
      class="relative z-50 hidden"
    >
      <div
        id={"#{@id}-bg"}
        class="fixed inset-0 bg-zinc-900/40 backdrop-blur-[2px]"
        aria-hidden="true"
      />
      <div
        class="fixed inset-0 overflow-y-auto"
        aria-labelledby={"#{@id}-title"}
        role="dialog"
        aria-modal="true"
        tabindex="0"
      >
        <div class="flex min-h-full items-center justify-center p-4 sm:p-6">
          <.focus_wrap
            id={"#{@id}-container"}
            phx-window-keydown={JS.exec("data-cancel", to: "##{@id}")}
            phx-key="escape"
            phx-click-away={JS.exec("data-cancel", to: "##{@id}")}
            class="relative hidden w-full max-w-lg rounded-2xl bg-raised p-6 shadow-overlay ring-1 ring-line"
          >
            <.icon_button
              icon="hero-x-mark"
              label="close"
              phx-click={JS.exec("data-cancel", to: "##{@id}")}
              class="absolute right-3 top-3"
            />
            <div id={"#{@id}-content"}>
              {render_slot(@inner_block)}
            </div>
          </.focus_wrap>
        </div>
      </div>
    </div>
    """
  end

  @doc """
  A button that opens a menu of `dropdown_item`s below it. The menu
  closes on a click outside it or Escape; an item closes it with
  `hide_dropdown/2`.

  ## Examples

      <.dropdown id="env-actions" label="Actions">
        <.dropdown_item title="Rebuild" phx-click={JS.push("rebuild") |> hide_dropdown("env-actions")}>
          Recreates the containers.
        </.dropdown_item>
      </.dropdown>
  """
  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :icon, :string, default: nil
  attr :size, :string, default: "sm", values: ~w(sm md)
  slot :inner_block, required: true

  def dropdown(assigns) do
    ~H"""
    <div
      id={@id}
      class="relative"
      phx-click-away={hide_dropdown(@id)}
      phx-window-keydown={hide_dropdown(@id)}
      phx-key="Escape"
    >
      <.button
        type="button"
        id={"#{@id}-trigger"}
        size={@size}
        icon={@icon}
        aria-haspopup="menu"
        aria-expanded="false"
        aria-controls={"#{@id}-menu"}
        phx-click={toggle_dropdown(@id)}
      >
        {@label}
        <.icon name="hero-chevron-down-mini" class="-mr-1 size-4 text-ink-3" />
      </.button>
      <div
        id={"#{@id}-menu"}
        role="menu"
        aria-labelledby={"#{@id}-trigger"}
        class="absolute right-0 top-full z-30 mt-1.5 hidden w-80 max-w-[calc(100vw-2rem)] origin-top-right rounded-xl border border-line bg-raised p-1.5 shadow-overlay"
      >
        {render_slot(@inner_block)}
      </div>
    </div>
    """
  end

  @doc """
  An entry in a `dropdown`: a title, what it does underneath, and an
  optional `note` about how things stand now.
  """
  attr :title, :string, required: true
  attr :icon, :string, default: nil
  attr :variant, :string, default: nil, values: [nil, "danger"]
  attr :rest, :global, include: ~w(disabled name value)
  slot :inner_block, required: true
  slot :note

  def dropdown_item(assigns) do
    ~H"""
    <button
      type="button"
      role="menuitem"
      class="group flex w-full items-start gap-3 rounded-lg px-2.5 py-2 text-left transition-colors duration-150 hover:bg-subtle focus-visible:bg-subtle focus-visible:outline-none disabled:cursor-not-allowed disabled:hover:bg-transparent"
      {@rest}
    >
      <span
        :if={@icon}
        class={[
          "mt-0.5 grid size-7 shrink-0 place-items-center rounded-md border border-line bg-canvas shadow-xs transition-colors group-disabled:text-ink-3",
          if(@variant == "danger", do: "text-danger", else: "text-ink-2 group-hover:text-ink")
        ]}
      >
        <.icon name={@icon} class="size-4" />
      </span>
      <span class="min-w-0">
        <span class={[
          "block text-sm font-medium group-disabled:text-ink-3",
          if(@variant == "danger", do: "text-danger", else: "text-ink")
        ]}>{@title}</span>
        <span class="mt-0.5 block text-xs leading-relaxed text-ink-3">{render_slot(@inner_block)}</span>
        <span :for={note <- @note} class="mt-1.5 block text-xs font-medium">{render_slot(note)}</span>
      </span>
    </button>
    """
  end

  @doc "A rule between groups of `dropdown_item`s."
  def dropdown_separator(assigns) do
    ~H"""
    <div role="separator" class="mx-1 my-1.5 border-t border-line"></div>
    """
  end

  @doc "Opens or closes a `dropdown`'s menu."
  def toggle_dropdown(js \\ %JS{}, id) do
    js
    |> JS.toggle(
      to: "##{id}-menu",
      time: 150,
      in:
        {"transition-[opacity,transform] ease-(--ease-out-expo) duration-150",
         "opacity-0 -translate-y-1 scale-[0.98]", "opacity-100 translate-y-0 scale-100"},
      out:
        {"transition-[opacity,transform] ease-in duration-100",
         "opacity-100 translate-y-0 scale-100", "opacity-0 -translate-y-1 scale-[0.98]"}
    )
    |> JS.toggle_attribute({"aria-expanded", "true", "false"}, to: "##{id}-trigger")
  end

  @doc "Closes a `dropdown`'s menu."
  def hide_dropdown(js \\ %JS{}, id) do
    js
    |> JS.hide(
      to: "##{id}-menu",
      time: 100,
      transition:
        {"transition-[opacity,transform] ease-in duration-100",
         "opacity-100 translate-y-0 scale-100", "opacity-0 -translate-y-1 scale-[0.98]"}
    )
    |> JS.set_attribute({"aria-expanded", "false"}, to: "##{id}-trigger")
  end

  @doc """
  Opens the modal with the given id.
  """
  def show_modal(js \\ %JS{}, id) when is_binary(id) do
    js
    |> JS.show(to: "##{id}")
    |> JS.show(
      to: "##{id}-bg",
      time: 200,
      transition: {"transition-opacity ease-out duration-200", "opacity-0", "opacity-100"}
    )
    |> show("##{id}-container")
    |> JS.add_class("overflow-hidden", to: "body")
    |> JS.focus_first(to: "##{id}-content")
  end

  @doc """
  Closes the modal with the given id.
  """
  def hide_modal(js \\ %JS{}, id) do
    js
    |> JS.hide(
      to: "##{id}-bg",
      transition: {"transition-opacity ease-in duration-200", "opacity-100", "opacity-0"}
    )
    |> hide("##{id}-container")
    |> JS.hide(to: "##{id}", transition: {"block", "block", "block"})
    |> JS.remove_class("overflow-hidden", to: "body")
    |> JS.pop_focus()
  end

  ## JS Commands

  def show(js \\ %JS{}, selector, display \\ "block") do
    JS.show(js,
      to: selector,
      display: display,
      time: 220,
      transition:
        {"transition-all ease-(--ease-out-expo) duration-220",
         "opacity-0 translate-y-2 sm:translate-y-0 sm:scale-[0.98]",
         "opacity-100 translate-y-0 sm:scale-100"}
    )
  end

  def hide(js \\ %JS{}, selector) do
    JS.hide(js,
      to: selector,
      time: 150,
      transition:
        {"transition-all ease-in duration-150", "opacity-100 translate-y-0 sm:scale-100",
         "opacity-0 translate-y-2 sm:translate-y-0 sm:scale-[0.98]"}
    )
  end

  @doc "Interpolates an Ecto error message."
  def translate_error({msg, opts}) do
    Enum.reduce(opts, msg, fn {key, value}, acc ->
      String.replace(acc, "%{#{key}}", fn _ -> to_string(value) end)
    end)
  end

  @doc """
  Translates the errors for a field from a keyword list of errors.
  """
  def translate_errors(errors, field) when is_list(errors) do
    for {^field, {msg, opts}} <- errors, do: translate_error({msg, opts})
  end
end
