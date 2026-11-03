defmodule Crew.Boxes do
  @moduledoc """
  Boxes and their agents (§10.2, §8.3): enrollment with single-use join
  tokens, the keys agents sign their connects with, online status, and
  capabilities, which are pinned at enrollment.

  An admin creates a join token for a named box of one of the four
  types. The agent generates its own keypair and enrolls with the
  token, which is then spent; only the public key is stored.

  **Capability pinning (§19.2 #6):** a later report that changes
  `guest_arch` or `driver`, or moves `vcpus`, `memory_mib` or
  `vm_area_mib` by more than 10%, puts the box in `needs_approval` until
  an admin accepts it, so a stolen key can't claim a huge box and draw
  in the fleet's jobs. Placement uses the pinned values.
  """
  import Ecto.Query

  alias Crew.{Activity, Audit, Repo, Scope}
  alias Crew.Boxes.{Box, JoinToken}

  @token_ttl 3600
  @drift 0.10

  # -- reads --------------------------------------------------------------------

  def list, do: Repo.all(from b in Box, where: is_nil(b.revoked_at), order_by: b.name)
  def get!(id), do: Repo.get!(Box, id)
  def get(id), do: Repo.get(Box, id)
  def get_by_name(name), do: Repo.get_by(Box, name: name)

  def subscribe, do: Phoenix.PubSub.subscribe(Crew.PubSub, "boxes")
  def subscribe(box_id), do: Phoenix.PubSub.subscribe(Crew.PubSub, "box:#{box_id}")

  defp changed(%Box{id: id} = box) do
    Phoenix.PubSub.broadcast(Crew.PubSub, "boxes", {:box_changed, id})
    Phoenix.PubSub.broadcast(Crew.PubSub, "box:#{id}", {:box_changed, id})
    box
  end

  # -- enrollment ----------------------------------------------------------------

  @doc """
  Creates a join token for a box. Returns the raw token, shown once; only
  its hash is stored.
  """
  def create_join_token(%Scope{} = scope, attrs) do
    types = %{
      box_name: :string,
      box_type: :string,
      data_disk: :string,
      tailscale_auth_key: :string
    }

    changeset =
      {%{}, types}
      |> Ecto.Changeset.cast(attrs, Map.keys(types))
      |> Ecto.Changeset.validate_required([:box_name, :box_type])
      |> Ecto.Changeset.validate_change(:box_name, fn :box_name, name ->
        if CrewProtocol.Names.box_name?(name),
          do: [],
          else: [box_name: "must be a lowercase DNS label of at most 40 characters"]
      end)
      |> Ecto.Changeset.validate_inclusion(:box_type, Box.types())
      |> Ecto.Changeset.validate_format(:data_disk, ~r"\A/dev/[a-z0-9/]{1,40}\z",
        message: "must be a device like /dev/sdb"
      )

    cond do
      not Scope.admin?(scope) ->
        {:error, :unauthorized}

      not changeset.valid? ->
        {:error, %{changeset | action: :insert}}

      true ->
        data = Ecto.Changeset.apply_changes(changeset)
        raw = "cj_" <> (32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false))

        Repo.insert!(%JoinToken{
          token_hash: hash(raw),
          box_name: data.box_name,
          box_type: data.box_type,
          data_disk: data[:data_disk],
          tailscale_auth_key: data[:tailscale_auth_key],
          created_by_id: scope.user.id,
          expires_at: DateTime.add(DateTime.utc_now(), @token_ttl)
        })

        Audit.log(scope, "box.join_token", {"Box", data.box_name}, %{"type" => data.box_type})
        {:ok, raw}
    end
  end

  @doc """
  Enrolls an agent: spends the join token and records the agent's public
  key. Re-enrolling a live box's name replaces its key; a revoked name
  stays revoked.
  """
  def enroll(raw_token, attrs) when is_binary(raw_token) do
    now = DateTime.utc_now()

    Repo.transact(fn ->
      with %JoinToken{} = token <- Repo.get_by(JoinToken, token_hash: hash(raw_token)),
           true <- is_nil(token.used_at) and DateTime.compare(token.expires_at, now) == :gt,
           {:ok, public_key} <- decode_key(attrs["public_key"]),
           {:ok, box} <- upsert_enrolled_box(token, public_key, attrs) do
        token |> Ecto.Changeset.change(used_at: now, box_id: box.id) |> Repo.update!()
        Audit.log(nil, "box.enroll", box, %{"agent_version" => attrs["agent_version"]})
        disconnect(box)
        Activity.record("box_joined", "#{box.name} enrolled", box_id: box.id)
        {:ok, changed(box)}
      else
        {:error, :bad_key} -> {:error, :bad_key}
        _ -> {:error, :invalid_token}
      end
    end)
  end

  def enroll(_, _), do: {:error, :invalid_token}

  defp upsert_enrolled_box(token, public_key, attrs) do
    box = get_by_name(token.box_name) || %Box{name: token.box_name}

    if box.revoked_at do
      {:error, :revoked}
    else
      box
      |> Ecto.Changeset.change(
        type: box.type || token.box_type,
        public_key: public_key,
        key_fingerprint: CrewProtocol.Auth.fingerprint(public_key),
        os: attrs["os"],
        agent_version: attrs["agent_version"]
      )
      |> Repo.insert_or_update()
    end
  end

  defp decode_key(key) when is_binary(key) do
    case Base.decode64(key) do
      {:ok, raw} when byte_size(raw) == 32 -> {:ok, raw}
      _ -> {:error, :bad_key}
    end
  end

  defp decode_key(_), do: {:error, :bad_key}

  defp hash(raw), do: :crypto.hash(:sha256, raw)

  @doc "The public key an agent's connect headers must verify against (§10.2)."
  def public_key(agent_id) do
    with {:ok, id} <- Ecto.UUID.cast(agent_id),
         %Box{revoked_at: nil, public_key: key} when is_binary(key) <- Repo.get(Box, id) do
      {:ok, key}
    else
      _ -> :error
    end
  end

  # -- the agent's link ----------------------------------------------------------

  @doc "Records a join: the agent's version, protocol and boot."
  def agent_joined(%Box{} = box, join) do
    now = DateTime.utc_now()

    box
    |> Ecto.Changeset.change(
      agent_version: join.agent_version,
      protocol_version: join.protocol_version,
      os: join.os,
      boot_id: join.boot_id,
      online_at: now,
      last_seen_at: now,
      offline_at: nil
    )
    |> Repo.update!()
    |> changed()
  end

  @doc "The agent's channel closed."
  def agent_left(box_id) do
    now = DateTime.utc_now()

    Repo.update_all(from(b in Box, where: b.id == ^box_id),
      set: [offline_at: now, last_seen_at: now]
    )

    with %Box{} = box <- get(box_id), do: changed(box)
    :ok
  end

  def seen(box_id) do
    Repo.update_all(from(b in Box, where: b.id == ^box_id),
      set: [last_seen_at: DateTime.utc_now()]
    )
  end

  # -- capabilities (§8.3) ---------------------------------------------------------

  @doc """
  Stores a `box.capabilities` report. The first is pinned; a later one
  that drifts too far sets `needs_approval`.
  """
  def report_capabilities(%Box{} = box, caps) when is_map(caps) do
    caps = stringify(caps)
    pinned = box.pinned_capabilities
    was_waiting = box.needs_approval

    # The baseline only moves when an admin accepts a report, so a box
    # can't creep past it a few percent at a time. Placement uses the
    # smaller of the two (Crew.Scheduler).
    {pinned, needs_approval} =
      cond do
        is_nil(pinned) -> {caps, false}
        drifted?(pinned, caps) -> {pinned, true}
        true -> {pinned, box.needs_approval}
      end

    box =
      box
      |> Ecto.Changeset.change(
        capabilities: caps,
        pinned_capabilities: pinned,
        needs_approval: needs_approval,
        driver: pinned["driver"],
        guest_arch: pinned["guest_arch"],
        firewall_ok: caps["firewall_ok"] == true,
        virtualized: caps["virtualized"] == true,
        hypervisor_vendor: caps["hypervisor_vendor"],
        sleep_disabled: caps["sleep_disabled"]
      )
      |> Repo.update!()

    if needs_approval and not was_waiting,
      do:
        Activity.record(
          "box_needs_approval",
          "#{box.name}'s capabilities changed; an admin has to accept them before it gets jobs",
          box_id: box.id
        )

    {:ok, changed(box)}
  end

  defp drifted?(pinned, caps) do
    pinned["guest_arch"] != caps["guest_arch"] or pinned["driver"] != caps["driver"] or
      Enum.any?(~w(vcpus memory_mib vm_area_mib), &moved?(pinned[&1], caps[&1]))
  end

  defp moved?(a, b) when is_number(a) and is_number(b) and a > 0, do: abs(b - a) / a > @drift
  defp moved?(a, b), do: a != b

  @doc "An admin accepts the box's reported capabilities (audited)."
  def approve_capabilities(%Scope{} = scope, %Box{} = box) do
    if Scope.admin?(scope) do
      box =
        box
        |> Ecto.Changeset.change(
          pinned_capabilities: box.capabilities,
          needs_approval: false,
          driver: box.capabilities["driver"],
          guest_arch: box.capabilities["guest_arch"]
        )
        |> Repo.update!()

      Audit.log(scope, "box.capabilities_approved", box, %{
        "vcpus" => box.capabilities["vcpus"],
        "memory_mib" => box.capabilities["memory_mib"]
      })

      Activity.record("box_approved", "#{box.name}'s new capabilities were accepted",
        box_id: box.id
      )

      {:ok, changed(box)}
    else
      {:error, :unauthorized}
    end
  end

  defp stringify(map), do: Map.new(map, fn {k, v} -> {to_string(k), v} end)

  # -- reboots (§12.1) -------------------------------------------------------------

  @doc "Stores a `box.reboot` report."
  def report_reboot(%Box{} = box, r) do
    newly = r.required and not box.reboot_required

    box =
      box
      |> Ecto.Changeset.change(
        reboot_required: r.required,
        reboot_packages: r.packages,
        can_restart: r.can_restart,
        os_version: r[:os_version] || box.os_version,
        cache_vm_reboot: r[:cache_vm] && stringify(r.cache_vm)
      )
      |> Repo.update!()

    if newly,
      do:
        Activity.record(
          "box_reboot_required",
          "#{box.name} needs a reboot (#{Enum.join(box.reboot_packages, ", ")})",
          box_id: box.id
        )

    changed(box)
  end

  # -- VM outcomes (§8.6) --------------------------------------------------------

  @quarantine_after 3
  @quarantine_s 300

  @doc """
  A VM on the box failed before `idle` for a reason that counts against
  the box. The third in a row quarantines it for 5 minutes.
  """
  def vm_failed(box_id) do
    {_, [n]} =
      Repo.update_all(from(b in Box, where: b.id == ^box_id, select: b.consecutive_failures),
        inc: [consecutive_failures: 1]
      )

    if n >= @quarantine_after do
      until = DateTime.add(DateTime.utc_now(), @quarantine_s, :second)

      Repo.update_all(from(b in Box, where: b.id == ^box_id),
        set: [quarantined_until: until, consecutive_failures: 0]
      )

      box = get!(box_id)

      Activity.record(
        "box_quarantined",
        "#{box.name} failed #{n} VMs in a row; it gets no new VMs for 5 minutes",
        box_id: box.id
      )

      changed(box)
    end

    :ok
  end

  @doc "A VM on the box reached `idle`: the failure count clears."
  def vm_succeeded(box_id) do
    Repo.update_all(from(b in Box, where: b.id == ^box_id and b.consecutive_failures != 0),
      set: [consecutive_failures: 0]
    )

    :ok
  end

  @doc "A VM on the box took a job from `repo_id`, for placement ranking (§8.3)."
  def ran_repo(box_id, repo_id) do
    with %Box{} = box <- get(box_id) do
      ran = Map.put(box.last_repo_ran_at || %{}, repo_id, System.system_time(:millisecond))
      box |> Ecto.Changeset.change(last_repo_ran_at: ran) |> Repo.update!()
    end

    :ok
  end

  # -- revoking ------------------------------------------------------------------

  @doc "Revokes a box: its key is deleted and its socket dropped at once."
  def revoke(%Scope{} = scope, %Box{} = box) do
    if Scope.admin?(scope) do
      box =
        box
        |> Ecto.Changeset.change(revoked_at: DateTime.utc_now(), public_key: nil)
        |> Repo.update!()

      Audit.log(scope, "box.revoke", box)
      Activity.record("box_revoked", "#{box.name} was revoked", box_id: box.id)
      disconnect(box)
      Crew.VMs.box_revoked(box.id)
      {:ok, changed(box)}
    else
      {:error, :unauthorized}
    end
  end

  # Drops the agent's socket (CrewWeb.AgentSocket.id/1).
  defp disconnect(%Box{id: id}),
    do: Phoenix.Channel.Server.broadcast(Crew.PubSub, "agent_socket:#{id}", "disconnect", %{})
end
