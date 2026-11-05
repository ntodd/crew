defmodule CrewWeb.BoxLive.New do
  @moduledoc """
  Add box (§12.2, §10.2): a name and a type, then a single-use join
  token (valid for an hour) and what to run on the machine.

  A Flatcar box (`linux-metal`, `linux-vm`, `mac-vm`) also takes an
  optional break-glass SSH key, a Tailscale auth key when the control
  plane has no OAuth client to mint one, and on bare metal the data
  disk. The launchers fetch the box's Ignition themselves; bare metal
  downloads it here.
  """
  use CrewWeb, :live_view

  alias Crew.Boxes
  alias Crew.Boxes.Flatcar

  @types [
    {"mac-vz", "Mac (Virtualization.framework)"},
    {"mac-vm", "Mac, M3 or later (Firecracker in a Flatcar VM)"},
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
       box_type: nil
     )}
  end

  @impl true
  def handle_event("change", %{"box" => params}, socket),
    do: {:noreply, assign(socket, :form, to_form(params, as: :box))}

  def handle_event("create", %{"box" => params}, socket) do
    case Boxes.create_join_token(socket.assigns.current_scope, params) do
      {:ok, token} ->
        {:noreply,
         assign(socket, token: token, box_name: params["box_name"], box_type: params["box_type"])}

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

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :type, assigns.form[:box_type].value)

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
            <div :if={@type == "linux-metal"}>
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
              command={"sudo ./install-macos.sh --url #{agent_url()}/agent/websocket --token #{@token}#{release_key_option()} --cache-vm"}
            />
            <p id="cache-vm-note" class="mt-3 text-xs text-ink-3">
              <span class="font-mono">--cache-vm</span>
              first makes the box's registry cache: a small Flatcar VM on the same Mac (2 CPUs, 4 GiB, a 100 GiB sparse data disk) that its job VMs pull images through.
              Without it, set <span class="font-mono">CREW_VZ_DNS_FALLBACK</span>
              in the agent's env so job VMs can resolve names.
            </p>
          <% type when type in ["linux-vm", "mac-vm"] -> %>
            <p class="mb-2 text-sm text-ink-2">On the host, run:</p>
            <.command
              id="join-command"
              command={"curl -fsSL #{Crew.Config.base_url()}/agent/#{type}.sh | sudo sh -s -- --token #{@token}"}
            />
            <p class="mt-3 text-xs text-ink-3">
              It takes <span class="font-mono">--cpus N</span>,
              <span class="font-mono">--memory GiB</span>
              and <span class="font-mono">--data GiB</span>
              (the data disk, 200 by default, at least 100). It prints the box's progress until it has enrolled.
            </p>
          <% "linux-metal" -> %>
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
              id="join-command"
              command={"(umask 077; f=crew-#{@box_name}.ign; rm -f \"$f.new\" && curl -fsSL -X POST -d join_token=#{@token} -d arch=amd64 #{Crew.Config.base_url()}/agent/flatcar/ignition -o \"$f.new\" && mv -f \"$f.new\" \"$f\")"}
            />
            <p class="mb-2 mt-4 text-sm text-ink-2">
              Then, from Flatcar's live image, install it to the OS disk (not the data disk) and reboot:
            </p>
            <.command
              id="flatcar-install"
              command={"sudo flatcar-install -d /dev/sda -i crew-#{@box_name}.ign && sudo reboot"}
            />
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
