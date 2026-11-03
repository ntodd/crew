defmodule CrewAgent.Connection do
  @moduledoc """
  The agent's socket to the control plane.

  The agent always dials out. Every connect attempt carries freshly signed
  headers (`CrewProtocol.Auth`), so reconnects are handled here rather
  than by Slipstream's `reconnect/1`, which would replay the first
  attempt's headers and fail the clock-skew check after a minute.

  Once joined to `agent:<id>`, commands arrive as `command` messages and
  go to `CrewAgent.Ops`; events from `CrewAgent.Outbox` go out as
  `event` pushes, and results are acknowledged by the control plane's
  reply.
  """
  use Slipstream, restart: :permanent

  alias CrewAgent.{Config, Identity, Ops, Outbox, Reporter, VMs}
  alias CrewProtocol.{Auth, Command, Event}

  require Logger

  @backoff [1_000, 2_000, 5_000, 10_000, 30_000]
  # Rejoining a refused or crashed channel: soon at first, then slowly, so
  # a refusal (say, an unsupported protocol version) isn't retried 10 times
  # a second.
  @rejoin_backoff [500, 1_000, 2_000, 5_000, 10_000, 30_000]

  def start_link(opts), do: Slipstream.start_link(__MODULE__, opts, name: __MODULE__)

  @impl Slipstream
  def init(_opts) do
    socket =
      new_socket()
      |> assign(
        config: Config.get(),
        identity: nil,
        attempt: 0,
        acks: %{},
        topic: nil,
        joined: false
      )

    {:ok, socket, {:continue, :identify}}
  end

  @impl Slipstream
  def handle_continue(:identify, socket) do
    config = socket.assigns.config

    case Identity.load(Config.agent_dir(config)) do
      {:ok, identity} ->
        {:noreply, socket |> assign(identity: identity) |> open()}

      :none when is_binary(config.join_token) and config.join_token != "" ->
        enroll(socket)

      :none ->
        Logger.error(
          "no agent identity in #{config.data_dir} and no join token (CREW_JOIN_TOKEN) to enroll with"
        )

        Process.send_after(self(), :identify, 30_000)
        {:noreply, socket}

      {:error, reason} ->
        Logger.error("couldn't load the agent identity: #{inspect(reason)}")
        Process.send_after(self(), :identify, 30_000)
        {:noreply, socket}
    end
  end

  defp enroll(socket) do
    case Identity.enroll(socket.assigns.config) do
      {:ok, identity} ->
        Logger.info("enrolled as agent #{identity.agent_id}")
        {:noreply, socket |> assign(identity: identity) |> open()}

      {:error, message} ->
        Logger.error(message)
        Process.send_after(self(), :identify, 30_000)
        {:noreply, socket}
    end
  end

  defp open(socket) do
    %{config: config, identity: identity} = socket.assigns
    headers = Auth.connect_headers(identity.agent_id, identity.private_key) |> Enum.to_list()

    with :ok <- Config.check_url(config),
         {:ok, socket} <-
           connect(socket,
             uri: socket_uri(config.url),
             headers: headers,
             reconnect_after_msec: @backoff,
             rejoin_after_msec: @rejoin_backoff
           ) do
      socket
    else
      {:error, reason} ->
        Logger.error("can't connect: #{inspect(reason)}")
        socket
    end
  end

  @doc false
  # CREW_URL is the socket URL itself: wss://<host>/agent/websocket (§5.3).
  def socket_uri(url) do
    uri = URI.parse(url)
    path = if uri.path in [nil, "", "/"], do: "/agent/websocket", else: uri.path
    URI.to_string(%{uri | path: path, query: "vsn=2.0.0"})
  end

  @impl Slipstream
  def handle_connect(socket) do
    topic = "agent:" <> socket.assigns.identity.agent_id
    {:ok, socket |> assign(topic: topic, attempt: 0) |> join(topic, join_payload())}
  end

  # Built fresh for every join and rejoin: the operations in flight change.
  defp join_payload do
    config = Config.get()

    %{
      agent_version: Identity.version(),
      protocol_version: CrewProtocol.version(),
      box_name: config.box_name,
      os: to_string(elem(:os.type(), 1)),
      arch: arch(),
      boot_id: CrewAgent.Boot.id(),
      in_flight: Ops.in_flight()
    }
    |> CrewProtocol.dump_join()
  end

  defp arch do
    if :erlang.system_info(:system_architecture) |> to_string() |> String.contains?("aarch64"),
      do: "arm64",
      else: "x64"
  end

  @impl Slipstream
  def handle_join(topic, _reply, socket) do
    Logger.info("joined #{topic}")
    Outbox.attach(self())
    Reporter.report_now()
    VMs.connected()
    {:ok, assign(socket, joined: true)}
  end

  @impl Slipstream
  def handle_message(_topic, "command", wire, socket) do
    case Command.from_wire(wire) do
      {:ok, cmd} ->
        Logger.info("command #{cmd.type} #{cmd.op_id}")
        Ops.submit(cmd)

      {:error, errors} ->
        Logger.warning("rejected an invalid command: #{inspect(errors)}")
        reject(wire, errors)
    end

    {:ok, socket}
  end

  def handle_message(_topic, event, _payload, socket) do
    Logger.debug("ignoring #{event}")
    {:ok, socket}
  end

  # A command that fails validation still gets a result, if it has an
  # op_id the control plane can match it to.
  defp reject(%{"op_id" => op_id}, errors) when is_binary(op_id) do
    message = "invalid command: #{inspect(errors)}" |> String.slice(0, 1000)

    case Event.new("op.result", %{
           op_id: op_id,
           status: "error",
           error: %{code: "invalid_command", message: message}
         }) do
      {:ok, event} -> Outbox.push(event)
      {:error, _} -> :ok
    end
  end

  defp reject(_, _), do: :ok

  @impl Slipstream
  def handle_info({:outbox_deliver, event, ack_id}, socket) do
    case safe_push(socket, event) do
      {:ok, ref} when is_integer(ack_id) ->
        {:noreply, update(socket, :acks, &Map.put(&1, ref, ack_id))}

      {:ok, _ref} ->
        {:noreply, socket}

      {:error, reason} ->
        Logger.warning("couldn't push #{event.type}: #{inspect(reason)}")
        {:noreply, socket}
    end
  end

  def handle_info(:identify, socket), do: handle_continue(:identify, socket)

  def handle_info(:reconnect, socket), do: {:noreply, open(socket)}

  def handle_info(message, socket) do
    Logger.debug("unexpected message: #{inspect(message)}")
    {:noreply, socket}
  end

  @impl Slipstream
  def handle_reply(ref, reply, socket) do
    {ack_id, acks} = Map.pop(socket.assigns.acks, ref)

    case {ack_id, reply} do
      {nil, _} ->
        :ok

      {ack_id, {:ok, _}} ->
        Outbox.ack(ack_id)

      {ack_id, :ok} ->
        Outbox.ack(ack_id)

      # A refusal is final: sending the same result again gets the same
      # answer, on every reconnect, forever.
      {ack_id, other} ->
        Logger.warning("control plane rejected an event: #{inspect(other)}")
        Outbox.ack(ack_id)
    end

    {:ok, assign(socket, acks: acks)}
  end

  @impl Slipstream
  def handle_disconnect(reason, socket) do
    Outbox.detach()
    attempt = socket.assigns.attempt
    delay = Enum.at(@backoff, attempt, List.last(@backoff)) + :rand.uniform(1_000)
    Logger.warning("disconnected (#{describe(reason)}); reconnecting in #{div(delay, 1000)}s")
    Process.send_after(self(), :reconnect, delay)
    {:ok, assign(socket, attempt: attempt + 1, acks: %{}, joined: false)}
  end

  @impl Slipstream
  def handle_topic_close(topic, reason, socket) do
    Outbox.detach()
    Logger.warning("left #{topic}: #{inspect(reason)}")
    # The socket rejoin returns carries the attempt count, which is what
    # makes the retries back off.
    {:ok, socket} = rejoin(socket, topic, join_payload())
    {:ok, assign(socket, joined: false)}
  end

  # The event is pushed as JSON by Slipstream's connection process: one
  # invalid UTF-8 byte would raise there and take this process with it,
  # again on every reconnect for a result. Scrubbed here as a last line.
  defp safe_push(socket, event) do
    push(socket, socket.assigns.topic, "event", Event.to_wire(event))
  catch
    kind, reason ->
      {:error, {:push_failed, Exception.format_banner(kind, reason)}}
  end

  defp describe({:upgrade_failure, %{status_code: status}}), do: "refused with HTTP #{status}"
  defp describe(reason), do: inspect(reason)
end
