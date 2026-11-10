defmodule CrewWeb.SizingComponents do
  @moduledoc """
  Right-sizing hints (§7.5) as the job and repo pages show them: what to
  move to, why, the `runs-on` line that does it, and an issue to file.
  """
  use Phoenix.Component

  import CrewWeb.CoreComponents, only: [button: 1]
  import CrewWeb.CrewComponents, only: [gib: 1, gh_link: 1]

  alias Crew.Sizing.Rules.Hint
  alias CrewWeb.{GitHub, SizingIssue}

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
      <.issue_actions :if={@issue} id="sizing-issue" issue={@issue} />
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

  @doc """
  A hint's issue: a link to GitHub's new-issue form, filled in, and a
  button that copies the same title and body as Markdown.
  """
  def issue_actions(assigns) do
    assigns = assign(assigns, markdown: SizingIssue.markdown(assigns.issue))

    ~H"""
    <div
      :if={@compact}
      id={@id}
      class="flex flex-wrap items-center gap-x-3 gap-y-1 text-xs sm:justify-end"
    >
      <.gh_link href={@issue.url} class="text-ink-2">File issue</.gh_link>
      <button
        type="button"
        id={"#{@id}-copy"}
        phx-hook="Copy"
        data-copy={@markdown}
        class="text-ink-2 underline-offset-2 transition-colors hover:text-ink hover:underline"
      >
        <span data-copy-label>Copy as Markdown</span>
      </button>
    </div>
    <div :if={!@compact} id={@id} class="flex flex-wrap items-center gap-2">
      <.button
        size="sm"
        href={@issue.url}
        target="_blank"
        rel="noopener noreferrer"
        icon="hero-arrow-top-right-on-square-micro"
      >
        File issue
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
end
