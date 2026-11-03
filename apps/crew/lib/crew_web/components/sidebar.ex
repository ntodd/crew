defmodule CrewWeb.Components.Sidebar do
  @moduledoc """
  Sidebar navigation primitives, composed into the app shell by
  `CrewWeb.Layouts.app/1`.

  The pieces are intentionally generic: `sidebar/1` owns the frame
  (fixed rail on desktop, slide-over drawer on mobile), while
  `sidebar_group/1` and `sidebar_link/1` build the nav inside it.
  App-specific concerns — which links exist, who sees them — stay in
  the layout.
  """
  use Phoenix.Component
  use CrewWeb, :verified_routes

  import CrewWeb.CoreComponents, only: [avatar: 1, icon: 1, icon_button: 1]

  alias Phoenix.LiveView.JS

  @doc """
  The sidebar frame: a fixed 248px rail on the cool layer at `lg` and
  up, and a 272px slide-over drawer (with backdrop) below that.

  ## Examples

      <.sidebar id="app-sidebar">
        <:brand><a href="/">Crew</a></:brand>
        <.sidebar_group>
          <.sidebar_link navigate={~p"/"} icon="hero-home">Home</.sidebar_link>
        </.sidebar_group>
        <:footer>…user menu…</:footer>
      </.sidebar>

  Open it from a `sidebar_toggle/1` button; content alongside it needs
  `lg:pl-[248px]` (or `lg:mr-[248px]` for `side="right"`) to clear the
  rail.
  """
  attr :id, :string, required: true

  attr :side, :string,
    default: "left",
    values: ~w(left right),
    doc: "which edge the rail pins to; the mobile drawer slides in from the same edge"

  slot :brand, doc: "pinned to the top of the rail, next to the mobile close button"
  slot :footer, doc: "pinned below the nav, separated by a border"
  slot :inner_block, required: true, doc: "the nav content, typically sidebar_group/1s"

  def sidebar(assigns) do
    ~H"""
    <div
      id={"#{@id}-overlay"}
      class="fixed inset-0 z-30 hidden bg-zinc-900/40 backdrop-blur-[2px] lg:hidden"
      phx-click={hide_sidebar(%JS{}, @id, @side)}
      aria-hidden="true"
    />
    <aside
      id={@id}
      class={
        [
          "fixed inset-y-0 z-40 flex w-[272px] flex-col transition-transform duration-220 ease-out-expo lg:w-[248px] lg:translate-x-0",
          if(@side == "right",
            # Right rails are contextual panels: on desktop they tuck
            # under the app top bar (h-14) so the bar runs the full
            # width, and sit on the canvas beside the work they scope.
            # The mobile drawer still covers the full height.
            do: "right-0 translate-x-full border-l border-line bg-canvas lg:top-14",
            else: "left-0 -translate-x-full border-r border-line bg-subtle"
          )
        ]
      }
    >
      <div class={[
        "flex h-14 shrink-0 items-center justify-between gap-2 px-3",
        @side == "right" && "border-b border-line px-4 lg:hidden"
      ]}>
        {render_slot(@brand)}
        <.icon_button
          icon="hero-x-mark"
          label="Close sidebar"
          phx-click={hide_sidebar(%JS{}, @id, @side)}
          class="-mr-1 lg:hidden"
        />
      </div>

      <nav class={[
        "flex-1 overflow-y-auto",
        if(@side == "right", do: "px-4 py-5", else: "space-y-5 px-3 pb-4 pt-1")
      ]}>
        {render_slot(@inner_block)}
      </nav>

      <div :if={@footer != []} class="shrink-0 border-t border-line p-3">
        {render_slot(@footer)}
      </div>
    </aside>
    """
  end

  @doc """
  A group of nav links with an optional label, set in sentence case
  as written (no tracked capitals).
  """
  attr :label, :string, default: nil

  slot :inner_block, required: true, doc: "the links, typically sidebar_link/1s"

  def sidebar_group(assigns) do
    ~H"""
    <div>
      <p :if={@label} class="truncate px-2.5 pb-1 text-xs font-medium text-ink-3">
        {@label}
      </p>
      <ul class="space-y-0.5">
        {render_slot(@inner_block)}
      </ul>
    </div>
    """
  end

  @doc """
  A nav link with an optional icon and automatic active state.

  Pass either `navigate` (LiveView navigation) or `href` (full page
  load — required for mounted dashboards like Oban). The link is
  active when `current_path` equals its path or sits underneath it,
  so `/assets` stays lit on `/assets/42`.

  Pass `active` to override that match. An index at `/distributions`
  and a page at `/distributions/42/settings` are two different nav
  entries, and the prefix rule would otherwise light both at once.
  """
  attr :navigate, :string, default: nil
  attr :href, :string, default: nil
  attr :icon, :string, default: nil
  attr :current_path, :string, default: nil

  attr :active, :boolean,
    default: nil,
    doc: "overrides the current_path match; nil defers to it"

  attr :rest, :global, include: ~w(id)

  slot :inner_block, required: true

  def sidebar_link(assigns) do
    assigns =
      assign(
        assigns,
        :active,
        if(is_nil(assigns.active),
          do: active_path?(assigns.current_path, assigns.navigate || assigns.href),
          else: assigns.active
        )
      )

    ~H"""
    <li>
      <.link
        navigate={@navigate}
        href={@href}
        aria-current={@active && "page"}
        {@rest}
        class={[
          "flex h-8 items-center gap-2.5 rounded-lg px-2.5 text-sm transition-colors duration-150",
          if(@active,
            do: "bg-canvas font-medium text-ink shadow-xs ring-1 ring-line",
            else: "text-ink-2 hover:bg-muted hover:text-ink"
          )
        ]}
      >
        <.icon
          :if={@icon}
          name={@icon}
          class={["size-[18px] shrink-0", if(@active, do: "text-accent", else: "text-ink-3")]}
        />
        <span class="truncate">{render_slot(@inner_block)}</span>
      </.link>
    </li>
    """
  end

  defp active_path?(nil, _path), do: false
  defp active_path?(_current, nil), do: false
  defp active_path?(current, "/"), do: current == "/"

  defp active_path?(current, path),
    do: current == path or String.starts_with?(current, path <> "/")

  @doc """
  The signed-in user row for the sidebar footer: avatar, GitHub login,
  role, and a sign-out button.
  """
  attr :user, :map, required: true

  def sidebar_user(assigns) do
    ~H"""
    <div id="sidebar-user" class="flex items-center gap-2.5 p-1">
      <.avatar user={@user} class="size-7 text-[11px]" />
      <span class="min-w-0 flex-1">
        <span
          class="block truncate text-[13px] font-medium text-ink"
          title={@user.name || @user.login}
        >
          {@user.login}
        </span>
        <span class="block truncate text-xs text-ink-3">{role_label(@user.role)}</span>
      </span>
      <.icon_button
        icon="hero-arrow-right-start-on-rectangle"
        label="Sign out"
        href={~p"/sign-out"}
        method="delete"
        size="sm"
      />
    </div>
    """
  end

  defp role_label("admin"), do: "Admin"
  defp role_label(_role), do: "Member"

  @doc """
  A button that opens a sidebar drawer. Hidden on `lg` screens, where
  the rail is always visible.
  """
  attr :sidebar, :string, required: true, doc: "the DOM id of the sidebar/1 it opens"
  attr :icon, :string, default: "hero-bars-3"
  attr :label, :string, default: "Open sidebar"

  def sidebar_toggle(assigns) do
    ~H"""
    <.icon_button
      id={"#{@sidebar}-open"}
      icon={@icon}
      label={@label}
      phx-click={show_sidebar(@sidebar)}
      aria-controls={@sidebar}
      class="lg:hidden"
    />
    """
  end

  @doc """
  Slides the sidebar drawer in and fades in its backdrop. Removing
  both translate classes covers either side, so the opener doesn't
  need to know which edge the drawer lives on. The overlay shadow
  rides with the open state only; parked off-canvas, its blur would
  bleed a gray gradient onto the page edge.
  """
  def show_sidebar(js \\ %JS{}, id) do
    js
    |> JS.show(
      to: "##{id}-overlay",
      transition: {"transition-opacity duration-200 ease-out", "opacity-0", "opacity-100"}
    )
    |> JS.remove_class("-translate-x-full translate-x-full", to: "##{id}")
    |> JS.add_class("max-lg:shadow-overlay", to: "##{id}")
  end

  @doc """
  Slides the sidebar drawer out and fades out its backdrop.
  """
  def hide_sidebar(js \\ %JS{}, id, side \\ "left") do
    js
    |> JS.hide(
      to: "##{id}-overlay",
      transition: {"transition-opacity duration-150 ease-in", "opacity-100", "opacity-0"}
    )
    |> JS.add_class(
      if(side == "right", do: "translate-x-full", else: "-translate-x-full"),
      to: "##{id}"
    )
    |> JS.remove_class("max-lg:shadow-overlay", to: "##{id}")
  end
end
