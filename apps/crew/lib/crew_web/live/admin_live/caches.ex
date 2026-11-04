defmodule CrewWeb.AdminLive.Caches do
  @moduledoc """
  The Caches page (§17.3): each box cache's last day (hit rate, bytes
  served, store size, top images) with a purge; the enabled hosts; the
  cacheable allowlist, where an entry is added only once an example
  image under it is fetched anonymously (§15.3); and **Rotate CA**
  (§15.4). Admins only; every change is audited by `Crew.Caches`.
  """
  use CrewWeb, :live_view

  alias Crew.{Boxes, Caches, Metrics}
  alias CrewProtocol.Hosts

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Caches.subscribe()

    {:ok,
     socket
     |> assign(:page_title, "Caches")
     |> assign(:entry_form, to_form(%{"entry" => "", "example" => ""}, as: :entry))
     |> load()}
  end

  defp load(socket) do
    boxes =
      for box <- Boxes.list() do
        %{box: box, summary: Caches.box_summary(box.id), store_mib: store_mib(box.id)}
      end

    assign(socket, config: Caches.config(), boxes: boxes)
  end

  defp store_mib(box_id) do
    case Metrics.latest_box(box_id) do
      %{cache_used_mib: mib} -> mib
      _ -> nil
    end
  end

  @impl true
  def handle_info(:caches_changed, socket), do: {:noreply, load(socket)}
  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def handle_event("hosts", params, socket) do
    hosts = for {host, "true"} <- Map.get(params, "hosts", %{}), do: host
    hosts = Enum.filter(Hosts.names(), &(&1 in hosts))

    case Caches.set_hosts(socket.assigns.current_scope, hosts) do
      {:ok, _} ->
        {:noreply, socket |> put_flash(:info, "Hosts saved.") |> load()}

      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, "Only admins can do that.")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Those hosts weren't saved.")}
    end
  end

  def handle_event("add_entry", %{"entry" => %{"entry" => entry, "example" => example}}, socket) do
    entry = String.trim(entry)

    case Caches.add_entry(socket.assigns.current_scope, entry, example) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(:entry_form, to_form(%{"entry" => "", "example" => ""}, as: :entry))
         |> put_flash(:info, "Added #{entry}.")
         |> load()}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:entry_form, to_form(%{"entry" => entry, "example" => example}, as: :entry))
         |> put_flash(:error, entry_error(reason))}
    end
  end

  def handle_event("remove_entry", %{"entry" => entry}, socket) do
    Caches.remove_entry(socket.assigns.current_scope, entry)
    {:noreply, load(socket)}
  end

  def handle_event("rotate_ca", _params, socket) do
    case Caches.rotate_ca(socket.assigns.current_scope) do
      {:ok, _} ->
        {:noreply, socket |> put_flash(:info, "Rotating every box cache's CA.") |> load()}

      _ ->
        {:noreply, put_flash(socket, :error, "Only admins can do that.")}
    end
  end

  def handle_event("purge", %{"box" => box_id}, socket) do
    case Caches.purge(socket.assigns.current_scope, box_id, "all") do
      {:ok, _} -> {:noreply, put_flash(socket, :info, "Purging that box's cache.")}
      {:error, :offline} -> {:noreply, put_flash(socket, :error, "That box is offline.")}
      _ -> {:noreply, put_flash(socket, :error, "That didn't work.")}
    end
  end

  defp entry_error(:bad_entry),
    do: "An entry is <known host>/<repository glob>, like ghcr.io/actions/*."

  defp entry_error(:bad_example),
    do: "The example is an image under the entry, like ghcr.io/actions/runner:latest."

  defp entry_error(:example_outside), do: "The example isn't under that entry."

  defp entry_error(:not_public),
    do: "That example isn't public: the allowlist is for images anyone can pull without a login."

  defp entry_error(:unauthorized), do: "Only admins can do that."

  defp pct(nil), do: "–"
  defp pct(rate), do: "#{round(rate * 100)}%"

  defp bytes(n) when n >= 1_073_741_824, do: "#{Float.round(n / 1_073_741_824, 1)} GiB"
  defp bytes(n) when n >= 1_048_576, do: "#{Float.round(n / 1_048_576, 1)} MiB"
  defp bytes(n), do: "#{div(n, 1024)} KiB"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} current_path={@current_path}>
      <:breadcrumb>Admin</:breadcrumb>
      <:breadcrumb>Caches</:breadcrumb>

      <.header>
        Caches
        <:subtitle>
          Each box's registry cache serves public images from the allowlist to its VMs.
        </:subtitle>
      </.header>

      <.panel id="box-caches" title="Boxes" padded={false}>
        <:subtitle>The last day.</:subtitle>
        <ul class="divide-y divide-line text-sm">
          <li
            :for={b <- @boxes}
            id={"cache-#{b.box.id}"}
            class="grid gap-x-6 gap-y-2 px-5 py-3 sm:grid-cols-[minmax(0,1fr)_auto]"
          >
            <div class="min-w-0">
              <p class="font-medium text-ink">{b.box.name}</p>
              <p class="mt-0.5 text-xs text-ink-3">
                {pct(b.summary.hit_rate)} hits · {bytes(b.summary.bytes_served)} served{if b.store_mib,
                  do: " · #{bytes(b.store_mib * 1_048_576)} stored"}{if b.summary.mismatches > 0,
                  do: " · #{b.summary.mismatches} digest mismatches"}
              </p>
              <ul :if={b.summary.top != []} class="mt-1.5 space-y-0.5 text-xs text-ink-2">
                <li :for={t <- Enum.take(b.summary.top, 5)} class="truncate font-mono">
                  {t.host}/{t.repo}
                  <span class="text-ink-3">· {bytes(t.bytes_served || 0)}</span>
                </li>
              </ul>
            </div>
            <div class="text-xs">
              <button
                id={"purge-#{b.box.id}"}
                type="button"
                phx-click="purge"
                phx-value-box={b.box.id}
                data-confirm={"Purge #{b.box.name}'s cache? Its next pulls go upstream."}
                class="text-danger underline-offset-2 hover:underline"
              >
                Purge
              </button>
            </div>
          </li>
          <li :if={@boxes == []} class="px-5 py-3 text-ink-3">No boxes yet.</li>
        </ul>
      </.panel>

      <div class="mt-4 grid gap-4 xl:grid-cols-2">
        <.panel id="hosts-panel" title="Hosts">
          <:subtitle>
            The registries box caches serve.
          </:subtitle>
          <.form for={%{}} id="hosts" phx-submit="hosts" class="space-y-2">
            <label :for={h <- Hosts.names()} class="flex items-center gap-2 text-sm text-ink">
              <input type="hidden" name={"hosts[#{h}]"} value="false" />
              <input
                type="checkbox"
                name={"hosts[#{h}]"}
                value="true"
                checked={h in @config.enabled_hosts}
                class="rounded border-line"
              />
              <span class="font-mono">{h}</span>
            </label>
            <div class="pt-2"><.button type="submit" size="sm">Save hosts</.button></div>
          </.form>
        </.panel>

        <.panel id="allowlist" title="Allowlist" padded={false}>
          <:subtitle>Public images only: each entry is checked with an anonymous pull.</:subtitle>
          <ul class="divide-y divide-line text-sm">
            <li
              :for={entry <- @config.allowlist}
              data-entry={entry}
              class="flex items-center justify-between gap-3 px-5 py-2"
            >
              <span class="min-w-0 truncate font-mono text-ink">{entry}</span>
              <button
                type="button"
                phx-click="remove_entry"
                phx-value-entry={entry}
                class="text-xs text-danger underline-offset-2 hover:underline"
              >
                Remove
              </button>
            </li>
            <li :if={@config.allowlist == []} class="px-5 py-3 text-ink-3">None.</li>
          </ul>
          <.form
            for={@entry_form}
            id="new-entry"
            phx-submit="add_entry"
            class="grid gap-3 border-t border-line p-5 sm:grid-cols-2"
          >
            <.input field={@entry_form[:entry]} label="Entry" placeholder="ghcr.io/actions/*" />
            <.input
              field={@entry_form[:example]}
              label="An image under it"
              placeholder="ghcr.io/actions/runner:latest"
            />
            <div class="sm:col-span-2"><.button type="submit" size="sm">Check and add</.button></div>
          </.form>
        </.panel>
      </div>

      <.panel id="ca" title="CA" class="mt-4">
        <div class="flex flex-wrap items-center justify-between gap-3 text-sm">
          <p class="text-ink-2">
            Generation {@config.ca_generation}. VMs started after a rotation trust the new root.
          </p>
          <.button
            id="rotate-ca"
            size="sm"
            phx-click="rotate_ca"
            data-confirm="Rotate every box cache's CA?"
          >
            Rotate CA
          </.button>
        </div>
      </.panel>
    </Layouts.app>
    """
  end
end
