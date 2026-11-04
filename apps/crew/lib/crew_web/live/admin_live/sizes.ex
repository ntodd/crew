defmodule CrewWeb.AdminLive.Sizes do
  @moduledoc """
  Sizes & labels (§17.3): the sizes (§7.1) with the one default, the
  label aliases (§7.3), and a label tester: paste a `runs-on` value and
  see how it parses and which boxes could hold it. Admins only; every
  change is audited by `Crew.Sizes`.
  """
  use CrewWeb, :live_view

  alias Crew.{Scheduler, Sizes}
  alias Crew.Sizes.{LabelAlias, Size}

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Sizes.subscribe()

    {:ok,
     socket
     |> assign(:page_title, "Sizes & labels")
     |> assign(:runs_on, "")
     |> assign(:tested, nil)
     |> assign(:new_size, to_form(Sizes.change(%Size{}), as: :size))
     |> assign(:new_alias, to_form(LabelAlias.changeset(%LabelAlias{}, %{}), as: :label_alias))
     |> load()}
  end

  defp load(socket), do: assign(socket, sizes: Sizes.list(), aliases: Sizes.list_aliases())

  @impl true
  def handle_info(:sizes_changed, socket), do: {:noreply, load(socket)}
  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def handle_event("create_size", %{"size" => attrs}, socket) do
    case Sizes.create(socket.assigns.current_scope, attrs) do
      {:ok, size} ->
        {:noreply,
         socket
         |> load()
         |> assign(new_size: to_form(Sizes.change(%Size{}), as: :size))
         |> put_flash(:info, "Added #{size.name}.")}

      {:error, %Ecto.Changeset{} = cs} ->
        {:noreply, assign(socket, new_size: to_form(Map.put(cs, :action, :validate), as: :size))}

      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, "Only admins can do that.")}
    end
  end

  def handle_event(action, %{"id" => id}, socket)
      when action in ["default", "retire", "unretire"] do
    size = Sizes.get!(id)
    scope = socket.assigns.current_scope

    result =
      case action do
        "default" -> Sizes.make_default(scope, size)
        "retire" -> Sizes.retire(scope, size)
        "unretire" -> Sizes.unretire(scope, size)
      end

    case result do
      {:ok, _} ->
        {:noreply, load(socket)}

      {:error, :retired} ->
        {:noreply, put_flash(socket, :error, "A retired size can't be the default.")}

      {:error, :default} ->
        {:noreply, put_flash(socket, :error, "The default size can't be retired.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "That didn't work: #{inspect(reason)}")}
    end
  end

  def handle_event("create_alias", %{"label_alias" => attrs}, socket) do
    labels = attrs |> Map.get("labels", "") |> String.split(~r/[,\s]+/, trim: true)

    case Sizes.create_alias(socket.assigns.current_scope, Map.put(attrs, "labels", labels)) do
      {:ok, _} ->
        {:noreply,
         socket
         |> load()
         |> assign(new_alias: to_form(LabelAlias.changeset(%LabelAlias{}, %{}), as: :label_alias))}

      {:error, %Ecto.Changeset{} = cs} ->
        {:noreply,
         assign(socket, new_alias: to_form(Map.put(cs, :action, :validate), as: :label_alias))}

      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, "Only admins can do that.")}
    end
  end

  def handle_event("delete_alias", %{"id" => id}, socket) do
    with %LabelAlias{} = a <- Enum.find(socket.assigns.aliases, &(&1.id == id)) do
      Sizes.delete_alias(socket.assigns.current_scope, a)
    end

    {:noreply, load(socket)}
  end

  def handle_event("test", %{"runs_on" => text}, socket) do
    {:noreply,
     assign(socket,
       runs_on: text,
       tested: if(String.trim(text) == "", do: nil, else: Scheduler.label_test(text))
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} current_path={@current_path}>
      <:breadcrumb>Admin</:breadcrumb>
      <:breadcrumb>Sizes & labels</:breadcrumb>

      <.header>
        Sizes & labels
        <:subtitle>
          What <code>runs-on: crew-&lt;size&gt;</code> means, and the labels that stand for a size.
        </:subtitle>
      </.header>

      <.panel id="tester-panel" title="Label tester">
        <:subtitle>Paste a <code>runs-on</code> value.</:subtitle>
        <.form for={%{}} id="label-tester" phx-change="test">
          <.input
            name="runs_on"
            value={@runs_on}
            label="runs-on"
            placeholder="[self-hosted, crew-m-arm64]"
            phx-debounce="200"
          />
        </.form>
        <div :if={@tested} id="tested" class="mt-3 space-y-1 text-sm">
          <p class="text-ink-3">
            Labels: <span class="font-mono text-ink">{Enum.join(@tested.key, ", ")}</span>
          </p>
          <%= case @tested.result do %>
            <% {:ours, parsed} -> %>
              <p class="text-ink">
                Crew job: size <span class="font-medium">{@tested.sizes[parsed.size_id] && @tested.sizes[parsed.size_id].name}</span>,
                arch <span class="font-medium">{parsed.arch}</span>{if parsed.alias,
                  do: " (by an alias)"}
              </p>
              <p :if={@tested.boxes != []} class="text-ink-2">
                Boxes that could hold it: {Enum.join(@tested.boxes, ", ")}
              </p>
              <p :if={@tested.boxes == []} class="text-warning">No box could hold it.</p>
            <% :not_ours -> %>
              <p class="text-ink-2">
                Not a Crew job: GitHub's runners, or another self-hosted pool, take it.
              </p>
            <% {:unsatisfiable, reason} -> %>
              <p class="text-warning">Crew can't run it: {reason}</p>
            <% :empty -> %>
              <p class="text-ink-3">No labels.</p>
          <% end %>
        </div>
      </.panel>

      <div class="mt-4 grid gap-4 xl:grid-cols-2">
        <.panel id="sizes" title="Sizes" padded={false}>
          <table class="w-full text-sm">
            <thead class="text-left text-xs text-ink-3">
              <tr>
                <th class="px-5 py-2 font-medium">Name</th>
                <th class="px-2 py-2 text-right font-medium">vCPUs</th>
                <th class="px-2 py-2 text-right font-medium">Memory</th>
                <th class="px-2 py-2 text-right font-medium">Disk</th>
                <th class="px-5 py-2"></th>
              </tr>
            </thead>
            <tbody class="divide-y divide-line">
              <tr
                :for={size <- @sizes}
                id={"size-#{size.name}"}
                class={Size.retired?(size) && "text-ink-3"}
              >
                <td class="px-5 py-2">
                  <span class="font-mono">crew-{size.name}</span>
                  <.badge :if={size.is_default} color="brand" size="sm">default</.badge>
                  <.badge :if={Size.retired?(size)} size="sm">retired</.badge>
                </td>
                <td class="px-2 py-2 text-right tabular-nums">{size.vcpus}</td>
                <td class="px-2 py-2 text-right tabular-nums">{gib(size.memory_mib)} GiB</td>
                <td class="px-2 py-2 text-right tabular-nums">{size.disk_gib} GiB</td>
                <td class="space-x-2 whitespace-nowrap px-5 py-2 text-right text-xs">
                  <button
                    :if={!size.is_default and !Size.retired?(size)}
                    type="button"
                    phx-click="default"
                    phx-value-id={size.id}
                    class="underline-offset-2 hover:underline"
                  >Make default</button>
                  <button
                    :if={!size.is_default and !Size.retired?(size)}
                    type="button"
                    phx-click="retire"
                    phx-value-id={size.id}
                    data-confirm={"Retire #{size.name}? Jobs asking for it can't run."}
                    class="text-danger underline-offset-2 hover:underline"
                  >Retire</button>
                  <button
                    :if={Size.retired?(size)}
                    type="button"
                    phx-click="unretire"
                    phx-value-id={size.id}
                    class="underline-offset-2 hover:underline"
                  >Unretire</button>
                </td>
              </tr>
            </tbody>
          </table>
          <.form
            for={@new_size}
            id="new-size"
            phx-submit="create_size"
            class="grid grid-cols-2 gap-3 border-t border-line p-5 sm:grid-cols-4"
          >
            <.input field={@new_size[:name]} label="Name" />
            <.input field={@new_size[:vcpus]} type="number" label="vCPUs" />
            <.input field={@new_size[:memory_mib]} type="number" label="Memory (MiB)" />
            <.input field={@new_size[:disk_gib]} type="number" label="Disk (GiB)" />
            <div class="col-span-2 sm:col-span-4">
              <.button type="submit" size="sm">Add size</.button>
            </div>
          </.form>
        </.panel>

        <.panel id="aliases" title="Aliases" padded={false}>
          <:subtitle>
            Labels without a crew- label that stand for a size, like [self-hosted, linux].
          </:subtitle>
          <ul class="divide-y divide-line text-sm">
            <li
              :for={a <- @aliases}
              id={"alias-#{a.id}"}
              class="flex items-center justify-between gap-3 px-5 py-2"
            >
              <span class="font-mono text-ink">{Enum.join(Enum.sort(a.labels), ", ")}</span>
              <span class="text-ink-2">→ {a.size.name}{if a.arch != "any", do: " · #{a.arch}"}</span>
              <button
                type="button"
                phx-click="delete_alias"
                phx-value-id={a.id}
                class="text-xs text-danger underline-offset-2 hover:underline"
              >Remove</button>
            </li>
            <li :if={@aliases == []} class="px-5 py-3 text-ink-3">None.</li>
          </ul>
          <.form
            for={@new_alias}
            id="new-alias"
            phx-submit="create_alias"
            class="grid grid-cols-3 gap-3 border-t border-line p-5"
          >
            <.input
              field={@new_alias[:labels]}
              label="Labels"
              placeholder="self-hosted, linux"
              value={labels_value(@new_alias[:labels].value)}
            />
            <.input
              field={@new_alias[:size_id]}
              type="select"
              label="Size"
              options={for s <- @sizes, !Size.retired?(s), do: {s.name, s.id}}
            />
            <.input
              field={@new_alias[:arch]}
              type="select"
              label="Arch"
              options={[{"any", "any"}, {"arm64", "arm64"}, {"x64", "x64"}]}
            />
            <div class="col-span-3"><.button type="submit" size="sm">Add alias</.button></div>
          </.form>
        </.panel>
      </div>
    </Layouts.app>
    """
  end

  defp labels_value(list) when is_list(list), do: Enum.join(list, ", ")
  defp labels_value(other), do: other
end
