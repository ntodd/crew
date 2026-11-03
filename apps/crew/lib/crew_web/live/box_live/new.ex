defmodule CrewWeb.BoxLive.New do
  @moduledoc """
  Add box (§12.2, §10.2): a name and a type, then a single-use join
  token (valid for an hour) and what to run on the machine.
  """
  use CrewWeb, :live_view

  alias Crew.Boxes

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
       token: nil,
       box_name: nil,
       box_type: nil
     )}
  end

  @impl true
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

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} current_path={@current_path}>
      <:breadcrumb navigate={~p"/boxes"}>Boxes</:breadcrumb>
      <:breadcrumb>Add box</:breadcrumb>
      <.header>
        Add box
        <:subtitle>A join token is good for one box, for an hour.</:subtitle>
      </.header>

      <.panel :if={is_nil(@token)} id="add-box-panel">
        <.form for={@form} id="add-box" phx-submit="create" class="space-y-2">
          <.input field={@form[:box_name]} label="Name" placeholder="m1ultra" />
          <fieldset class="mb-3">
            <legend class="label">Type</legend>
            <div class="space-y-2">
              <label :for={{value, label} <- types()} class="flex items-center gap-2 text-sm text-ink">
                <input
                  type="radio"
                  class="radio"
                  name="box[box_type]"
                  value={value}
                  checked={@form[:box_type].value == value}
                />
                <span class="font-mono text-xs text-ink-2">{value}</span> {label}
              </label>
            </div>
          </fieldset>
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
              command={"sudo ./install-macos.sh --url #{agent_url()}/agent/websocket --token #{@token}"}
            />
          <% type when type in ["linux-vm", "mac-vm"] -> %>
            <p class="mb-2 text-sm text-ink-2">On the host, run:</p>
            <.command
              id="join-command"
              command={"curl -fsSL #{Crew.Config.base_url()}/agent/#{type}.sh | sudo sh -s -- --token #{@token}"}
            />
          <% "linux-metal" -> %>
            <p class="mb-2 text-sm text-ink-2">
              Boot the machine from Flatcar with this box's Ignition. It's fetched with the token:
            </p>
            <.command
              id="join-command"
              command={"curl -fsSL -X POST -d join_token=#{@token} -d arch=x86_64 #{Crew.Config.base_url()}/agent/flatcar/ignition > crew-box.ign"}
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
