defmodule CrewWeb.BoxLive.Index do
  @moduledoc "Boxes (§17.3): each with its status, driver, arch, capacity and agent version."
  use CrewWeb, :live_view

  alias Crew.{Agents, Boxes, Metrics, Scope}

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Boxes.subscribe()
    {:ok, socket |> assign(:page_title, "Boxes") |> load()}
  end

  defp load(socket) do
    boxes = Boxes.list()
    online = MapSet.new(Agents.online_ids())

    assign(socket,
      boxes: boxes,
      online: online,
      metrics: Map.new(boxes, &{&1.id, Metrics.latest_box(&1.id)})
    )
  end

  @impl true
  def handle_info({:box_changed, _id}, socket), do: {:noreply, load(socket)}
  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} current_path={@current_path}>
      <:breadcrumb>Boxes</:breadcrumb>
      <.header>
        Boxes
        <:subtitle>The machines that run job VMs.</:subtitle>
        <:actions>
          <.button
            :if={Scope.admin?(@current_scope)}
            navigate={~p"/boxes/new"}
            variant="primary"
            size="sm"
            icon="hero-plus"
          >
            Add box
          </.button>
        </:actions>
      </.header>

      <div :if={@boxes != []} class="grid gap-4 md:grid-cols-2 xl:grid-cols-3">
        <.link
          :for={box <- @boxes}
          id={"box-#{box.id}"}
          navigate={~p"/boxes/#{box.id}"}
          class="block rounded-xl border border-line bg-raised p-5 shadow-xs transition-colors hover:bg-subtle"
        >
          <div class="flex items-start justify-between gap-3">
            <div class="min-w-0">
              <p class="truncate font-semibold text-ink">{box.name}</p>
              <p class="mt-0.5 text-xs text-ink-3">
                {box.type} · {box.driver || "no driver yet"} · {box.guest_arch || "?"} · agent {box.agent_version ||
                  "?"}
              </p>
            </div>
            <.box_status box={box} online={MapSet.member?(@online, box.id)} />
          </div>
          <div :if={caps = box.pinned_capabilities} class="mt-4 space-y-3">
            <.capacity_bar
              label="CPU"
              value={(m = @metrics[box.id]) && m.cpu_pct}
              max={100}
              unit="%"
            />
            <.capacity_bar
              label="Memory (MiB)"
              value={(m = @metrics[box.id]) && m.mem_used_mib}
              max={(m = @metrics[box.id]) && m.mem_total_mib}
            />
            <p class="text-xs text-ink-3">
              {caps["vcpus"]} vCPU · {div(caps["memory_mib"] || 0, 1024)} GiB for VMs · {div(
                caps["vm_area_mib"] || 0,
                1024
              )} GiB clone area
            </p>
          </div>
        </.link>
      </div>

      <.panel :if={@boxes == []}>
        <.empty_state id="boxes-empty" icon="hero-server-stack" title="Add your first box">
          A box is a machine that runs job VMs: a Mac with Virtualization.framework, or Linux with KVM.
          <:action :if={Scope.admin?(@current_scope)}>
            <.button navigate={~p"/boxes/new"} size="sm" variant="primary">Add box</.button>
          </:action>
        </.empty_state>
      </.panel>
    </Layouts.app>
    """
  end
end
