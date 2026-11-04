defmodule CrewWeb.AdminLive.Images do
  @moduledoc """
  The Images page (§17.3): each arch's default or pinned guest image with
  its runner, Docker and kernel versions; the runner freshness warning
  (§13.1); where each box is with the default (§20.4); and pin and unpin,
  which is also how to roll back. Admins only; pins are audited.
  """
  use CrewWeb, :live_view

  alias Crew.{Boxes, Images}
  alias Crew.Images.Runner

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Images.subscribe()
    {:ok, socket |> assign(:page_title, "Images") |> load()}
  end

  defp load(socket) do
    images = Images.list()
    defaults = Images.defaults()
    boxes = Boxes.list()
    states = Map.new(Images.box_images_all(), &{{&1.box_id, &1.image_id}, &1})
    releases = Runner.releases()

    arches =
      for arch <- ["arm64", "x64"],
          arch_images = Enum.filter(images, &(&1.arch == arch)),
          arch_boxes = Enum.filter(boxes, &(&1.guest_arch == arch)),
          arch_images != [] or arch_boxes != [] do
        default = Enum.find(arch_images, &(&1.id == defaults[arch].default))

        %{
          arch: arch,
          images: arch_images,
          default: default,
          boxes: arch_boxes,
          freshness: default && Runner.freshness(default.runner_version, releases)
        }
      end

    assign(socket, arches: arches, states: states)
  end

  @impl true
  def handle_info(:images_changed, socket), do: {:noreply, load(socket)}
  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def handle_event(action, %{"id" => id}, socket) when action in ["pin", "unpin"] do
    scope = socket.assigns.current_scope

    with %{} = image <- Images.get(id),
         {:ok, _} <-
           if(action == "pin", do: Images.pin(scope, image), else: Images.unpin(scope, image)) do
      {:noreply, load(socket)}
    else
      {:error, :not_mirrored} ->
        {:noreply,
         put_flash(socket, :error, "That image's files aren't on the control plane yet.")}

      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, "Only admins can do that.")}

      _ ->
        {:noreply, socket}
    end
  end

  defp stale(arches), do: Enum.filter(arches, &(&1.freshness && &1.freshness.level != :ok))

  defp registered(at), do: Calendar.strftime(at, "%b %-d, %Y")

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} current_path={@current_path}>
      <:breadcrumb>Admin</:breadcrumb>
      <:breadcrumb>Images</:breadcrumb>

      <.header>
        Images
        <:subtitle>
          The guest image job VMs boot, per arch. The newest becomes the default unless
          one is pinned; pin the previous one to roll back.
        </:subtitle>
      </.header>

      <div :if={stale(@arches) != []} id="runner-freshness" class="mb-4 space-y-2">
        <.callout
          :for={a <- stale(@arches)}
          kind={if a.freshness.level == :alert, do: "danger", else: "warning"}
          icon="hero-exclamation-triangle"
        >
          The {a.arch} image's runner ({a.default.runner_version}) is {a.freshness.days} days behind
          actions/runner {a.freshness.latest}. GitHub stops giving jobs to runners that fall too far
          behind: release an image with the new runner.
        </.callout>
      </div>

      <.empty_state :if={@arches == []} id="images-empty" icon="hero-square-3-stack-3d">
        No images yet. The control plane registers its release's images when it starts.
      </.empty_state>

      <section :for={a <- @arches} id={"arch-#{a.arch}"} class="mb-6 space-y-4">
        <h2 class="text-base font-semibold text-ink">{a.arch}</h2>

        <.panel id={"default-#{a.arch}"} title="Default">
          <%= if a.default do %>
            <dl class="grid grid-cols-2 gap-x-6 gap-y-3 text-sm sm:grid-cols-4">
              <div>
                <dt class="text-xs text-ink-3">Version</dt>
                <dd class="flex items-center gap-2 font-mono text-ink">
                  {a.default.version}
                  <.badge :if={a.default.pinned} color="amber" size="sm">pinned</.badge>
                </dd>
              </div>
              <div>
                <dt class="text-xs text-ink-3">Runner</dt>
                <dd class="font-mono text-ink">{a.default.runner_version}</dd>
              </div>
              <div>
                <dt class="text-xs text-ink-3">Docker</dt>
                <dd class="font-mono text-ink">{a.default.docker_version || "–"}</dd>
              </div>
              <div>
                <dt class="text-xs text-ink-3">Kernel</dt>
                <dd class="font-mono text-ink">{a.default.kernel_version || "–"}</dd>
              </div>
            </dl>
          <% else %>
            <p class="text-sm text-ink-3">
              No image is ready yet: the control plane is still fetching its files.
            </p>
          <% end %>
        </.panel>

        <div class="grid gap-4 xl:grid-cols-2">
          <.panel id={"images-#{a.arch}"} title="Images" padded={false}>
            <ul class="divide-y divide-line text-sm">
              <li
                :for={image <- a.images}
                id={"image-#{image.id}"}
                class="flex flex-wrap items-start justify-between gap-x-3 gap-y-1 px-5 py-3"
              >
                <div class="min-w-0">
                  <p class="flex flex-wrap items-center gap-2">
                    <span class="font-mono text-ink">{image.version}</span>
                    <.badge :if={a.default && a.default.id == image.id} color="brand" size="sm">
                      default
                    </.badge>
                    <.badge :if={image.pinned} color="amber" size="sm">pinned</.badge>
                    <.badge :if={image.mirror_state == "pending"} size="sm" dot pulse>
                      fetching
                    </.badge>
                    <.badge :if={image.mirror_state == "failed"} color="rose" size="sm">
                      fetch failed
                    </.badge>
                  </p>
                  <p class="mt-0.5 text-xs text-ink-3">
                    Runner {image.runner_version} · registered {registered(image.registered_at)}
                  </p>
                  <p :if={image.mirror_error} class="mt-0.5 text-xs text-danger">
                    {image.mirror_error}
                  </p>
                </div>
                <div class="shrink-0 text-xs">
                  <button
                    :if={image.mirror_state == "ready" and not image.pinned}
                    id={"pin-#{image.id}"}
                    type="button"
                    phx-click="pin"
                    phx-value-id={image.id}
                    data-confirm={"Pin #{image.version} as the #{a.arch} default?"}
                    class="underline-offset-2 hover:underline"
                  >
                    Pin
                  </button>
                  <button
                    :if={image.pinned}
                    id={"unpin-#{image.id}"}
                    type="button"
                    phx-click="unpin"
                    phx-value-id={image.id}
                    class="underline-offset-2 hover:underline"
                  >
                    Unpin
                  </button>
                </div>
              </li>
            </ul>
          </.panel>

          <.panel id={"rollout-#{a.arch}"} title="Rollout" padded={false}>
            <:subtitle :if={a.default}>Where each box is with {a.default.version}.</:subtitle>
            <ul class="divide-y divide-line text-sm">
              <li
                :for={box <- a.boxes}
                id={"rollout-#{a.arch}-#{box.id}"}
                class="flex items-center justify-between gap-3 px-5 py-2.5"
              >
                <span class="min-w-0 truncate text-ink">{box.name}</span>
                <.rollout_state state={a.default && @states[{box.id, a.default.id}]} />
              </li>
              <li :if={a.boxes == []} class="px-5 py-3 text-ink-3">No {a.arch} boxes.</li>
            </ul>
          </.panel>
        </div>
      </section>
    </Layouts.app>
    """
  end

  attr :state, :any, required: true

  defp rollout_state(assigns) do
    ~H"""
    <span class="shrink-0 text-xs">
      <%= case @state && @state.state do %>
        <% "ready" -> %>
          <.badge color="emerald" size="sm" dot>ready</.badge>
        <% s when s in ["downloading", "verifying", "converting"] -> %>
          <.badge color="amber" size="sm" dot pulse>{s} {@state.progress}%</.badge>
        <% "failed" -> %>
          <span class="text-danger">failed: {@state.error}</span>
        <% nil -> %>
          <span class="text-ink-3">not started</span>
        <% other -> %>
          <span class="text-ink-3">{other}</span>
      <% end %>
    </span>
    """
  end
end
