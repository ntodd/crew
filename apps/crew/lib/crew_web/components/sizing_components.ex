defmodule CrewWeb.SizingComponents do
  @moduledoc """
  Right-sizing hints (§7.5) as the job and repo pages show them: what to
  move to, why, and the `runs-on` line that does it.
  """
  use Phoenix.Component

  import CrewWeb.CrewComponents, only: [gib: 1, gh_link: 1]

  alias Crew.Sizing.Rules.Hint
  alias CrewWeb.GitHub

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
  The `runs-on` label for a size, keeping the job's arch when it named
  one (`crew-s-arm64`).
  """
  def label(%{name: name}, job) when is_binary(name) do
    arch = job && job.arch

    suffix =
      if arch in ["x64", "arm64"] and
           Enum.any?(job.labels || [], &String.ends_with?(&1, "-" <> arch)),
         do: "-" <> arch,
         else: ""

    "crew-#{name}#{suffix}"
  end

  def label(_size, _job), do: nil

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

  @doc "A hint in full: the headline, the move, why, and how: the `runs-on` line and its file."
  def hint_details(assigns) do
    assigns =
      assign(assigns,
        label: label(assigns.hint.to, assigns.job),
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
end
