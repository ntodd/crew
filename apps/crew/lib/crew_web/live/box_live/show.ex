defmodule CrewWeb.BoxLive.Show do
  @moduledoc """
  A box (§17.3): status, capabilities (pinned and reported, with
  approval), firewall and virtualisation, the latest metrics, what its
  agent last reported (VMs and images), recent operations, and revoking.
  """
  use CrewWeb, :live_view

  alias Crew.{Agents, Boxes, Metrics, Operations, Repos, Scheduler, Scope, VMs}

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    box = Boxes.get!(id)
    if connected?(socket), do: Boxes.subscribe(box.id)
    {:ok, socket |> assign(:page_title, box.name) |> load(box)}
  end

  defp load(socket, box) do
    assign(socket,
      box: box,
      online: Agents.online?(box.id),
      metrics: Metrics.latest_box(box.id),
      inventory: VMs.inventory(box.id),
      vms: VMs.box_vms(box.id),
      allocation: VMs.allocation(box.id),
      capacity: Scheduler.capacity(box),
      readable: Repos.readable_ids(socket.assigns.current_scope),
      ops: Operations.recent_for_box(box.id, 10)
    )
  end

  # A repo the member can't read is named as such (§18.3).
  defp repo_name(%{repo: repo}, :all), do: repo.full_name

  defp repo_name(%{repo: repo}, ids),
    do: if(repo.id in ids, do: repo.full_name, else: "a private repo")

  defp vm_color(state) do
    case state do
      "busy" -> "brand"
      "idle" -> "emerald"
      "failed" -> "rose"
      s when s in ~w(requested starting booted) -> "sky"
      _ -> "zinc"
    end
  end

  @impl true
  def handle_info({event, _id}, socket) when event in [:box_changed, :box_metrics],
    do: {:noreply, load(socket, Boxes.get!(socket.assigns.box.id))}

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def handle_event("approve", _params, socket) do
    case Boxes.approve_capabilities(socket.assigns.current_scope, socket.assigns.box) do
      {:ok, box} ->
        {:noreply, socket |> load(box) |> put_flash(:info, "Accepted the new capabilities.")}

      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, "Only admins can do that.")}
    end
  end

  def handle_event("revoke", _params, socket) do
    case Boxes.revoke(socket.assigns.current_scope, socket.assigns.box) do
      {:ok, box} ->
        {:noreply,
         socket |> put_flash(:info, "Revoked #{box.name}.") |> push_navigate(to: ~p"/boxes")}

      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, "Only admins can do that.")}
    end
  end

  @fields [
    {"vcpus", "vCPUs"},
    {"memory_mib", "Memory (MiB)"},
    {"vm_area_mib", "Clone area (MiB)"},
    {"max_vcpus_per_vm", "Most vCPUs per VM"},
    {"max_memory_mib_per_vm", "Most memory per VM (MiB)"},
    {"vmm_overhead_mib", "VMM overhead per VM (MiB)"},
    {"driver", "Driver"},
    {"driver_version", "Driver version"},
    {"guest_arch", "Guest arch"}
  ]

  defp fields, do: @fields

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} current_path={@current_path}>
      <:breadcrumb navigate={~p"/boxes"}>Boxes</:breadcrumb>
      <:breadcrumb>{@box.name}</:breadcrumb>

      <.header>
        {@box.name}
        <:subtitle>{@box.type} · agent {@box.agent_version || "not joined yet"}</:subtitle>
        <:actions>
          <.box_status box={@box} online={@online} />
        </:actions>
      </.header>

      <.callout
        :if={@box.needs_approval}
        id="needs-approval"
        kind="warning"
        icon="hero-exclamation-triangle"
      >
        The agent reports capabilities that differ from the ones pinned at enrollment
        ({(@box.capabilities || %{})["vcpus"]} vCPUs, {(@box.capabilities || %{})["memory_mib"]} MiB, {(@box.capabilities ||
                                                                                                          %{})[
          "guest_arch"
        ]}).
        It gets no jobs until an admin accepts them.
        <:actions :if={Scope.admin?(@current_scope)}>
          <.button
            id="approve-capabilities"
            size="sm"
            phx-click="approve"
            data-confirm="Accept the box's new capabilities?"
          >
            Accept
          </.button>
        </:actions>
      </.callout>

      <div class="grid gap-4 lg:grid-cols-2">
        <.panel id="capabilities" title="Capabilities">
          <:subtitle>Pinned at enrollment; placement uses these.</:subtitle>
          <dl :if={@box.pinned_capabilities} class="grid grid-cols-2 gap-x-4 gap-y-2 text-sm">
            <%= for {key, label} <- fields() do %>
              <dt class="text-ink-2">{label}</dt>
              <dd class="text-right tabular-nums text-ink">{@box.pinned_capabilities[key]}</dd>
            <% end %>
          </dl>
          <p :if={is_nil(@box.pinned_capabilities)} class="text-sm text-ink-3">
            The agent hasn't reported yet.
          </p>
          <div class="mt-4 flex flex-wrap gap-2">
            <.badge color={if @box.firewall_ok, do: "emerald", else: "rose"} dot>
              {if @box.firewall_ok, do: "Firewall verified", else: "Firewall not verified"}
            </.badge>
            <.badge :if={@box.virtualized} color="sky">
              Virtualized{if @box.hypervisor_vendor, do: " (#{@box.hypervisor_vendor})"}
            </.badge>
            <.badge :if={@box.sleep_disabled == false} color="amber">
              Sleep is on: jobs pause when the Mac sleeps
            </.badge>
          </div>
        </.panel>

        <.panel id="metrics" title="Now">
          <div :if={@metrics} class="space-y-3">
            <.capacity_bar label="CPU" value={Float.round(@metrics.cpu_pct, 1)} max={100} unit="%" />
            <.capacity_bar
              label="Memory (MiB)"
              value={@metrics.mem_used_mib}
              max={@metrics.mem_total_mib}
            />
            <.capacity_bar
              label="Disk (MiB)"
              value={@metrics.disk_used_mib}
              max={@metrics.disk_total_mib}
            />
            <p class="text-xs text-ink-3">
              Load {@metrics.load1} · {@metrics.vms_running} VMs running · {@metrics.vm_area_free_mib} MiB clone area free
            </p>
          </div>
          <p :if={is_nil(@metrics)} class="text-sm text-ink-3">No metrics yet.</p>
        </.panel>

        <.panel id="vms" title="VMs" padded={false} class="lg:col-span-2">
          <:subtitle>
            <span id="allocation">
              {@allocation.vcpus} of {if @capacity, do: trunc(@capacity.vcpus), else: "–"} vCPUs · {gib(
                @allocation.memory_mib
              )} of {if @capacity, do: gib(@capacity.memory_mib), else: "–"} GiB memory allocated
            </span>
          </:subtitle>
          <ul class="divide-y divide-line text-sm">
            <li
              :for={vm <- @vms}
              id={"vm-#{vm.id}"}
              class="grid grid-cols-[minmax(0,1fr)_auto] items-center gap-x-4 gap-y-1 px-5 py-2.5 sm:grid-cols-[minmax(0,2fr)_minmax(0,1.5fr)_auto_auto]"
            >
              <span class="truncate font-mono text-xs text-ink">{vm.name}</span>
              <span class="truncate text-ink-2 max-sm:order-last">{repo_name(vm, @readable)}</span>
              <span class="tabular-nums text-xs text-ink-3 max-sm:hidden">
                {vm.vcpus} vCPU · {gib(vm.memory_mib)} GiB
              </span>
              <.badge
                color={vm_color(vm.state)}
                dot
                pulse={vm.state in ~w(requested starting booted busy)}
                size="sm"
              >
                {vm.state}{if vm.fail_reason, do: " · #{vm.fail_reason}"}
              </.badge>
            </li>
            <li :if={@vms == []} class="px-5 py-3 text-ink-3">No VMs.</li>
          </ul>
        </.panel>

        <.panel id="inventory" title="Agent's inventory" padded={false}>
          <:subtitle>What the agent last reported.</:subtitle>
          <%= if @inventory do %>
            <ul class="divide-y divide-line text-sm">
              <li :for={vm <- @inventory.vms} class="flex justify-between gap-3 px-5 py-2.5">
                <span class="truncate font-mono text-xs text-ink">{vm.vm_id}</span>
                <span class="text-ink-2">{if vm.alive, do: "running", else: "exited"}</span>
              </li>
              <li :for={image <- @inventory.images} class="flex justify-between gap-3 px-5 py-2.5">
                <span class="truncate font-mono text-xs text-ink">image {image.id}</span>
                <span class="text-ink-2">{image.state}</span>
              </li>
              <li :if={@inventory.vms == [] and @inventory.images == []} class="px-5 py-3 text-ink-3">
                No VMs or images.
              </li>
            </ul>
          <% else %>
            <p class="px-5 py-4 text-sm text-ink-3">
              Nothing reported since the control plane started.
            </p>
          <% end %>
        </.panel>

        <.panel id="operations" title="Recent commands" padded={false}>
          <ul class="divide-y divide-line text-sm">
            <li :for={op <- @ops} class="flex justify-between gap-3 px-5 py-2.5">
              <span class="text-ink">{action_label(op.command)}</span>
              <span class={[
                "text-xs",
                op.status == "failed" && "text-danger",
                op.status != "failed" && "text-ink-3"
              ]}>
                {op.status}{if op.error, do: ": #{op.error}"}
              </span>
            </li>
            <li :if={@ops == []} class="px-5 py-3 text-ink-3">None yet.</li>
          </ul>
        </.panel>
      </div>

      <.panel :if={Scope.admin?(@current_scope)} id="danger" title="Revoke">
        <:subtitle>
          Deletes the agent's key and drops its connection at once. Re-adding it needs a new join token.
        </:subtitle>
        <.button
          id="revoke-box"
          variant="danger_outline"
          size="sm"
          phx-click="revoke"
          data-confirm={"Revoke #{@box.name}? Its agent is disconnected at once."}
        >
          Revoke {@box.name}
        </.button>
      </.panel>
    </Layouts.app>
    """
  end
end
