defmodule CrewWeb.AdminLive.Sizes do
  @moduledoc """
  Sizes & labels (§17.3): the sizes (§7.1) with the one default, the
  label aliases (§7.3), and a label tester: paste a `runs-on` value and
  see how it parses, whether it's spare, and which boxes (or, for a spare
  label, which boxes' spare shares) could hold it. Admins only; every
  change is audited by `Crew.Sizes`.
  """
  use CrewWeb, :live_view

  alias Crew.{Repos, Scheduler, Sizes}
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
     |> assign(:allow_repos, [])
     |> load()}
  end

  # From a custom right-sizing hint (§7.5): its shape in the new-size
  # form, and the repos it's for that limit their sizes, to allow it for.
  @impl true
  def handle_params(params, _uri, socket) do
    shape = Map.take(params, ["vcpus", "memory_mib", "disk_gib"])

    socket =
      if shape == %{},
        do: socket,
        else: assign(socket, new_size: to_form(Sizes.change(%Size{}, shape), as: :size))

    {:noreply, assign(socket, :allow_repos, limited_repos(params["repos"]))}
  end

  defp limited_repos(ids) when is_list(ids) do
    ids
    |> Enum.flat_map(fn id ->
      case Ecto.UUID.cast(id) do
        {:ok, id} -> [Repos.get(id)]
        :error -> []
      end
    end)
    |> Enum.filter(&limits_sizes?/1)
    |> Enum.uniq_by(& &1.id)
  end

  defp limited_repos(_ids), do: []

  defp limits_sizes?(%Crew.Repos.Repo{archived_at: nil, allowed_sizes: [_ | _]}), do: true
  defp limits_sizes?(_repo), do: false

  # Adds the new size to each of the repos ticked, among those offered,
  # that still limit their sizes: one that stopped already takes it.
  defp allow(scope, size, ticked, offered) do
    for %{id: id} <- offered,
        id in List.wrap(ticked),
        repo = Repos.get(id),
        limits_sizes?(repo),
        size.name not in repo.allowed_sizes,
        {:ok, repo} <-
          [
            Repos.update_settings(scope, repo, %{
              "allowed_sizes" => repo.allowed_sizes ++ [size.name]
            })
          ],
        do: repo
  end

  defp load(socket), do: assign(socket, sizes: Sizes.list(), aliases: Sizes.list_aliases())

  defp added(size, []), do: "Added #{size.name}."

  defp added(size, repos),
    do: "Added #{size.name}. #{Enum.map_join(repos, ", ", & &1.full_name)} may use it."

  @impl true
  def handle_info(:sizes_changed, socket), do: {:noreply, load(socket)}
  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def handle_event("create_size", %{"size" => attrs} = params, socket) do
    scope = socket.assigns.current_scope

    case Sizes.create(scope, attrs) do
      {:ok, size} ->
        allowed = allow(scope, size, params["allow"], socket.assigns.allow_repos)

        {:noreply,
         socket
         |> load()
         |> assign(new_size: to_form(Sizes.change(%Size{}), as: :size), allow_repos: [])
         |> put_flash(:info, added(size, allowed))}

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
                <.badge :if={parsed.spare} size="sm" data-tier="spare">spare</.badge>
              </p>
              <%= cond do %>
                <% @tested.boxes != [] and parsed.spare -> %>
                  <p class="text-ink-2">
                    Boxes whose spare share could hold it: {Enum.join(@tested.boxes, ", ")}
                  </p>
                <% @tested.boxes != [] -> %>
                  <p class="text-ink-2">
                    Boxes that could hold it: {Enum.join(@tested.boxes, ", ")}
                  </p>
                <% parsed.spare -> %>
                  <p class="text-warning">No box's spare share could hold it.</p>
                <% true -> %>
                  <p class="text-warning">No box could hold it.</p>
              <% end %>
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
          <%!-- Phone-wide, each size is a card; the table needs more room. --%>
          <ul class="divide-y divide-line text-sm sm:hidden">
            <li
              :for={size <- @sizes}
              id={"size-card-#{size.name}"}
              class={["px-5 py-3", Size.retired?(size) && "text-ink-3"]}
            >
              <div class="flex flex-wrap items-center gap-x-2 gap-y-1">
                <span class="font-mono">crew-{size.name}</span>
                <.badge :if={size.is_default} color="brand" size="sm">default</.badge>
                <.badge :if={Size.retired?(size)} size="sm">retired</.badge>
              </div>
              <p :if={warning = spare_warning(size)} class="mt-0.5 text-xs text-warning">
                {warning}
              </p>
              <p class="mt-0.5 tabular-nums text-ink-2">
                {size.vcpus} vCPUs · {gib(size.memory_mib)} GiB · {size.disk_gib} GiB disk
              </p>
              <div class="mt-1.5 space-x-3 text-xs"><.size_actions size={size} /></div>
            </li>
          </ul>
          <table class="hidden w-full text-sm sm:table">
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
              <%= for size <- @sizes do %>
                <% warning = spare_warning(size) %>
                <tr
                  id={"size-#{size.name}"}
                  class={[Size.retired?(size) && "text-ink-3", warning && "!border-b-0 [&>td]:pb-0"]}
                >
                  <td class="px-5 py-2">
                    <span class="font-mono">crew-{size.name}</span>
                    <.badge :if={size.is_default} color="brand" size="sm">default</.badge>
                    <.badge :if={Size.retired?(size)} size="sm">retired</.badge>
                  </td>
                  <td class="px-2 py-2 text-right tabular-nums">{size.vcpus}</td>
                  <td class="whitespace-nowrap px-2 py-2 text-right tabular-nums">
                    {gib(size.memory_mib)} GiB
                  </td>
                  <td class="whitespace-nowrap px-2 py-2 text-right tabular-nums">
                    {size.disk_gib} GiB
                  </td>
                  <td class="space-x-2 whitespace-nowrap px-5 py-2 text-right text-xs">
                    <.size_actions size={size} />
                  </td>
                </tr>
                <tr :if={warning} id={"size-#{size.name}-warning"}>
                  <td colspan="5" class="px-5 pb-2 pt-0.5 text-xs text-warning">{warning}</td>
                </tr>
              <% end %>
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
            <fieldset
              :if={@allow_repos != []}
              id="new-size-allow"
              class="col-span-2 space-y-1.5 sm:col-span-4"
            >
              <legend class="mb-1.5 text-xs text-ink-2">
                These repos limit their sizes. Allow the new one for them:
              </legend>
              <input type="hidden" name="allow[]" value="" />
              <label :for={r <- @allow_repos} class="flex items-center gap-2 text-sm text-ink">
                <input type="checkbox" name="allow[]" value={r.id} checked class="checkbox" />
                {r.full_name}
              </label>
            </fieldset>
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
            class="grid grid-cols-2 gap-3 border-t border-line p-5 sm:grid-cols-3"
          >
            <div class="col-span-2 sm:col-span-1">
              <.input
                field={@new_alias[:labels]}
                label="Labels"
                placeholder="self-hosted, linux"
                value={labels_value(@new_alias[:labels].value)}
              />
            </div>
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
            <div class="col-span-2 sm:col-span-3">
              <.button type="submit" size="sm">Add alias</.button>
            </div>
          </.form>
        </.panel>
      </div>
    </Layouts.app>
    """
  end

  attr :size, :map, required: true

  defp size_actions(assigns) do
    ~H"""
    <button
      :if={!@size.is_default and !Size.retired?(@size)}
      type="button"
      phx-click="default"
      phx-value-id={@size.id}
      class="underline-offset-2 hover:underline"
    >Make default</button>
    <button
      :if={!@size.is_default and !Size.retired?(@size)}
      type="button"
      phx-click="retire"
      phx-value-id={@size.id}
      data-confirm={"Retire #{@size.name}? Jobs asking for it can't run."}
      class="text-danger underline-offset-2 hover:underline"
    >Retire</button>
    <button
      :if={Size.retired?(@size)}
      type="button"
      phx-click="unretire"
      phx-value-id={@size.id}
      class="underline-offset-2 hover:underline"
    >Unretire</button>
    """
  end

  # A size named before the -spare rule (§7.1) hides its label's spare
  # form; renaming it hands the label over.
  defp spare_warning(%Size{name: name}) do
    label =
      cond do
        name == "spare" -> "crew-spare"
        String.ends_with?(name, "-spare") -> "crew-#{name}"
        true -> nil
      end

    if label do
      "#{CrewProtocol.Sizes.name_error(name)}: rename it to use #{label}. " <>
        "Runners already started for this label finish their jobs first."
    end
  end

  defp labels_value(list) when is_list(list), do: Enum.join(list, ", ")
  defp labels_value(other), do: other
end
