defmodule CrewWeb.Layouts do
  @moduledoc """
  The app shell: a sidebar of sections on the left, a top bar with the
  page's breadcrumb and actions, and the page content. Signed-out pages
  (sign in, setup) get a centered single-column frame instead.
  """
  use CrewWeb, :html

  import CrewWeb.Components.Sidebar

  embed_templates "layouts/*"

  attr :flash, :map, required: true
  attr :current_scope, :map, default: nil
  attr :current_path, :string, default: nil

  attr :width, :string,
    default: "wide",
    values: ~w(narrow wide full),
    doc: "content width; full suits logs and tables"

  slot :breadcrumb do
    attr :navigate, :string
  end

  slot :actions
  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <%= if signed_in?(@current_scope) do %>
      <.sidebar id="app-sidebar">
        <:brand>
          <.link
            navigate={~p"/"}
            class="flex min-w-0 flex-1 items-center gap-2.5 rounded-lg p-1.5 transition-colors hover:bg-muted"
          >
            <.mark />
            <span class="truncate text-sm font-semibold text-ink">Crew</span>
          </.link>
        </:brand>

        <.sidebar_group>
          <.sidebar_link navigate={~p"/"} icon="hero-squares-2x2" active={@current_path == "/"}>
            Dashboard
          </.sidebar_link>
          <.sidebar_link navigate={~p"/runs"} icon="hero-play-circle" current_path={@current_path}>
            Runs
          </.sidebar_link>
          <.sidebar_link navigate={~p"/repos"} icon="hero-code-bracket" current_path={@current_path}>
            Repos
          </.sidebar_link>
        </.sidebar_group>

        <.sidebar_group :if={Crew.Scope.admin?(@current_scope)} label="Admin">
          <.sidebar_link
            navigate={~p"/admin"}
            icon="hero-shield-check"
            active={@current_path == "/admin"}
          >
            Deployment
          </.sidebar_link>
          <.sidebar_link navigate={~p"/admin/users"} icon="hero-users" current_path={@current_path}>
            People
          </.sidebar_link>
          <.sidebar_link
            navigate={~p"/admin/audit"}
            icon="hero-document-text"
            current_path={@current_path}
          >
            Audit log
          </.sidebar_link>
          <.sidebar_link href={~p"/admin/oban"} icon="hero-queue-list" current_path={@current_path}>
            Jobs
          </.sidebar_link>
        </.sidebar_group>

        <:footer>
          <div class="space-y-3">
            <div class="flex items-center justify-between gap-2 px-1 sm:hidden">
              <span class="text-xs font-medium text-ink-3">Theme</span>
              <.theme_toggle id="sidebar-theme-toggle" />
            </div>
            <.sidebar_user user={@current_scope.user} />
          </div>
        </:footer>
      </.sidebar>

      <div class="flex min-h-svh flex-col lg:pl-[248px]">
        <header
          id="app-topbar"
          class="sticky top-0 z-20 flex h-14 shrink-0 items-center gap-2 border-b border-line bg-canvas/85 px-4 backdrop-blur-md sm:px-6 lg:px-8"
        >
          <div class="-ml-1.5 lg:hidden">
            <.sidebar_toggle sidebar="app-sidebar" />
          </div>

          <nav id="topbar-breadcrumb" aria-label="Breadcrumb" class="flex min-w-0 items-center gap-2">
            <%= for {crumb, index} <- Enum.with_index(@breadcrumb) do %>
              <span :if={index > 0} aria-hidden="true" class="shrink-0 text-sm text-line-strong">/</span>
              <%= if crumb[:navigate] do %>
                <.link
                  navigate={crumb[:navigate]}
                  class={[crumb_class(index), "rounded-md transition-colors hover:text-ink"]}
                >
                  {render_slot(crumb)}
                </.link>
              <% else %>
                <span class={crumb_class(index)}>{render_slot(crumb)}</span>
              <% end %>
            <% end %>
          </nav>

          <div class="ml-auto flex shrink-0 items-center gap-1">
            <div :if={@actions != []} class="mr-2 flex items-center gap-2">
              {render_slot(@actions)}
            </div>
            <div class="ml-2 hidden sm:block">
              <.theme_toggle id="topbar-theme-toggle" />
            </div>
          </div>
        </header>

        <div
          :if={@current_scope.user.github_login_expired}
          id="github-expired-banner"
          class="flex items-center gap-3 border-b border-line bg-warning-soft px-4 py-2.5 text-sm text-warning sm:px-6 lg:px-8"
        >
          <.icon name="hero-exclamation-triangle-mini" class="size-4 shrink-0" />
          <span class="flex-1">
            Your GitHub login expired. Sign in again to keep seeing your repos' runs and logs.
          </span>
          <.link href={~p"/auth/github"} class="font-medium underline">Sign in again</.link>
        </div>

        <main class="flex-1 px-4 py-6 sm:px-6 sm:py-8 lg:px-8">
          <div class={[
            "space-y-6",
            @width == "narrow" && "mx-auto max-w-2xl",
            @width == "wide" && "mx-auto max-w-5xl",
            @width == "full" && "w-full"
          ]}>
            {render_slot(@inner_block)}
          </div>
        </main>
      </div>
    <% else %>
      <div class="flex min-h-svh flex-col bg-subtle">
        <header class="flex items-center justify-between px-4 py-4 sm:px-6">
          <a
            href="/"
            class="flex items-center gap-2.5 rounded-lg p-1.5 transition-colors hover:bg-muted"
          >
            <.mark />
            <span class="text-sm font-semibold text-ink">Crew</span>
          </a>
          <.theme_toggle />
        </header>

        <main class="flex flex-1 justify-center px-4 pb-16 pt-6 sm:pt-14">
          <div class={["w-full space-y-4", if(@width == "wide", do: "max-w-2xl", else: "max-w-md")]}>
            {render_slot(@inner_block)}
          </div>
        </main>
      </div>
    <% end %>

    <.flash_group flash={@flash} />
    """
  end

  defp signed_in?(%Crew.Scope{user: %{}}), do: true
  defp signed_in?(_scope), do: false

  defp crumb_class(0), do: "truncate text-sm font-medium text-ink"
  defp crumb_class(_index), do: "truncate text-sm text-ink-2"

  @doc "Crew's mark."
  attr :size, :string, default: "md", values: ~w(md lg)

  def mark(assigns) do
    ~H"""
    <span
      class={[
        "grid shrink-0 place-items-center bg-accent font-semibold text-accent-fg",
        @size == "md" && "size-7 rounded-[7px] text-[13px]",
        @size == "lg" && "size-12 rounded-2xl text-xl"
      ]}
      aria-hidden="true"
    >
      C
    </span>
    """
  end

  attr :flash, :map, required: true
  attr :id, :string, default: "flash-group"

  def flash_group(assigns) do
    ~H"""
    <div
      id={@id}
      aria-live="polite"
      class="pointer-events-none fixed inset-x-0 bottom-0 z-[60] flex flex-col items-center gap-2 p-4 sm:bottom-auto sm:left-auto sm:right-0 sm:top-0 sm:items-end"
    >
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        autohide={nil}
        title="Lost the connection"
        phx-disconnected={
          show(%JS{}, ".phx-client-error #client-error", "flex")
          |> JS.remove_attribute("hidden", to: ".phx-client-error #client-error")
        }
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        Reconnecting <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        autohide={nil}
        title="Something went wrong"
        phx-disconnected={
          show(%JS{}, ".phx-server-error #server-error", "flex")
          |> JS.remove_attribute("hidden", to: ".phx-server-error #server-error")
        }
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        Reconnecting <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end

  attr :id, :string, default: nil

  def theme_toggle(assigns) do
    ~H"""
    <div
      id={@id}
      role="group"
      aria-label="Theme"
      class="relative flex w-[88px] items-center rounded-lg bg-muted p-0.5"
    >
      <div
        class="absolute inset-y-0.5 left-0.5 w-7 rounded-md bg-canvas shadow-raised transition-transform duration-220 ease-out-expo [[data-theme=light]_&]:translate-x-7 [[data-theme=dark]_&]:translate-x-14 [[data-theme-source=system]_&]:translate-x-0!"
        aria-hidden="true"
      />
      <button
        :for={
          {theme, icon, label} <- [
            {"system", "hero-computer-desktop-micro", "Match system"},
            {"light", "hero-sun-micro", "Light"},
            {"dark", "hero-moon-micro", "Dark"}
          ]
        }
        type="button"
        class="relative grid h-7 w-7 cursor-pointer place-items-center rounded-md text-ink-3 transition-colors hover:text-ink"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme={theme}
        aria-label={label}
        title={label}
      >
        <.icon name={icon} class="size-4" />
      </button>
    </div>
    """
  end
end
