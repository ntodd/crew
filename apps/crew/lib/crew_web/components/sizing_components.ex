defmodule CrewWeb.SizingComponents do
  @moduledoc """
  Right-sizing hints (§7.5) as the job and repo pages show them: what to
  move to, why, the `runs-on` line that does it, and an issue to file.
  """
  use Phoenix.Component
  use CrewWeb, :verified_routes

  import CrewWeb.CoreComponents, only: [button: 1, icon: 1]
  import CrewWeb.CrewComponents, only: [gib: 1, gh_link: 1]

  alias Crew.Sizing.Rules.Hint
  alias CrewWeb.{GitHub, SizingIssue}
  alias Phoenix.LiveView.JS

  @doc "A hint's headline."
  def title(%Hint{kind: :smaller, to: to}), do: "Try #{to.name}"
  def title(%Hint{kind: :custom}), do: "A custom size would fit"
  def title(%Hint{kind: :larger, to: nil}), do: "Needs more memory"
  def title(%Hint{kind: :larger, to: to}), do: "Needs more memory: #{to.name}"
  def title(%Hint{kind: :faster, to: to}), do: "Could run faster on #{to.name}"
  def title(%Hint{kind: :fits, from: from}), do: "#{from.name || "Its size"} fits"

  @doc "A shape as the pages write sizes: 4 vCPU · 8 GiB, with the name when it has one."
  def shape(nil), do: "–"

  def shape(s) do
    base = "#{s.vcpus} vCPU · #{gib(s.memory_mib)} GiB"
    base = if s[:disk_gib] && is_nil(s[:name]), do: "#{base} · #{s.disk_gib} GiB disk", else: base
    if s[:name], do: "#{s.name} (#{base})", else: base
  end

  @doc "GiB-hours as the pages write them: one decimal, whole past 100."
  def gib_h(x) when x >= 100, do: x |> round() |> Integer.to_string()
  def gib_h(x), do: :erlang.float_to_binary(x * 1.0, decimals: 1)

  @doc ~s(What a run would free, or take, in GiB: "frees 6.0 GiB a run", "takes 8.0 GiB more a run".)
  def saving(%Hint{saved_mib: 0}), do: nil
  def saving(%Hint{saved_mib: m}) when m > 0, do: "frees #{gib(m)} GiB a run"
  def saving(%Hint{saved_mib: m}), do: "takes #{gib(-m)} GiB more a run"

  @doc """
  The Crew label for a size in place of the job's (§7.2): its arch when
  its Crew label named one (`crew-s-arm64`), or when an alias set it, and
  `-spare` for a spare job. Nil for a size without a name.
  """
  def label(%{name: name}, job) when is_binary(name),
    do: "crew-#{name}#{arch_suffix(job)}#{if spare?(job), do: "-spare"}"

  def label(_size, _job), do: nil

  @doc """
  The job's `runs-on` with the size's label in place of its Crew label,
  the labels next to it kept (`[self-hosted, crew-xs]`); just the label
  for a job without one (an alias, §7.3). Nil for a size without a name.
  """
  def runs_on(size, job) do
    with new when is_binary(new) <- label(size, job) do
      labels = labels(job)

      if Enum.any?(labels, &crew_label?/1),
        do: format_runs_on(Enum.map(labels, &if(crew_label?(&1), do: new, else: &1))),
        else: new
    end
  end

  @doc "A job's labels as its `runs-on` reads: one alone, several in brackets. Nil without any."
  def runs_on_now(job) do
    case labels(job) do
      [] -> nil
      labels -> format_runs_on(labels)
    end
  end

  defp format_runs_on([label]), do: label
  defp format_runs_on(labels), do: "[" <> Enum.join(labels, ", ") <> "]"

  defp labels(nil), do: []
  defp labels(job), do: Map.get(job, :labels) || []

  defp spare?(nil), do: false
  defp spare?(job), do: Map.get(job, :spare) == true

  defp crew_label?(label) do
    label = String.downcase(label)
    label == "crew" or String.starts_with?(label, "crew-")
  end

  # The arch stays in the new label when the old one had it; generic
  # labels next to it keep theirs. A job on an alias has no Crew label,
  # so the new one carries the alias's arch.
  defp arch_suffix(nil), do: ""

  defp arch_suffix(job) do
    arch = Map.get(job, :arch)
    crew = job |> labels() |> Enum.find(&crew_label?/1)

    cond do
      arch not in ["x64", "arm64"] ->
        ""

      is_nil(crew) ->
        "-" <> arch

      crew |> String.downcase() |> drop_spare(job) |> String.ends_with?("-" <> arch) ->
        "-" <> arch

      true ->
        ""
    end
  end

  defp drop_spare(label, job) do
    if spare?(job), do: String.replace_suffix(label, "-spare", ""), else: label
  end

  @doc "What a hint is based on."
  def basis(%Hint{runs: 1}), do: "From this job's last run."
  def basis(%Hint{runs: n}), do: "From the last #{n} runs of this job."

  @doc "A badge colour for the kind of hint."
  def color(%Hint{kind: kind}) when kind in [:smaller, :custom], do: "emerald"
  def color(%Hint{kind: :larger}), do: "amber"
  def color(%Hint{kind: :faster}), do: "running"
  def color(_hint), do: "zinc"

  attr :hint, Hint, required: true
  attr :job, :any, default: nil, doc: "a job of the hint's, for the label's arch"
  attr :admin, :boolean, default: false
  attr :repo, :any, default: nil, doc: "the job's repo, for the workflow file's link"
  attr :workflow_path, :string, default: nil, doc: "the run's `path`, as GitHub gives it"

  attr :issue, :map, default: nil, doc: "the hint's issue (`CrewWeb.SizingIssue`), if it has one"

  attr :dismissal, :any,
    default: nil,
    doc: "the hint's `Crew.Sizing.Dismissal`, if it's dismissed"

  attr :dismissing, :boolean, default: false, doc: "an admin has the dismiss form open"

  @doc """
  A hint in full: the headline, the move, why, and how: the `runs-on`
  line, its file, and an issue to file for it.
  """
  def hint_details(assigns) do
    assigns =
      assign(assigns,
        label: runs_on(assigns.hint.to, assigns.job),
        file: GitHub.workflow_file(assigns.workflow_path),
        file_url: assigns.repo && GitHub.workflow_url(assigns.repo, assigns.workflow_path)
      )

    ~H"""
    <div class="space-y-3">
      <div>
        <p class="text-sm font-medium text-ink">{title(@hint)}</p>
        <p :if={@hint.to} class="mt-0.5 text-xs text-ink-3">
          {shape(@hint.from)} → {shape(@hint.to)}<span :if={saving(@hint)}>, {saving(@hint)}</span>
        </p>
      </div>
      <ul class="space-y-1 text-xs text-ink-2">
        <li :for={reason <- @hint.reasons}>{reason}</li>
      </ul>
      <div :if={@label} class="flex flex-wrap items-baseline gap-x-2 gap-y-1">
        <code class="block w-fit rounded-md border border-line bg-subtle px-2 py-1 font-mono text-xs text-ink">runs-on: {@label}</code>
        <p :if={@file_url} class="min-w-0 text-xs text-ink-3">
          in <.gh_link href={@file_url} class="break-all font-mono text-ink-2">{@file}</.gh_link>
        </p>
      </div>
      <.issue_actions :if={@issue && !@dismissal} id="sizing-issue" issue={@issue} />
      <div
        :if={@dismissal}
        id="sizing-dismissed"
        class="flex flex-wrap items-baseline justify-between gap-x-3 gap-y-1 rounded-lg bg-subtle px-3 py-2 text-xs text-ink-2"
      >
        <p class="min-w-0">{dismissed_by(@dismissal)}</p>
        <.restore_button :if={@admin} dismissal={@dismissal} />
      </div>
      <div :if={@admin && !@dismissal && @hint.kind != :fits && @job}>
        <.dismiss_button :if={!@dismissing} job_id={@job.id} />
        <.dismiss_form :if={@dismissing} id="sizing-dismiss" job_id={@job.id} hint={@hint} />
      </div>
      <p :if={@hint.kind == :custom} class="text-xs text-ink-3">
        <%= if @admin do %>
          Add it on <.link navigate="/admin/sizes" class="underline underline-offset-2 hover:text-ink">Sizes & labels</.link>, then use it in the job's <code class="font-mono">runs-on</code>.
        <% else %>
          An admin can add it on Sizes & labels.
        <% end %>
      </p>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :issue, :map, required: true, doc: "from `CrewWeb.SizingIssue.for_hint/2`"
  attr :compact, :boolean, default: false, doc: "text links, for a row in a list of hints"
  attr :label, :string, default: "File issue"

  attr :align, :string,
    default: "end",
    values: ~w(start end),
    doc: "where compact links sit from sm up"

  attr :class, :any, default: nil

  @doc """
  An issue for a hint or a repo's hints: a link to GitHub's new-issue
  form, filled in, and a button that copies the same title and body as
  Markdown.
  """
  def issue_actions(assigns) do
    assigns = assign(assigns, markdown: SizingIssue.markdown(assigns.issue))

    ~H"""
    <div
      :if={@compact}
      id={@id}
      class={[
        "flex flex-wrap items-center gap-x-3 gap-y-1 text-xs",
        @align == "end" && "sm:justify-end",
        @class
      ]}
    >
      <.gh_link href={@issue.url} class="whitespace-nowrap text-ink-2">{@label}</.gh_link>
      <button
        type="button"
        id={"#{@id}-copy"}
        phx-hook="Copy"
        data-copy={@markdown}
        class="text-left text-ink-2 underline-offset-2 transition-colors hover:text-ink hover:underline"
      >
        <span data-copy-label>Copy as Markdown</span>
      </button>
    </div>
    <div :if={!@compact} id={@id} class={["flex flex-wrap items-center gap-2", @class]}>
      <.button
        size="sm"
        href={@issue.url}
        target="_blank"
        rel="noopener noreferrer"
        icon="hero-arrow-top-right-on-square-micro"
      >
        {@label}
      </.button>
      <.button
        size="sm"
        type="button"
        id={"#{@id}-copy"}
        phx-hook="Copy"
        data-copy={@markdown}
        icon="hero-clipboard-document-micro"
      >
        <span data-copy-label>Copy as Markdown</span>
      </.button>
    </div>
    """
  end

  @doc "Who dismissed a hint, when, and why."
  def dismissed_by(%{user_login: login, updated_at: at, reason: reason}) do
    base = "Dismissed by #{login || "someone"} on #{Calendar.strftime(at, "%b %-d")}"
    if reason, do: "#{base}: #{reason}", else: base <> "."
  end

  attr :job_id, :string, required: true

  @doc "Opens the form to dismiss the hint of a job (admins)."
  def dismiss_button(assigns) do
    ~H"""
    <button
      type="button"
      phx-click="dismissing"
      phx-value-job={@job_id}
      class="whitespace-nowrap text-xs text-ink-2 underline-offset-2 transition-colors hover:text-ink hover:underline"
    >
      Dismiss
    </button>
    """
  end

  attr :id, :string, required: true
  attr :job_id, :string, required: true
  attr :hint, Hint, required: true, doc: "the hint it dismisses, so a changed one isn't"
  attr :class, :any, default: nil

  @doc "Dismisses a job's hint, with an optional reason, or calls it off."
  def dismiss_form(assigns) do
    ~H"""
    <form id={@id} phx-submit="dismiss_hint" class={["flex flex-wrap items-center gap-2", @class]}>
      <input type="hidden" name="job_id" value={@job_id} />
      <input type="hidden" name="kind" value={@hint.kind} />
      <input type="hidden" name="vcpus" value={@hint.from.vcpus} />
      <input type="hidden" name="memory_mib" value={@hint.from.memory_mib} />
      <input
        type="text"
        name="reason"
        maxlength="500"
        placeholder="Why? (optional)"
        aria-label="Why dismiss it (optional)"
        phx-mounted={JS.focus()}
        class="input h-8 min-w-0 flex-1 basis-48 text-xs sm:max-w-sm"
      />
      <div class="flex gap-2">
        <.button type="submit" size="sm">Dismiss</.button>
        <.button type="button" size="sm" variant="ghost" phx-click="dismissing">Cancel</.button>
      </div>
    </form>
    """
  end

  attr :dismissal, :any, required: true

  def restore_button(assigns) do
    ~H"""
    <button
      type="button"
      phx-click="restore_hint"
      phx-value-id={@dismissal.id}
      class="whitespace-nowrap text-xs text-ink-2 underline-offset-2 transition-colors hover:text-ink hover:underline"
    >
      Restore
    </button>
    """
  end

  attr :id, :string, default: "sizing-dismissed"
  attr :hints, :list, required: true, doc: "dismissed hints, each with its `dismissal`"
  attr :open, :boolean, default: false
  attr :admin, :boolean, default: false
  attr :repo, :boolean, default: false, doc: "name each hint's repo"

  @doc """
  The hints an admin dismissed, under a page's list: how many, and when
  opened, each with who dismissed it, when and why, and Restore for
  admins.
  """
  def dismissed_list(assigns) do
    ~H"""
    <div :if={@hints != []} class="mt-3 border-t border-line pt-3">
      <button
        type="button"
        id={"#{@id}-toggle"}
        phx-click="toggle_dismissed"
        aria-expanded={to_string(@open)}
        aria-controls={@id}
        class="inline-flex items-center gap-1 text-xs font-medium text-ink-2 transition-colors hover:text-ink"
      >
        <.icon
          name={if @open, do: "hero-chevron-down-micro", else: "hero-chevron-right-micro"}
          class="size-3.5"
        />
        {length(@hints)} dismissed
      </button>
      <ul :if={@open} id={@id} class="mt-1 divide-y divide-line">
        <li
          :for={h <- @hints}
          id={"#{@id}-#{h.job.id}"}
          class="flex flex-wrap items-start justify-between gap-x-6 gap-y-1 py-2.5"
        >
          <div class="min-w-0">
            <.link
              navigate={
                ~p"/runs/#{h.job.github_run_id}/attempts/#{h.job.run_attempt}/jobs/#{h.job.github_id}"
              }
              class="text-sm font-medium text-ink underline-offset-2 hover:underline"
            >
              {h.workflow_name} · {h.name}
            </.link>
            <span :if={@repo} class="ml-1 text-xs text-ink-3">{h.repo.full_name}</span>
            <p class="mt-0.5 text-xs text-ink-2">{title(h.hint)}, from {shape(h.hint.from)}</p>
            <p class="mt-0.5 text-xs text-ink-3">{dismissed_by(h.dismissal)}</p>
          </div>
          <.restore_button :if={@admin} dismissal={h.dismissal} />
        </li>
      </ul>
    </div>
    """
  end
end
