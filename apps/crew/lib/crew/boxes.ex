defmodule Crew.Boxes do
  @moduledoc """
  Boxes and their agents (§10.2, §8.3): enrollment with single-use join
  tokens, the keys agents sign their connects with, online status, and
  capabilities, which are pinned at enrollment.

  An admin creates a join token for a named box of one of the four
  types. The agent generates its own keypair and enrolls with the
  token, which is then spent; only the public key is stored.

  **Capability pinning (§19.2 #6):** the first report is pinned and puts
  the box in `needs_approval` until an admin accepts it, so whoever spends
  a join token can't claim a huge box and draw in the fleet's jobs. So
  does a later report that changes `guest_arch` or `driver`, or moves
  `vcpus`, `memory_mib` or `vm_area_mib` by more than 10%, so a stolen
  key can't either. Placement uses the pinned values.
  """
  import Ecto.Query

  alias Crew.{Activity, Audit, Repo, Scope}
  alias Crew.Agents.Releases
  alias Crew.Boxes.{Box, Flatcar, JoinToken}

  @token_ttl 3600
  @drift 0.10

  # -- reads --------------------------------------------------------------------

  def list, do: Repo.all(from b in Box, where: is_nil(b.revoked_at), order_by: b.name)
  def get!(id), do: Repo.get!(Box, id)
  def get(id), do: Repo.get(Box, id)
  def get_by_name(name), do: Repo.get_by(Box, name: name)

  @blocking ~w(offline not_reported firewall needs_approval quarantined draining)a

  @doc """
  What's wrong with a box, or worth knowing, most serious first. The
  first six keep placement off it (§8.3, `blocking?/1`): `:offline`,
  `:not_reported` (no capabilities yet), `:firewall` (not verified),
  `:needs_approval`, `:quarantined` and `:draining`. Then `:sleep_on`
  (a Mac whose jobs pause when it sleeps) and `:reboot_required`.
  """
  def issues(box, online?, now \\ DateTime.utc_now()) do
    reported? = box.pinned_capabilities != nil

    [
      not online? && :offline,
      not reported? && :not_reported,
      (reported? and not box.firewall_ok) && :firewall,
      box.needs_approval && :needs_approval,
      (box.quarantined_until != nil and DateTime.compare(box.quarantined_until, now) == :gt) &&
        :quarantined,
      Box.draining?(box) && :draining,
      box.sleep_disabled == false && :sleep_on,
      box.reboot_required && :reboot_required
    ]
    |> Enum.filter(& &1)
  end

  @doc "Whether placement skips a box with this issue (§8.3)."
  def blocking?(issue), do: issue in @blocking

  def subscribe, do: Phoenix.PubSub.subscribe(Crew.PubSub, "boxes")
  def subscribe(box_id), do: Phoenix.PubSub.subscribe(Crew.PubSub, "box:#{box_id}")

  defp changed(%Box{id: id} = box) do
    broadcast_changed(id)
    box
  end

  @doc "Tells the box's pages it changed."
  def broadcast_changed(id) do
    Phoenix.PubSub.broadcast(Crew.PubSub, "boxes", {:box_changed, id})
    Phoenix.PubSub.broadcast(Crew.PubSub, "box:#{id}", {:box_changed, id})
  end

  # -- enrollment ----------------------------------------------------------------

  @doc """
  Creates a join token for a box. Returns the raw token, shown once; only
  its hash is stored.

  For a Flatcar box (§12.2) it also keeps what the box's Ignition needs:
  on `linux-metal`, its disks (the OS disk, and the data disk with the
  `separate` layout; `one`, the default, puts `/srv/crew` on the OS
  disk), a break-glass SSH key for `core`, and a Tailscale auth key the
  admin pasted (stored encrypted, and forgotten at enrollment).
  """
  def create_join_token(%Scope{} = scope, attrs) do
    types = %{
      box_name: :string,
      box_type: :string,
      disk_layout: :string,
      uplink: :string,
      extra_blocked: :string,
      os_disk: :string,
      data_disk: :string,
      ssh_keys: :string,
      tailscale_auth_key: :string
    }

    changeset =
      {%{}, types}
      |> Ecto.Changeset.cast(attrs, Map.keys(types))
      |> Ecto.Changeset.validate_required([:box_name, :box_type])
      |> Ecto.Changeset.validate_change(:box_name, &validate_join_name/2)
      |> Ecto.Changeset.validate_inclusion(:box_type, Box.types())
      |> validate_network()
      |> validate_disks()
      |> Ecto.Changeset.validate_change(:ssh_keys, fn :ssh_keys, keys ->
        if Enum.all?(split_keys(keys), &Flatcar.ssh_key?/1),
          do: [],
          else: [ssh_keys: "must be SSH public keys, one per line"]
      end)
      |> Ecto.Changeset.validate_format(:tailscale_auth_key, ~r/\Atskey-[A-Za-z0-9_-]+\z/,
        message: "must be a Tailscale auth key (tskey-...)"
      )

    cond do
      not Scope.admin?(scope) ->
        {:error, :unauthorized}

      not changeset.valid? ->
        {:error, %{changeset | action: :insert}}

      true ->
        data = Ecto.Changeset.apply_changes(changeset)
        raw = "cj_" <> (32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false))

        flatcar? = data.box_type in Flatcar.types()
        metal? = data.box_type == "linux-metal"
        layout = if metal?, do: disk_layout(data)
        network = if flatcar?, do: data, else: %{}

        Repo.insert!(%JoinToken{
          token_hash: hash(raw),
          box_name: data.box_name,
          box_type: data.box_type,
          disk_layout: layout,
          uplink: network[:uplink],
          extra_blocked: network[:extra_blocked],
          os_disk: if(metal?, do: data[:os_disk]),
          data_disk: if(layout == "separate", do: data[:data_disk]),
          ssh_keys: if(flatcar?, do: split_keys(data[:ssh_keys]), else: []),
          tailscale_auth_key: if(flatcar?, do: data[:tailscale_auth_key]),
          created_by_id: scope.user.id,
          expires_at: DateTime.add(DateTime.utc_now(), @token_ttl)
        })

        Audit.log(scope, "box.join_token", {"Box", data.box_name}, %{"type" => data.box_type})
        {:ok, raw}
    end
  end

  defp validate_join_name(:box_name, name) do
    cond do
      not CrewProtocol.Names.box_name?(name) ->
        [box_name: "must be a lowercase DNS label of at most 40 characters"]

      Box.retired?(get_by_name(name)) ->
        [box_name: "belongs to a retired mac-vm worker. Choose a new name for its replacement."]

      match?(%Box{revoked_at: %DateTime{}}, get_by_name(name)) ->
        [box_name: "belongs to a revoked box. Choose a new name for its replacement."]

      # A token for a box that's there would replace its key, and the box
      # would keep its repos' trust (allowed_boxes) and its capacity.
      get_by_name(name) ->
        [box_name: "belongs to a box that's already enrolled. Choose a new name for a new box."]

      true ->
        []
    end
  end

  defp validate_network(changeset) do
    changeset
    |> Ecto.Changeset.validate_change(:uplink, fn key, value ->
      if Flatcar.uplink?(value), do: [], else: [{key, "must be a usable uplink interface"}]
    end)
    |> Ecto.Changeset.validate_change(:extra_blocked, fn key, value ->
      if Flatcar.blocked_ranges?(value),
        do: [],
        else: [{key, "must be comma-separated IPv4 addresses or CIDRs"}]
    end)
  end

  defp disk_layout(data), do: data[:disk_layout] || "one"

  # linux-metal's disks. The OS disk is a by-id link, the same disk under
  # the same name in every live image and at first boot: with one disk the
  # Ignition partitions it, and either way flatcar-install writes over
  # whatever the box page's command names.
  defp validate_disks(changeset) do
    if Ecto.Changeset.get_field(changeset, :box_type) == "linux-metal" do
      changeset
      |> Ecto.Changeset.validate_inclusion(:disk_layout, Flatcar.disk_layouts())
      |> Ecto.Changeset.validate_required([:os_disk],
        message: "is needed for a dedicated Linux machine"
      )
      |> Ecto.Changeset.validate_change(:os_disk, fn :os_disk, disk ->
        if Flatcar.os_disk?(disk), do: [], else: [os_disk: "must be a /dev/disk/by-id/... link"]
      end)
      |> then(&validate_layout(&1, disk_layout(Ecto.Changeset.apply_changes(&1))))
    else
      changeset
    end
  end

  defp validate_layout(changeset, "one"), do: changeset

  defp validate_layout(changeset, _separate) do
    os_disk = Ecto.Changeset.get_field(changeset, :os_disk)

    changeset
    |> Ecto.Changeset.validate_required([:data_disk],
      message: "is needed with a separate data disk"
    )
    |> Ecto.Changeset.validate_change(:data_disk, fn :data_disk, disk ->
      cond do
        not Flatcar.data_disk?(disk) ->
          [data_disk: "must be a device like /dev/sdb or /dev/disk/by-id/..."]

        disk == os_disk ->
          [data_disk: "must be another disk than the OS disk"]

        true ->
          []
      end
    end)
  end

  # SSH keys, given as a list or one per line.
  defp split_keys(keys) when is_list(keys),
    do: keys |> Enum.filter(&is_binary/1) |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))

  defp split_keys(keys) when is_binary(keys), do: keys |> String.split(~r/\R/) |> split_keys()
  defp split_keys(_), do: []

  @doc """
  Enrolls an agent: spends the join token and records the agent's public
  key. A token only makes a new box: one for a name that's already
  enrolled (or revoked, or retired) is refused.

  The token is claimed with one update that only matches it unused and
  unexpired, in the same transaction as the box's key: of enrollments
  racing for one token, exactly one gets it (the others wait on the
  row, then match nothing). Anything that fails after the claim rolls it
  back, so a bad key doesn't spend the token.
  """
  def enroll(raw_token, attrs) when is_binary(raw_token) do
    now = DateTime.utc_now()

    Repo.transact(fn ->
      with :ok <- lock_name(raw_token),
           {:ok, token} <- claim_token(raw_token, now),
           {:ok, public_key} <- decode_key(attrs["public_key"]),
           {:ok, box} <- upsert_enrolled_box(token, public_key, attrs) do
        token |> Ecto.Changeset.change(box_id: box.id) |> Repo.update!()
        spend_siblings(token, now)

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

  # Every token for the name the token's for, locked in one order before
  # any is claimed: enrollments for one name then go one after another,
  # and the one that wins spends the rest in its own transaction (Postgres;
  # SQLite has one writer at a time anyway).
  defp lock_name(raw) do
    with %JoinToken{box_name: name} <- Repo.get_by(JoinToken, token_hash: hash(raw)) do
      if Repo.database() == "postgres" do
        Repo.all(
          from(t in JoinToken,
            where: t.box_name == ^name,
            order_by: t.id,
            lock: "FOR UPDATE",
            select: t.id
          )
        )
      end

      :ok
    end
  end

  # Other unused tokens for the box's name can't enroll it now, so they
  # can't fetch its first-boot config, with a Tailscale key, either.
  defp spend_siblings(token, now) do
    Repo.update_all(
      from(t in JoinToken,
        where: t.box_name == ^token.box_name and t.id != ^token.id and is_nil(t.used_at)
      ),
      set: [used_at: now, tailscale_auth_key: nil]
    )
  end

  # Marks the token used if, and only if, it's unused and unexpired, and
  # forgets its Tailscale key, which was for this box's first boot.
  defp claim_token(raw, now) do
    query =
      from t in JoinToken,
        where:
          t.token_hash == ^hash(raw) and is_nil(t.used_at) and t.expires_at > ^now and
            t.box_type in ^Box.types(),
        select: t

    case Repo.update_all(query, set: [used_at: now, tailscale_auth_key: nil]) do
      {1, [token]} -> {:ok, token}
      _ -> {:error, :invalid_token}
    end
  end

  # -- Flatcar boxes (§12.2) -------------------------------------------------------

  @doc """
  The first-boot Ignition for the Flatcar box `raw_token` enrolls, for
  `params["arch"]` (`amd64` or `arm64`), with `params["ssh_keys"]` (the
  launcher's own key, a list or one per line) added to the token's
  break-glass key for `core`. Returns `{:ok, config, box_name}`.

  It embeds the token, which stays good for the agent's own enrollment
  (that spends it), the release key, the newest release for the arch,
  and the box's Tailscale key: the one pasted on Add box, or one minted
  with the OAuth client the first time it's asked for and kept for the
  next ask. See `Crew.Boxes.Flatcar`.
  """
  def flatcar_ignition(raw_token, params) do
    arch = params["arch"]

    with true <- arch in Flatcar.arches() || {:error, :bad_arch},
         %JoinToken{} = token <- valid_join_token(raw_token) || {:error, :invalid_token},
         true <- token.box_type in Flatcar.types() || {:error, :not_flatcar},
         {:ok, release} <- Releases.install_set(Flatcar.target(arch)),
         {:ok, ts_key} <- box_tailscale_key(token),
         {:ok, config} <-
           Flatcar.ignition(%{
             mode: :provision,
             name: token.box_name,
             type: token.box_type,
             arch: arch,
             disk_layout: token.disk_layout,
             uplink: token.uplink,
             extra_blocked: token.extra_blocked,
             os_disk: token.os_disk,
             data_disk: token.data_disk,
             ssh_keys: token.ssh_keys ++ split_keys(params["ssh_keys"]),
             url: Crew.Config.base_url(),
             join_token: raw_token,
             tailscale_auth_key: ts_key,
             release: %{
               version: release.version,
               agent: artifact(release.agent),
               cache: artifact(release.cache)
             },
             release_key: Crew.Config.release_public_key(),
             dev: Crew.Config.dev?()
           }) do
      {:ok, config, token.box_name}
    end
  end

  @doc """
  The cache VM's first-boot Ignition for a `mac-vz` box's join token
  (§12.3, §15.6), and the management token it carries: the box's
  installer (install-macos.sh, through the cache launcher's `--role
  cache`) gives the same token to the agent. A new token each time; the
  control plane keeps none of them, and the join token stays good for
  the agent's enrollment.
  """
  def cachevm_ignition(raw_token, params) do
    with %JoinToken{} = token <- valid_join_token(raw_token) || {:error, :invalid_token},
         true <- token.box_type == "mac-vz" || {:error, :not_mac_vz},
         {:ok, release} <- Releases.install_set(Flatcar.target("arm64")),
         mgmt_token = "cm_" <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false),
         {:ok, config} <-
           Flatcar.cachevm_ignition(%{
             mode: :provision,
             arch: "arm64",
             ssh_keys: token.ssh_keys ++ split_keys(params["ssh_keys"]),
             mgmt_token: mgmt_token,
             release: %{version: release.version, cache: artifact(release.cache)},
             release_key: Crew.Config.release_public_key()
           }) do
      {:ok, config, token.box_name, mgmt_token}
    end
  end

  defp artifact(release),
    do: %{url: Releases.url(release), sha256: release.sha256, signature: release.signature}

  defp valid_join_token(raw) when is_binary(raw),
    do: valid_join_token_row(Repo.get_by(JoinToken, token_hash: hash(raw)))

  defp valid_join_token(_), do: nil

  defp valid_join_token_row(%JoinToken{used_at: nil} = token) do
    if token.box_type in Box.types() and
         DateTime.compare(token.expires_at, DateTime.utc_now()) == :gt and
         is_nil(get_by_name(token.box_name)),
       do: token
  end

  defp valid_join_token_row(_), do: nil

  defp box_tailscale_key(%JoinToken{tailscale_auth_key: key}) when is_binary(key), do: {:ok, key}

  defp box_tailscale_key(token),
    do: if(Crew.Tailscale.configured?(), do: mint_box_key(token), else: {:ok, nil})

  # Minted outside a transaction (it's a call to Tailscale), then kept
  # only if no other request stored one first: a key minted by a request
  # that lost the race expires unused.
  defp mint_box_key(token) do
    expiry = max(DateTime.diff(token.expires_at, DateTime.utc_now()), 600)

    case Crew.Tailscale.create_box_auth_key(token.box_name, expiry) do
      {:ok, key} ->
        # Only on a token that's still good: the box may have enrolled (or
        # a sibling may have) while Tailscale made it.
        Repo.update_all(
          from(t in JoinToken,
            where: t.id == ^token.id and is_nil(t.tailscale_auth_key) and is_nil(t.used_at)
          ),
          set: [tailscale_auth_key: key]
        )

        case valid_join_token_row(Repo.reload!(token)) do
          %JoinToken{tailscale_auth_key: stored} when is_binary(stored) -> {:ok, stored}
          _ -> {:error, :invalid_token}
        end

      {:error, reason} ->
        {:error, {:tailscale, reason}}
    end
  end

  defp enrollment(id) do
    Repo.one(
      from t in JoinToken,
        where: t.box_id == ^id,
        order_by: [desc: t.used_at, desc: t.inserted_at],
        limit: 1
    )
  end

  @doc """
  The disks a `linux-metal` box was added with, from the join token that
  enrolled it last: `%{disk_layout: "one" | "separate", os_disk: _,
  data_disk: _}`. A token from before layouts (#140) had a data disk of
  its own.
  """
  def disks(%Box{id: id}) do
    token = enrollment(id)

    %{
      disk_layout: (token && token.disk_layout) || "separate",
      os_disk: token && token.os_disk,
      data_disk: token && token.data_disk
    }
  end

  @doc "Applies the reprovision form's disk overrides to the enrolled layout."
  def reprovision_disks(disks, params) do
    %{
      disks
      | os_disk: present(params["os_disk"]) || disks.os_disk,
        data_disk: present(params["data_disk"]) || disks.data_disk
    }
  end

  @doc """
  The reprovision Ignition for a Flatcar box (§12.2): no join token, no
  Tailscale key, for a new OS disk over the box's data. A `linux-metal`
  box keeps the layout it was added with; its OS disk and data disk are
  `params["os_disk"]` and `params["data_disk"]`, or the ones it was added
  with. Admins only; audited.
  """
  def reprovision_ignition(%Scope{} = scope, %Box{} = box, params) do
    cond do
      not Scope.admin?(scope) ->
        {:error, :unauthorized}

      box.type not in Flatcar.types() ->
        {:error, :not_flatcar}

      true ->
        token = enrollment(box.id)
        disks = if box.type == "linux-metal", do: reprovision_disks(disks(box), params), else: %{}

        with {:ok, config} <-
               Flatcar.ignition(%{
                 mode: :reprovision,
                 name: box.name,
                 type: box.type,
                 arch: params["arch"],
                 disk_layout: disks[:disk_layout],
                 uplink: token && token.uplink,
                 extra_blocked: token && token.extra_blocked,
                 os_disk: disks[:os_disk],
                 data_disk: disks[:data_disk],
                 ssh_keys: split_keys(params["ssh_keys"]),
                 # Root's copy, for the updates' root half (§20.2).
                 release_key: Crew.Config.release_public_key()
               }) do
          Audit.log(scope, "box.reprovision_ignition", box, %{"arch" => params["arch"]})
          {:ok, config}
        end
    end
  end

  @doc """
  A `mac-vz` box's cache VM's reprovision Ignition (§12.3), for admins:
  no management token (the data disk has it) and the newest linux-arm64
  release, if one is registered, which the new OS disk moves crew_cache
  to.
  """
  def cachevm_reprovision_ignition(%Scope{} = scope, %Box{} = box, params) do
    cond do
      not Scope.admin?(scope) ->
        {:error, :unauthorized}

      box.type != "mac-vz" ->
        {:error, :not_mac_vz}

      true ->
        release =
          case Releases.install_set(Flatcar.target("arm64")) do
            {:ok, r} -> %{version: r.version, cache: artifact(r.cache)}
            _ -> nil
          end

        with {:ok, config} <-
               Flatcar.cachevm_ignition(%{
                 mode: :reprovision,
                 arch: "arm64",
                 ssh_keys: split_keys(params["ssh_keys"]),
                 release: release,
                 release_key: Crew.Config.release_public_key()
               }) do
          Audit.log(scope, "box.cachevm_reprovision_ignition", box, %{
            "version" => release && release.version
          })

          {:ok, config}
        end
    end
  end

  defp present(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp present(_), do: nil

  # A token makes a new box, never another key for one that's there: one
  # minted before the box enrolled with another token can't be used.
  defp upsert_enrolled_box(token, public_key, attrs) do
    if get_by_name(token.box_name) do
      {:error, :taken}
    else
      %Box{name: token.box_name}
      |> Ecto.Changeset.change(
        type: token.box_type,
        public_key: public_key,
        key_fingerprint: CrewProtocol.Auth.fingerprint(public_key),
        os: attrs["os"],
        agent_version: attrs["agent_version"]
      )
      # Two tokens for one name racing: the name's index takes one.
      |> Ecto.Changeset.unique_constraint(:name)
      |> Repo.insert()
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
      arch: join.arch,
      boot_id: join.boot_id,
      online_at: now,
      last_seen_at: now,
      offline_at: nil
    )
    |> Repo.update!()
    |> Crew.Boxes.Reboots.joined()
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
  Stores a `box.capabilities` report. The first is pinned and waits for
  an admin (`needs_approval`); so does a later one that drifts too far.
  """
  def report_capabilities(%Box{} = box, caps) when is_map(caps) do
    caps = stringify(caps)

    {:ok, {box, notice}} =
      Repo.transact(fn ->
        # Read again, locked, so a report and an approval (which reads the
        # same way) can't each work from what the other is replacing.
        box = locked(box.id)
        pinned = box.pinned_capabilities

        # The baseline only moves when an admin accepts a report, so a box
        # can't creep past it a few percent at a time. Placement uses the
        # smaller of the two (Crew.Scheduler).
        {new_pinned, needs_approval} =
          cond do
            # The first report is pinned too, but an admin accepts it
            # before the box gets jobs: whoever spends a join token says
            # what it has.
            is_nil(pinned) -> {caps, true}
            drifted?(pinned, caps) -> {pinned, true}
            true -> {pinned, box.needs_approval}
          end

        updated =
          box
          |> Ecto.Changeset.change(
            capabilities: caps,
            pinned_capabilities: new_pinned,
            needs_approval: needs_approval,
            driver: new_pinned["driver"],
            guest_arch: new_pinned["guest_arch"],
            firewall_ok: caps["firewall_ok"] == true,
            virtualized: caps["virtualized"] == true,
            hypervisor_vendor: caps["hypervisor_vendor"],
            sleep_disabled: caps["sleep_disabled"]
          )
          |> Repo.update!()

        notice =
          cond do
            not needs_approval or box.needs_approval ->
              nil

            is_nil(pinned) ->
              "#{box.name} reported what it has; an admin has to accept it before it gets jobs"

            true ->
              "#{box.name}'s capabilities changed; an admin has to accept them before it gets jobs"
          end

        {:ok, {updated, notice}}
      end)

    if notice, do: Activity.record("box_needs_approval", notice, box_id: box.id)
    {:ok, changed(box)}
  end

  # The box's row, locked for the transaction on Postgres. SQLite has one
  # writer at a time, so a transaction that writes is serialised anyway.
  defp locked(id) do
    query = from(b in Box, where: b.id == ^id)
    query = if Repo.database() == "postgres", do: lock(query, "FOR UPDATE"), else: query
    Repo.one!(query)
  end

  defp drifted?(pinned, caps) do
    pinned["guest_arch"] != caps["guest_arch"] or pinned["driver"] != caps["driver"] or
      Enum.any?(~w(vcpus memory_mib vm_area_mib), &moved?(pinned[&1], caps[&1]))
  end

  defp moved?(a, b) when is_number(a) and is_number(b) and a > 0, do: abs(b - a) / a > @drift
  defp moved?(a, b), do: a != b

  @doc """
  A short digest of the box's last capabilities report, so an admin's
  approval (`approve_capabilities/3`) is for the report they saw.
  """
  def report_digest(%Box{capabilities: caps}) do
    :crypto.hash(:sha256, :erlang.term_to_binary(caps, [:deterministic]))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end

  @doc """
  An admin accepts the box's reported capabilities (audited): the report
  whose `report_digest/1` they saw. One that's been replaced meanwhile
  isn't accepted: `{:error, :stale}`.
  """
  def approve_capabilities(%Scope{} = scope, %Box{} = box, digest) do
    if Scope.admin?(scope) do
      Repo.transact(fn ->
        current = locked(box.id)

        if report_digest(current) == digest,
          do: {:ok, accept_capabilities(scope, current)},
          else: {:error, :stale}
      end)
      |> case do
        # Told once it's committed, so a page that reloads sees it.
        {:ok, box} ->
          Activity.record("box_approved", "#{box.name}'s capabilities were accepted",
            box_id: box.id
          )

          {:ok, changed(box)}

        error ->
          error
      end
    else
      {:error, :unauthorized}
    end
  end

  defp accept_capabilities(scope, box) do
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

    box
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
      |> Crew.Boxes.Reboots.reported(r)

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

    quarantine_at(box_id, n)
  end

  @doc """
  An `image_not_ready` refusal of a VM placed at `placed_at` (§8.6): a
  failure like `vm_failed/1`, but once per batch of placements. The first
  refusal of VMs placed since the last strike counts, in the same
  statement as its mark, and the rest of its batch doesn't.
  """
  def image_refused(box_id, placed_at, now \\ DateTime.utc_now()) do
    case Repo.update_all(
           from(b in Box,
             where:
               b.id == ^box_id and
                 (is_nil(b.image_refused_at) or b.image_refused_at < ^placed_at),
             select: b.consecutive_failures
           ),
           inc: [consecutive_failures: 1],
           set: [image_refused_at: now]
         ) do
      {1, [n]} -> quarantine_at(box_id, n)
      _ -> :ok
    end
  end

  defp quarantine_at(box_id, n) do
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

  # -- admin controls (§17.3) -------------------------------------------------------

  @doc "Drains a box (no new VMs; idle ones are reaped, §8.5), or undrains it. Audited."
  def set_draining(%Scope{} = scope, %Box{} = box, draining?, reason \\ "admin") do
    admin(scope, fn ->
      box =
        box
        |> Ecto.Changeset.change(draining: draining?, drain_reason: if(draining?, do: reason))
        |> Repo.update!()

      Audit.log(scope, if(draining?, do: "box.drain", else: "box.undrain"), box)
      Crew.Scheduler.poke()
      {:ok, changed(box)}
    end)
  end

  @doc "Ends a box's quarantine early (§8.6). Audited."
  def clear_quarantine(%Scope{} = scope, %Box{} = box) do
    admin(scope, fn ->
      box =
        box
        |> Ecto.Changeset.change(quarantined_until: nil, consecutive_failures: 0)
        |> Repo.update!()

      Audit.log(scope, "box.clear_quarantine", box)
      Crew.Scheduler.poke()
      {:ok, changed(box)}
    end)
  end

  @override_fields ~w(allocatable_vcpus_override allocatable_memory_mib_override reserve_vcpus reserve_memory_mib cpu_overcommit max_vms spare_pct)a

  def change_overrides(%Box{} = box, attrs \\ %{}) do
    box
    |> Ecto.Changeset.cast(attrs, @override_fields, empty_values: [""])
    |> Ecto.Changeset.validate_number(:cpu_overcommit,
      greater_than_or_equal_to: 1.0,
      less_than_or_equal_to: 4.0
    )
    |> Ecto.Changeset.validate_number(:reserve_vcpus, greater_than_or_equal_to: 0)
    |> Ecto.Changeset.validate_number(:reserve_memory_mib, greater_than_or_equal_to: 0)
    |> Ecto.Changeset.validate_number(:allocatable_vcpus_override, greater_than: 0)
    |> Ecto.Changeset.validate_number(:allocatable_memory_mib_override, greater_than: 0)
    |> Ecto.Changeset.validate_number(:max_vms, greater_than: 0)
    |> Ecto.Changeset.validate_number(:spare_pct,
      greater_than_or_equal_to: 0,
      less_than_or_equal_to: 100
    )
  end

  @doc "Capacity overrides (§8.3). Audited with what changed."
  def update_overrides(%Scope{} = scope, %Box{} = box, attrs) do
    admin(scope, fn ->
      changeset = change_overrides(box, attrs)

      with {:ok, updated} <- Repo.update(changeset) do
        Audit.log(
          scope,
          "box.overrides",
          updated,
          Map.new(changeset.changes, fn {k, v} -> {to_string(k), v} end)
        )

        Crew.Scheduler.poke()
        {:ok, changed(updated)}
      end
    end)
  end

  @doc """
  Pins the box's agent to `version` (§20.2), or with nil (or "") lets it
  follow the newest release for its target again. Audited. A pin must
  be a version the box's target has; picking another version clears one
  that failed twice. An online box gets the update at once.
  """
  def pin_agent_version(%Scope{} = scope, %Box{} = box, version) do
    admin(scope, fn ->
      version = if version in [nil, ""], do: nil, else: version

      changeset =
        box
        |> Ecto.Changeset.change(desired_agent_version: version)
        |> validate_pin(box)

      changeset =
        if Ecto.Changeset.changed?(changeset, :desired_agent_version),
          do: Ecto.Changeset.put_change(changeset, :failed_agent_version, nil),
          else: changeset

      with {:ok, box} <- Repo.update(changeset) do
        Audit.log(scope, "box.pin_agent_version", box, %{"version" => version})
        Crew.Agents.Updates.maybe_update(box)
        {:ok, changed(box)}
      end
    end)
  end

  defp validate_pin(changeset, box) do
    Ecto.Changeset.validate_change(changeset, :desired_agent_version, fn _, version ->
      case Crew.Agents.Updates.target(box) do
        nil ->
          [desired_agent_version: "the box hasn't joined yet, so its target isn't known"]

        target ->
          if version in Crew.Agents.Releases.versions(target),
            do: [],
            else: [desired_agent_version: "there's no #{version} release for #{target}"]
      end
    end)
  end

  @doc """
  Sends a box the version that failed on it twice again (§20.2), with
  its two tries back. Audited.
  """
  def retry_agent_update(%Scope{} = scope, %Box{} = box) do
    admin(scope, fn ->
      failed = box.failed_agent_version
      box = box |> Ecto.Changeset.change(failed_agent_version: nil) |> Repo.update!()
      Crew.Agents.Updates.forget_failures(box)
      Audit.log(scope, "box.retry_agent_update", box, %{"version" => failed})
      Crew.Agents.Updates.maybe_update(box)
      {:ok, changed(box)}
    end)
  end

  defp admin(scope, fun), do: if(Scope.admin?(scope), do: fun.(), else: {:error, :unauthorized})

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
