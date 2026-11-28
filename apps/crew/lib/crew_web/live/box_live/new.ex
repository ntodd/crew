defmodule CrewWeb.BoxLive.New do
  @moduledoc """
  Add box (§12.2, §10.2): a name and a type, then a single-use join
  token (valid for an hour) and what to run on the machine.

  A Flatcar box (`linux-metal`, `linux-vm`) also takes an
  optional break-glass SSH key, a Tailscale auth key when the control
  plane has no OAuth client to mint one, and on bare metal its disks:
  one disk (the default), which `/srv/crew` shares with Flatcar, or a
  separate data disk. The launchers fetch the box's Ignition themselves; bare metal
  downloads it here, and so can a `linux-vm` box whose VM is built by
  hand where the launcher can't run (a TrueNAS SCALE host, say), so it
  enrolls as the nested box it is rather than as `linux-metal`.
  """
  use CrewWeb, :live_view

  alias Crew.Boxes
  alias Crew.Boxes.Flatcar

  @types [
    {"mac-vz", "Mac (Virtualization.framework)"},
    {"linux-vm", "Linux with KVM (Flatcar VM)"},
    {"linux-metal", "Dedicated Linux machine (Flatcar on bare metal)"}
  ]

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Add box",
       form: to_form(%{"box_name" => "", "box_type" => "mac-vz"}, as: :box),
       minted?: Crew.Tailscale.configured?(),
       token: nil,
       box_name: nil,
       box_type: nil,
       os_disk: nil,
       data_disk: nil,
       disk_layout: nil
     )}
  end

  @impl true
  def handle_event("change", %{"box" => params}, socket),
    do: {:noreply, assign(socket, :form, to_form(params, as: :box))}

  def handle_event("create", %{"box" => params}, socket) do
    case Boxes.create_join_token(socket.assigns.current_scope, params) do
      {:ok, token} ->
        {:noreply,
         assign(socket,
           token: token,
           box_name: params["box_name"],
           box_type: params["box_type"],
           os_disk: params["os_disk"],
           data_disk: if(params["disk_layout"] == "separate", do: params["data_disk"]),
           disk_layout: params["disk_layout"] || "one"
         )}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset, as: :box))}

      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, "Only admins add boxes.")}
    end
  end

  defp types, do: @types

  defp agent_url do
    base = Crew.Config.base_url()
    String.replace_prefix(base, "https://", "wss://") |> String.replace_prefix("http://", "ws://")
  end

  # The key the Mac's agent checks its updates against (§20.2), the one
  # whose fingerprint is shown above.
  defp release_key_option do
    case Crew.Config.release_public_key() do
      nil -> ""
      key -> " --release-key #{Base.encode64(key)}"
    end
  end

  # The Ignition download, the command that fetches it on the machine,
  # and the install from Flatcar's live image: bare metal's way in, and
  # a linux-vm box's when its VM is built by hand.
  attr :token, :string, required: true
  attr :box_name, :string, required: true
  attr :os_disk, :string, required: true
  attr :fetch_id, :string, required: true
  attr :data_disk?, :boolean, default: true, doc: "whether there's a data disk not to install to"
  attr :data_disk, :string, default: nil, doc: "the separately selected physical data device"

  defp ignition_steps(assigns) do
    ~H"""
    <p class="mb-3 text-sm text-ink-2">
      Download the box's Ignition. It holds the join token (and the box's Tailscale key), so keep it to yourself.
      Delete it once the box has enrolled.
    </p>
    <form
      id="ignition-download"
      action="/agent/flatcar/ignition"
      method="post"
      class="mb-4 flex flex-wrap items-end gap-3"
    >
      <input type="hidden" name="join_token" value={@token} />
      <div class="w-40">
        <.input
          type="select"
          name="arch"
          id="ignition-arch"
          label="Architecture"
          value="amd64"
          options={[{"x86_64 (amd64)", "amd64"}, {"arm64", "arm64"}]}
        />
      </div>
      <div class="mb-3">
        <.button type="submit" size="sm" icon="hero-arrow-down-tray-micro">
          Download Ignition
        </.button>
      </div>
    </form>
    <p class="mb-2 text-sm text-ink-2">
      Or fetch it on the machine (a new file only you can read):
    </p>
    <.command
      id={@fetch_id}
      command={"(umask 077; f=crew-#{@box_name}.ign; s=$(stty -g 2>/dev/null); trap 'stty \"$s\" 2>/dev/null' EXIT; trap 'exit 130' INT; stty -echo 2>/dev/null; printf 'Join token: '; read -r t; stty \"$s\" 2>/dev/null; echo; rm -f \"$f.new\" && printf %s \"$t\" | curl -fsSL -X POST --data-urlencode join_token@- -d arch=amd64 #{Crew.Config.base_url()}/agent/flatcar/ignition -o \"$f.new\" && mv -f \"$f.new\" \"$f\")"}
    />
    <p class="mb-2 mt-4 text-sm text-ink-2">
      Then, from Flatcar's live image, install it to the OS disk{if @data_disk?,
        do: " (not the data disk)"} and reboot:
    </p>
    <.command
      id="flatcar-install"
      command={Flatcar.install_command(@os_disk, "crew-#{@box_name}.ign", @data_disk)}
    />
    """
  end

  @impl true
  def render(assigns) do
    assigns =
      assign(assigns,
        type: assigns.form[:box_type].value,
        layout: assigns.form[:disk_layout].value || "one"
      )

    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} current_path={@current_path}>
      <:breadcrumb navigate={~p"/boxes"}>Boxes</:breadcrumb>
      <:breadcrumb>Add box</:breadcrumb>
      <.header>
        Add box
        <:subtitle>A join token is good for one box, for an hour.</:subtitle>
      </.header>

      <.panel :if={is_nil(@token)} id="add-box-panel">
        <.form for={@form} id="add-box" phx-change="change" phx-submit="create" class="space-y-2">
          <.input field={@form[:box_name]} label="Name" placeholder="m1ultra" />
          <fieldset class="mb-3">
            <legend class="label">Type</legend>
            <div class="space-y-2">
              <label
                :for={{value, label} <- types()}
                class="flex items-start gap-2 text-sm text-ink sm:items-center"
              >
                <input
                  type="radio"
                  class="radio mt-0.5 sm:mt-0"
                  name="box[box_type]"
                  value={value}
                  checked={@type == value}
                />
                <span>
                  <span class="font-mono text-xs text-ink-2">{value}</span> {label}
                </span>
              </label>
            </div>
          </fieldset>

          <div :if={@type in Flatcar.types()} id="flatcar-fields" class="space-y-2">
            <.input field={@form[:uplink]} label="Uplink interface (optional)" placeholder="eno2" />
            <.input
              field={@form[:extra_blocked]}
              label="Additional blocked IPv4 addresses or CIDRs (comma-separated)"
              placeholder="203.0.113.7, 198.51.100.0/24"
            />
            <div :if={@type == "linux-metal"}>
              <fieldset id="disk-layout" class="mb-3">
                <legend class="label">Disks</legend>
                <div class="space-y-2">
                  <label
                    :for={
                      {value, label, help} <- [
                        {"one", "One disk",
                         "Crew's images, job VMs and cache go on the OS disk, after Flatcar."},
                        {"separate", "Separate data disk",
                         "They go on a disk of their own, which Crew formats only if it's empty."}
                      ]
                    }
                    class="flex items-start gap-2 text-sm text-ink"
                  >
                    <input
                      type="radio"
                      class="radio mt-0.5"
                      name="box[disk_layout]"
                      value={value}
                      checked={@layout == value}
                    />
                    <span>{label} <span class="text-xs text-ink-3">{help}</span></span>
                  </label>
                </div>
              </fieldset>

              <.input
                field={@form[:os_disk]}
                label="OS disk"
                placeholder="/dev/disk/by-id/nvme-…"
                autocomplete="off"
              />
              <p id="os-disk-help" class="-mt-2 mb-3 text-xs text-ink-3">
                Where Flatcar goes, by its <span class="font-mono">/dev/disk/by-id/…</span>
                name, from <span class="font-mono">ls -l /dev/disk/by-id/</span>
                in Flatcar's live image: <span class="font-mono">/dev/nvme0n1</span>
                can be another disk the next time.
                <%= if @layout == "one" do %>
                  At least 128 GiB (a drive sold as 128 GB is too small). Crew's data is partition 10,
                  which reinstalling with the box's reprovision Ignition keeps.
                <% end %>
              </p>

              <div :if={@layout == "separate"}>
                <.input
                  field={@form[:data_disk]}
                  label="Data disk"
                  placeholder="/dev/sdb"
                  autocomplete="off"
                />
                <p class="-mt-2 mb-3 text-xs text-ink-3">
                  The disk for images, job VMs and the cache (XFS). Crew formats it only if it's empty. A
                  <span class="font-mono">/dev/disk/by-id/…</span>
                  path survives disks being renamed.
                </p>
              </div>
            </div>

            <.input
              field={@form[:ssh_keys]}
              type="textarea"
              rows="2"
              label="Break-glass SSH key (optional)"
              placeholder="ssh-ed25519 AAAA… you@laptop"
              class="input font-mono text-xs"
            />
            <p class="-mt-2 mb-3 text-xs text-ink-3">
              Lets you in as <span class="font-mono">core</span> if the agent can't be reached.
            </p>

            <div :if={not @minted?}>
              <.input
                field={@form[:tailscale_auth_key]}
                type="password"
                label="Tailscale auth key (optional)"
                placeholder="tskey-auth-…"
                autocomplete="off"
              />
              <p class="-mt-2 mb-3 text-xs text-ink-3">
                Single-use and pre-authorized, tagged <span class="font-mono">tag:crew-box</span>.
                Without one, the box has to reach this control plane some other way.
              </p>
            </div>
            <p :if={@minted?} id="tailscale-minted" class="mb-3 text-xs text-ink-3">
              The box gets a Tailscale auth key of its own, from this control plane's OAuth client.
            </p>
          </div>

          <.button type="submit" variant="primary" size="sm">Create join token</.button>
        </.form>
      </.panel>

      <.panel :if={@token} id="join-instructions" title={"Add #{@box_name}"}>
        <:subtitle>
          Compare the release key's fingerprint with the one in Crew's README and release notes first.
          The box trusts this control plane's key for its first install otherwise.
        </:subtitle>
        <p class="mb-4 break-all font-mono text-xs text-ink">
          Release key: {Crew.Config.release_key_fingerprint() ||
            "not configured (CREW_RELEASE_PUBLIC_KEY)"}
        </p>

        <%= case @box_type do %>
          <% "mac-vz" -> %>
            <ol class="list-decimal space-y-2 pl-5 text-sm text-ink-2">
              <li>
                Download <span class="font-mono">crew-agent-darwin-arm64.tar.gz</span>
                from Crew's GitHub release.
              </li>
              <li>Verify it against the published release key fingerprint (above).</li>
              <li>On the Mac, in the unpacked directory, run:</li>
            </ol>
            <.command
              id="join-command"
              command={"sudo ./install-macos.sh --url #{agent_url()}/agent/websocket --name #{@box_name}#{release_key_option()} --cache-vm"}
            />
            <p class="mt-3 mb-2 text-sm text-ink-2">
              When it asks, paste the join token. It goes on no command line on the Mac, or in its shell's history.
            </p>
            <.command id="join-token" command={@token} />
            <p id="cache-vm-note" class="mt-3 text-xs text-ink-3">
              <span class="font-mono">--cache-vm</span>
              first makes the box's registry cache: a small Flatcar VM on the same Mac (2 CPUs, 4 GiB, a 100 GiB sparse data disk) that its job VMs pull images through.
              Without it, set <span class="font-mono">CREW_VZ_DNS_FALLBACK</span>
              in the agent's env so job VMs can resolve names.
            </p>
          <% "linux-vm" -> %>
            <p class="mb-2 text-sm text-ink-2">On the host, run:</p>
            <.command
              id="join-command"
              command={"curl -fsSL #{Crew.Config.base_url()}/agent/linux-vm.sh | sudo sh -s"}
            />
            <p class="mt-3 mb-2 text-sm text-ink-2">
              When it asks, paste the join token. It never goes on the host's command line, where anyone on it could read it.
            </p>
            <.command id="join-token" command={@token} />
            <p class="mt-3 text-xs text-ink-3">
              It takes <span class="font-mono">--token-file FILE</span>
              (no terminal), <span class="font-mono">--cpus N</span>,
              <span class="font-mono">--memory GiB</span>
              and <span class="font-mono">--data GiB</span>
              (the data disk, 200 by default, at least 100). It prints the box's progress until it has enrolled.
            </p>
            <div id="hand-built-vm" class="mt-6 border-t border-line pt-4">
              <p class="mb-3 text-sm text-ink-2">
                Or, where the launcher can't run (TrueNAS SCALE, say), build the VM yourself:
                host CPU passthrough (it runs VMs of its own), UEFI, fixed memory, and two VirtIO disks,
                the OS disk (<span class="font-mono">/dev/vda</span>) and then the data disk
                (<span class="font-mono">/dev/vdb</span>, at least 100 GiB), which the Ignition formats.
                Boot Flatcar's ISO in it.
              </p>
              <.ignition_steps
                token={@token}
                box_name={@box_name}
                os_disk="/dev/vda"
                fetch_id="ignition-fetch-command"
              />
            </div>
          <% "linux-metal" -> %>
            <.ignition_steps
              token={@token}
              box_name={@box_name}
              os_disk={@os_disk}
              fetch_id="join-command"
              data_disk?={@disk_layout == "separate"}
              data_disk={@data_disk}
            />
            <p class="mt-3 mb-2 text-sm text-ink-2">
              The join token, for the fetch when it asks:
            </p>
            <.command id="join-token" command={@token} />
        <% end %>

        <div :if={Crew.Config.dev?()} id="dev-command" class="mt-6">
          <p class="mb-2 text-sm text-ink-2">Development: run an agent here with the null driver.</p>
          <.command
            id="dev-join-command"
            command={"cd apps/crew_agent && CREW_DEV=1 CREW_DRIVER=null CREW_URL=#{agent_url()}/agent/websocket CREW_JOIN_TOKEN=#{@token} CREW_BOX_NAME=#{@box_name} mix run --no-halt"}
          />
        </div>
      </.panel>
    </Layouts.app>
    """
  end
end
