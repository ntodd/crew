defmodule CrewWeb.BoxLive.Show do
  @moduledoc """
  A box (§17.3): status, capabilities (pinned and reported, with
  approval), firewall and virtualisation, the latest metrics, what its
  agent last reported (VMs and images), recent operations, the
  reprovision Ignition for a Flatcar box (§12.2), and revoking.
  """
  use CrewWeb, :live_view

  alias Crew.{Agents, Boxes, Metrics, Operations, Repos, Scheduler, Scope, VMs}
  alias Crew.Agents.{Releases, Updates}
  alias Crew.Boxes.Flatcar

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    box = Boxes.get!(id)
    if connected?(socket), do: Boxes.subscribe(box.id)

    {:ok,
     socket
     |> assign(:page_title, box.name)
     |> assign(:data_disk, if(box.type == "linux-metal", do: Boxes.data_disk(box)))
     |> load(box)}
  end

  # The arch a reprovision Ignition is for, by default: a Mac's VM is
  # arm64, and otherwise the guests' arch is the box's.
  defp default_arch(%{type: "mac-vm"}), do: "arm64"
  defp default_arch(%{guest_arch: "arm64"}), do: "arm64"
  defp default_arch(_), do: "amd64"

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
      ops: Operations.recent_for_box(box.id, 10),
      images: box_images(box.id),
      overrides: to_form(Boxes.change_overrides(box), as: :box),
      update: Updates.status(box),
      versions: (Updates.target(box) && Releases.versions(Updates.target(box))) || [],
      fleet: Updates.target(box) && Releases.fleet_version(Updates.target(box))
    )
  end

  defp box_images(box_id) do
    images = Map.new(Crew.Images.list(), &{&1.id, &1})

    for bi <- Crew.Images.box_images(box_id), image = images[bi.image_id] do
      %{image: image, state: bi.state, progress: bi.progress, error: bi.error}
    end
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

  def handle_event(event, _params, socket)
      when event in ["drain", "undrain", "clear_quarantine"] do
    scope = socket.assigns.current_scope
    box = socket.assigns.box

    result =
      case event do
        "drain" -> Boxes.set_draining(scope, box, true)
        "undrain" -> Boxes.set_draining(scope, box, false)
        "clear_quarantine" -> Boxes.clear_quarantine(scope, box)
      end

    case result do
      {:ok, box} -> {:noreply, load(socket, box)}
      {:error, :unauthorized} -> {:noreply, put_flash(socket, :error, "Only admins can do that.")}
    end
  end

  def handle_event("overrides", %{"box" => attrs}, socket) do
    case Boxes.update_overrides(socket.assigns.current_scope, socket.assigns.box, attrs) do
      {:ok, box} ->
        {:noreply, socket |> load(box) |> put_flash(:info, "Saved #{box.name}'s capacity.")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         assign(socket, overrides: to_form(Map.put(changeset, :action, :validate), as: :box))}

      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, "Only admins can do that.")}
    end
  end

  def handle_event("pin_agent", %{"version" => version}, socket) do
    case Boxes.pin_agent_version(socket.assigns.current_scope, socket.assigns.box, version) do
      {:ok, box} ->
        message =
          if box.desired_agent_version,
            do: "Pinned #{box.name}'s agent to #{box.desired_agent_version}.",
            else: "#{box.name}'s agent follows the newest release again."

        {:noreply, socket |> load(box) |> put_flash(:info, message)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {message, _} = changeset.errors[:desired_agent_version]
        {:noreply, put_flash(socket, :error, "Can't pin it: #{message}.")}

      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, "Only admins can do that.")}
    end
  end

  def handle_event("retry_agent_update", _params, socket) do
    case Boxes.retry_agent_update(socket.assigns.current_scope, socket.assigns.box) do
      {:ok, box} -> {:noreply, socket |> load(box) |> put_flash(:info, "Sent the update again.")}
      {:error, :unauthorized} -> {:noreply, put_flash(socket, :error, "Only admins can do that.")}
    end
  end

  def handle_event("kill", %{"id" => id}, socket) do
    with %VMs.VM{box_id: box_id} = vm <- VMs.get(id),
         true <- box_id == socket.assigns.box.id,
         :ok <- VMs.kill(socket.assigns.current_scope, vm) do
      {:noreply, put_flash(socket, :info, "Stopping #{vm.name}.")}
    else
      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, "Only admins can do that.")}

      {:error, :offline} ->
        {:noreply,
         put_flash(socket, :error, "The box is offline: the stop goes when it rejoins.")}

      _ ->
        {:noreply, socket}
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

  defp update_label(%{state: :current}, _online), do: "Up to date"
  defp update_label(%{state: :pending, version: v}, true), do: "Update to #{v} is due"
  defp update_label(%{state: :pending, version: v}, false), do: "Updates to #{v} when it's back"
  defp update_label(%{state: :updating, version: v}, _online), do: "Installing #{v}"
  defp update_label(%{state: :restarting, version: v}, _online), do: "Restarting into #{v}"
  defp update_label(%{state: :blocked, version: v}, _online), do: "#{v} failed twice"
  defp update_label(%{state: :none, target: nil}, _online), do: "Not joined yet"
  defp update_label(%{state: :none, target: t}, _online), do: "No release for #{t}"

  defp update_color(:current), do: "emerald"
  defp update_color(state) when state in [:pending, :updating, :restarting], do: "sky"
  defp update_color(:blocked), do: "amber"
  defp update_color(:none), do: "zinc"

  defp pin_options(versions, fleet),
    do: [{"Follow the newest (#{fleet || "none"})", ""} | Enum.map(versions, &{&1, &1})]

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
        <:subtitle>
          {@box.type} · agent {@box.agent_version || "not joined yet"}<span :if={
            @update.state in [:updating, :restarting]
          }>, updating to {@update.version}</span>
        </:subtitle>
        <:actions>
          <span id="box-status"><.box_status box={@box} online={@online} /></span>
          <%= if Scope.admin?(@current_scope) do %>
            <.button
              :if={
                @box.quarantined_until &&
                  DateTime.compare(@box.quarantined_until, DateTime.utc_now()) == :gt
              }
              id="clear-quarantine"
              size="sm"
              phx-click="clear_quarantine"
            >
              Clear quarantine
            </.button>
            <.button
              :if={!@box.draining}
              id="drain"
              size="sm"
              phx-click="drain"
              data-confirm={"Drain #{@box.name}? It takes no new VMs, and its idle ones are stopped."}
            >
              Drain
            </.button>
            <.button :if={@box.draining} id="undrain" size="sm" phx-click="undrain">Undrain</.button>
          <% end %>
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

      <.callout :if={@update.state == :blocked} id="agent-update-failed" kind="warning">
        <p class="font-medium">
          Agent {@update.version} didn't take on this box twice, so it isn't sent again.
        </p>
        <p class="mt-0.5">
          The box went back to {@box.agent_version}.<span :if={@update.error}> Last time: {@update.error}</span>
        </p>
        <:actions :if={Scope.admin?(@current_scope)}>
          <.button
            id="retry-agent-update"
            size="sm"
            phx-click="retry_agent_update"
            data-confirm={"Send agent #{@update.version} to #{@box.name} again?"}
          >
            Retry
          </.button>
        </:actions>
      </.callout>

      <div class="grid gap-4 lg:grid-cols-2">
        <.panel id="agent" title="Agent">
          <:subtitle>
            Updates follow the newest release for the box's target unless an admin pins one (§20.2).
          </:subtitle>
          <dl class="grid grid-cols-2 gap-x-4 gap-y-2 text-sm">
            <dt class="text-ink-2">Running</dt>
            <dd id="agent-running" class="text-right tabular-nums text-ink">
              {@box.agent_version || "–"}<span :if={@update.target} class="text-ink-3"> · {@update.target}</span>
            </dd>
            <dt class="text-ink-2">{if @update.pinned, do: "Pinned to", else: "Follows"}</dt>
            <dd id="agent-target" class="text-right tabular-nums text-ink">
              {@update.version || "no release yet"}
            </dd>
          </dl>
          <div class="mt-4 flex flex-wrap items-center gap-2">
            <span id="agent-update-state">
              <.badge
                color={update_color(@update.state)}
                dot
                pulse={@update.state in [:updating, :restarting]}
              >
                {update_label(@update, @online)}
              </.badge>
            </span>
            <span
              :if={@update.error && @update.state != :blocked}
              id="agent-update-error"
              class="text-xs text-danger"
            >
              Last update: {@update.error}
            </span>
          </div>
          <form
            :if={Scope.admin?(@current_scope) and @versions != []}
            id="pin-agent"
            phx-submit="pin_agent"
            class="mt-4 flex flex-wrap items-end gap-x-3"
          >
            <div class="w-full sm:w-64">
              <.input
                type="select"
                name="version"
                id="pin-agent-version"
                label="Agent version"
                value={@box.desired_agent_version || ""}
                options={pin_options(@versions, @fleet)}
              />
            </div>
            <div class="mb-3"><.button type="submit" size="sm">Save</.button></div>
          </form>
        </.panel>

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
              <span class="flex items-center justify-end gap-3">
                <.badge
                  color={vm_color(vm.state)}
                  dot
                  pulse={vm.state in ~w(requested starting booted busy)}
                  size="sm"
                >
                  {vm.state}{if vm.fail_reason, do: " · #{vm.fail_reason}"}
                </.badge>
                <button
                  :if={Scope.admin?(@current_scope) and vm.state != "destroyed"}
                  id={"kill-#{vm.id}"}
                  type="button"
                  phx-click="kill"
                  phx-value-id={vm.id}
                  data-confirm={"Kill #{vm.name}? Its job fails."}
                  class="text-xs text-danger underline-offset-2 hover:underline"
                >
                  Kill
                </button>
              </span>
            </li>
            <li :if={@vms == []} class="px-5 py-3 text-ink-3">No VMs.</li>
          </ul>
        </.panel>

        <.panel id="images" title="Images" padded={false}>
          <ul class="divide-y divide-line text-sm">
            <li :for={i <- @images} class="flex items-center justify-between gap-3 px-5 py-2.5">
              <span class="truncate text-ink">{i.image.version}
              <span class="text-ink-3">· {i.image.arch}</span></span>
              <span class={["text-xs", (i.state == "failed" && "text-danger") || "text-ink-3"]}>
                {i.state}{if i.state in ~w(downloading verifying converting), do: " · #{i.progress}%"}{if i.error,
                  do: " · #{i.error}"}
              </span>
            </li>
            <li :if={@images == []} class="px-5 py-3 text-ink-3">No images yet.</li>
          </ul>
        </.panel>

        <.panel :if={Scope.admin?(@current_scope)} id="capacity" title="Capacity">
          <:subtitle>
            Overrides for what placement offers job VMs (§8.3). Empty means the default.
          </:subtitle>
          <.form for={@overrides} id="overrides" phx-submit="overrides" class="grid grid-cols-2 gap-3">
            <.input field={@overrides[:allocatable_vcpus_override]} type="number" label="vCPUs" />
            <.input
              field={@overrides[:allocatable_memory_mib_override]}
              type="number"
              label="Memory (MiB)"
            />
            <.input field={@overrides[:reserve_vcpus]} type="number" label="Reserved vCPUs" />
            <.input
              field={@overrides[:reserve_memory_mib]}
              type="number"
              label="Reserved memory (MiB)"
            />
            <.input
              field={@overrides[:cpu_overcommit]}
              type="number"
              step="0.1"
              label="CPU overcommit"
            />
            <.input field={@overrides[:max_vms]} type="number" label="Most VMs" />
            <div class="col-span-2"><.button type="submit" size="sm">Save</.button></div>
          </.form>
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

      <.panel
        :if={Scope.admin?(@current_scope) and @box.type in Flatcar.types()}
        id="reprovision"
        title="Reprovision"
      >
        <:subtitle>
          For a new OS disk over this box's data disk, to recover it. The Ignition holds no join token or Tailscale key:
          the box keeps its agent, identity and tailnet node from the data disk, and Flatcar updates itself from there.
        </:subtitle>
        <form
          action={~p"/boxes/#{@box.id}/reprovision.ign"}
          method="get"
          class="flex flex-wrap items-end gap-x-3"
        >
          <div class="w-40">
            <.input
              type="select"
              name="arch"
              id="reprovision-arch"
              label="Architecture"
              value={default_arch(@box)}
              options={[{"x86_64 (amd64)", "amd64"}, {"arm64", "arm64"}]}
            />
          </div>
          <div :if={@box.type == "linux-metal"} class="w-full sm:w-56">
            <.input
              name="data_disk"
              id="reprovision-data-disk"
              label="Data disk"
              value={@data_disk}
              placeholder="/dev/sdb"
              autocomplete="off"
            />
          </div>
          <div class="w-full min-w-0 sm:w-auto sm:flex-1">
            <.input
              name="ssh_keys"
              id="reprovision-ssh-key"
              label="Break-glass SSH key (optional)"
              value=""
              placeholder="ssh-ed25519 AAAA… you@laptop"
              class="input font-mono text-xs"
            />
          </div>
          <div class="mb-3">
            <.button type="submit" size="sm" icon="hero-arrow-down-tray-micro">
              Download Ignition
            </.button>
          </div>
        </form>
        <%= if @box.type == "linux-metal" do %>
          <p class="mb-2 text-sm text-ink-2">From Flatcar's live image, onto the OS disk:</p>
          <.command
            id="reprovision-command"
            command={"sudo flatcar-install -d /dev/sda -i crew-#{@box.name}-#{default_arch(@box)}-reprovision.ign && sudo reboot"}
          />
        <% else %>
          <p class="mb-2 text-sm text-ink-2">On the host:</p>
          <.command
            id="reprovision-command"
            command={"sudo crew-box reimage crew-#{@box.name}-#{default_arch(@box)}-reprovision.ign"}
          />
        <% end %>
      </.panel>

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
