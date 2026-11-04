defmodule CrewWeb.CrewComponents do
  @moduledoc "Components for Crew's own concepts: boxes, capacity, commands."
  use Phoenix.Component
  use CrewWeb, :verified_routes

  import CrewWeb.CoreComponents

  @doc """
  A box's status (§17.3): online, draining, quarantined, needs approval,
  revoked or offline, as a badge with text.
  """
  attr :box, :map, required: true
  attr :online, :boolean, required: true

  def box_status(assigns) do
    assigns = assign(assigns, :status, box_state(assigns.box, assigns.online))

    ~H"""
    <span class="inline-flex flex-wrap gap-1.5">
      <.badge :for={{color, label} <- @status} color={color} dot>{label}</.badge>
    </span>
    """
  end

  defp box_state(%{revoked_at: at}, _online) when not is_nil(at), do: [{"rose", "Revoked"}]

  defp box_state(box, online) do
    now = DateTime.utc_now()

    [
      if(online, do: {"emerald", "Online"}, else: {"zinc", "Offline"}),
      box.needs_approval && {"amber", "Needs approval"},
      box.draining && {"sky", "Draining"},
      box.quarantined_until && DateTime.compare(box.quarantined_until, now) == :gt &&
        {"rose", "Quarantined"},
      box.reboot_required && {"amber", "Reboot needed"}
    ]
    |> Enum.filter(& &1)
  end

  @doc """
  A small line chart of a series against its ceiling (a VM's CPU or
  memory against its size), as an inline SVG, with the last value.
  """
  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :values, :list, required: true
  attr :max, :any, required: true
  attr :unit, :string, default: ""

  def sparkline(assigns) do
    values = Enum.take(assigns.values, -120)

    max =
      if is_number(assigns.max) and assigns.max > 0,
        do: assigns.max,
        else: Enum.max(values, fn -> 1 end)

    n = length(values)

    points =
      values
      |> Enum.with_index()
      |> Enum.map_join(" ", fn {v, i} ->
        x = if n > 1, do: i * 100 / (n - 1), else: 100
        y = 30 - min(v / max, 1) * 28
        "#{Float.round(x * 1.0, 2)},#{Float.round(y * 1.0, 2)}"
      end)

    assigns = assign(assigns, points: points, last: List.last(values))

    ~H"""
    <figure id={@id} class="space-y-1">
      <figcaption class="flex items-baseline justify-between text-xs">
        <span class="text-ink-2">{@label}</span>
        <span class="tabular-nums text-ink-3">
          <%= if @last do %>
            {round(@last)}{@unit}<span :if={@unit != "%"}> / {round(@max)}{@unit}</span>
          <% else %>
            –
          <% end %>
        </span>
      </figcaption>
      <svg
        viewBox="0 0 100 32"
        preserveAspectRatio="none"
        class="h-10 w-full text-accent"
        role="img"
        aria-label={@label}
      >
        <line
          x1="0"
          y1="2"
          x2="100"
          y2="2"
          class="stroke-line"
          stroke-width="0.5"
          stroke-dasharray="2 2"
          vector-effect="non-scaling-stroke"
        />
        <polyline
          :if={@points != ""}
          points={@points}
          fill="none"
          stroke="currentColor"
          stroke-width="1.5"
          vector-effect="non-scaling-stroke"
        />
      </svg>
    </figure>
    """
  end

  @doc "A used-of-total bar, amber past `threshold`."
  attr :label, :string, required: true
  attr :value, :any, required: true
  attr :max, :any, required: true
  attr :unit, :string, default: ""
  attr :threshold, :float, default: 0.9
  attr :format, :any, default: nil

  def capacity_bar(assigns) do
    max = if is_number(assigns.max) and assigns.max > 0, do: assigns.max, else: nil
    ratio = if max, do: (assigns.value || 0) / max, else: 0

    assigns =
      assigns
      |> assign(:ratio, ratio)
      |> assign(:max_value, max && round(max * 100))
      |> assign(:bar_value, max && round(min(assigns.value || 0, max) * 100))

    ~H"""
    <div class="space-y-1.5">
      <div class="flex items-baseline justify-between gap-2 text-xs">
        <span class="text-ink-2">{@label}</span>
        <span class="tabular-nums text-ink-3">
          {fmt(@value, @format)}<span :if={@max_value}> / {fmt(@max, @format)}</span>{@unit}
        </span>
      </div>
      <progress
        :if={@max_value}
        class={["bar", bar_class(@ratio, @threshold)]}
        value={@bar_value}
        max={@max_value}
        aria-label={@label}
      >
        {round(@ratio * 100)}%
      </progress>
    </div>
    """
  end

  defp bar_class(ratio, threshold) when ratio > 1,
    do: if(threshold < 1, do: "bar-danger", else: "bar-warning")

  defp bar_class(ratio, threshold) when ratio > threshold, do: "bar-warning"
  defp bar_class(_, _), do: nil

  defp fmt(nil, _), do: "0"
  defp fmt(value, fun) when is_function(fun, 1), do: fun.(value)

  defp fmt(value, _) when is_float(value),
    do: :erlang.float_to_binary(Float.round(value, 1), [:short])

  defp fmt(value, _), do: to_string(value)

  # One decimal below 100 GiB, whole numbers above ("1758", not "1.8e3").
  def gib(mb) when is_number(mb) and mb >= 100 * 1024, do: Integer.to_string(round(mb / 1024))
  def gib(mb) when is_number(mb), do: :erlang.float_to_binary(mb / 1024, decimals: 1)
  def gib(_), do: "0"

  @doc "A shell command with a copy button."
  attr :id, :string, required: true
  attr :command, :string, required: true
  attr :label, :string, default: nil

  def command(assigns) do
    ~H"""
    <div class="space-y-1.5">
      <p :if={@label} class="text-xs font-medium text-ink-2">{@label}</p>
      <div class="flex items-stretch gap-2">
        <code id={@id} class="command min-w-0 flex-1 text-ink">{@command}</code>
        <button
          type="button"
          id={"#{@id}-copy"}
          phx-hook="Copy"
          data-copy={@command}
          class="inline-flex shrink-0 items-center gap-1.5 rounded-lg border border-line-strong bg-canvas px-3 text-xs font-medium text-ink-2 shadow-control transition-colors hover:bg-subtle hover:text-ink"
        >
          <.icon name="hero-clipboard-document-micro" class="size-3.5" />
          <span data-copy-label>Copy</span>
        </button>
      </div>
    </div>
    """
  end

  @doc "A titled panel, the basic surface for page sections."
  attr :title, :string, default: nil
  attr :id, :string, default: nil
  attr :class, :any, default: nil
  attr :padded, :boolean, default: true
  slot :actions
  slot :subtitle
  slot :inner_block, required: true

  def panel(assigns) do
    ~H"""
    <section id={@id} class={["rounded-xl border border-line bg-raised shadow-xs", @class]}>
      <header
        :if={@title}
        class="flex items-start justify-between gap-4 border-b border-line px-5 py-3.5"
      >
        <div class="min-w-0">
          <h2 class="text-sm font-semibold text-ink">{@title}</h2>
          <p :if={@subtitle != []} class="mt-0.5 text-xs text-ink-2">{render_slot(@subtitle)}</p>
        </div>
        <div :if={@actions != []} class="flex shrink-0 items-center gap-2">
          {render_slot(@actions)}
        </div>
      </header>
      <div class={@padded && "p-5"}>{render_slot(@inner_block)}</div>
    </section>
    """
  end

  @doc "A notice strip: info, warning or danger."
  attr :kind, :string, default: "info", values: ~w(info warning danger)
  attr :icon, :string, default: nil
  attr :id, :string, default: nil
  attr :class, :any, default: nil
  slot :inner_block, required: true
  slot :actions

  def callout(assigns) do
    ~H"""
    <div
      id={@id}
      class={[
        "flex flex-col gap-3 rounded-xl border px-4 py-3 text-sm sm:flex-row sm:items-center",
        @kind == "info" && "border-line bg-subtle text-ink-2",
        @kind == "warning" && "border-warning/30 bg-warning-soft text-warning",
        @kind == "danger" && "border-danger/30 bg-danger-soft text-danger",
        @class
      ]}
    >
      <div class="flex flex-1 items-start gap-2.5">
        <.icon name={@icon || callout_icon(@kind)} class="mt-0.5 size-4 shrink-0" />
        <div class="min-w-0 flex-1">{render_slot(@inner_block)}</div>
      </div>
      <div :if={@actions != []} class="flex shrink-0 flex-wrap items-center gap-2">
        {render_slot(@actions)}
      </div>
    </div>
    """
  end

  defp callout_icon("info"), do: "hero-information-circle-mini"
  defp callout_icon("warning"), do: "hero-exclamation-triangle-mini"
  defp callout_icon("danger"), do: "hero-x-circle-mini"

  @doc "An operation's status as a small icon and label."
  attr :status, :string, required: true

  def op_status(assigns) do
    ~H"""
    <span class={["inline-flex items-center gap-1.5 text-xs font-medium", op_color(@status)]}>
      <.icon
        name={op_icon(@status)}
        class={["size-4", @status in ~w(dispatched running) && "motion-safe:animate-spin"]}
      />
      {op_label(@status)}
    </span>
    """
  end

  defp op_icon("succeeded"), do: "hero-check-circle-mini"
  defp op_icon("failed"), do: "hero-x-circle-mini"
  defp op_icon("cancelled"), do: "hero-minus-circle-mini"
  defp op_icon("queued"), do: "hero-clock-mini"
  defp op_icon(_), do: "hero-arrow-path-mini"

  defp op_color("succeeded"), do: "text-success"
  defp op_color("failed"), do: "text-danger"
  defp op_color("queued"), do: "text-ink-3"
  defp op_color("cancelled"), do: "text-ink-3"
  defp op_color(_), do: "text-accent-ink"

  defp op_label("dispatched"), do: "Sent"
  defp op_label(status), do: String.capitalize(status)

  @doc "A human name for an operation's action."
  def action_label("vm.start"), do: "Start a VM"
  def action_label("vm.stop"), do: "Stop a VM"
  def action_label("image.prepare"), do: "Prepare an image"
  def action_label("image.remove"), do: "Remove an image"
  def action_label("cache.config"), do: "Configure the cache"
  def action_label("cache.purge"), do: "Purge the cache"
  def action_label("box.inventory"), do: "Refresh inventory"
  def action_label("box.restart"), do: "Reboot the box"
  def action_label("cachevm.restart"), do: "Reboot the cache VM"
  def action_label("agent.update"), do: "Update agent"
  def action_label("op.cancel"), do: "Cancel an operation"
  def action_label(other), do: other

  @doc """
  A job's status (§17.4): an icon and text, never colour alone, and the
  reason where there is one. `data-job-state` names the state for tests
  and styles.
  """
  attr :job, :map, required: true
  attr :now, :any, default: nil
  attr :reason, :boolean, default: true

  def job_status(assigns) do
    assigns =
      assign(
        assigns,
        :status,
        CrewWeb.JobStatus.of(assigns.job, assigns.now || DateTime.utc_now())
      )

    ~H"""
    <span
      data-job-state={@status.state}
      class={["inline-flex min-w-0 items-center gap-1.5 text-sm", tone(@status.tone)]}
    >
      <span :if={@status.icon == "dot"} class="relative flex size-2.5 shrink-0" aria-hidden="true">
        <span class="absolute inline-flex size-full animate-ping rounded-full bg-accent opacity-60"></span>
        <span class="relative inline-flex size-2.5 rounded-full bg-accent"></span>
      </span>
      <.icon :if={@status.icon not in ["", "dot"]} name={@status.icon} class="size-4 shrink-0" />
      <span class="font-medium">{@status.label}</span>
      <span :if={@reason and @status.reason} class="truncate text-ink-3">· {@status.reason}</span>
    </span>
    """
  end

  defp tone(:success), do: "text-success"
  defp tone(:danger), do: "text-danger"
  defp tone(:warning), do: "text-warning"
  defp tone(:accent), do: "text-accent-ink"
  defp tone(:muted), do: "text-ink-3"

  @doc "One segment per job, each with its state: the per-job state bar of the Runs page."
  attr :jobs, :list, required: true
  attr :now, :any, default: nil

  def job_bar(assigns) do
    now = assigns.now || DateTime.utc_now()

    statuses = Enum.map(assigns.jobs, &{&1, CrewWeb.JobStatus.of(&1, now)})
    assigns = assign(assigns, statuses: statuses, groups: groups(statuses))

    ~H"""
    <span class="flex h-2 w-28 gap-0.5 overflow-hidden" role="img" aria-label={bar_label(@statuses)}>
      <%= if @groups do %>
        <span
          :for={{state, n} <- @groups}
          data-job-state={state}
          data-count={n}
          title={"#{n} #{String.replace(state, "_", " ")}"}
          style={"flex-grow: #{n}"}
          class={["h-full min-w-1 basis-0 rounded-sm", segment(state)]}
        ></span>
      <% else %>
        <span
          :for={{job, status} <- @statuses}
          data-job-state={status.state}
          title={"#{job.name}: #{status.label}"}
          class={["h-full min-w-1 flex-1 rounded-sm", segment(status.state)]}
        ></span>
      <% end %>
    </span>
    """
  end

  # Past 16 jobs a segment each doesn't fit: one segment per state,
  # sized by its count, in the order a run moves through them.
  @bar_order ~w(success failure refused running blocked unsatisfiable queued)
  defp groups(statuses) when length(statuses) > 16, do: by_state(statuses)
  defp groups(_statuses), do: nil

  defp by_state(statuses) do
    counts = Enum.frequencies_by(statuses, fn {_, s} -> s.state end)
    known = for state <- @bar_order, n = counts[state], do: {state, n}
    known ++ Enum.sort(Map.drop(counts, @bar_order))
  end

  defp bar_label(statuses) do
    statuses
    |> by_state()
    |> Enum.map_join(", ", fn {state, n} -> "#{n} #{String.replace(state, "_", " ")}" end)
  end

  defp segment("success"), do: "bg-success"
  defp segment("failure"), do: "bg-danger"
  defp segment("refused"), do: "bg-danger"
  defp segment("running"), do: "bg-accent"
  defp segment("blocked"), do: "bg-warning"
  defp segment("unsatisfiable"), do: "bg-warning"
  defp segment("queued"), do: "bg-ink-3/50"
  defp segment(_), do: "bg-line"
end
