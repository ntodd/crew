defmodule Crew.Jobs.Classify do
  @moduledoc """
  A job's classification from its labels and the static checks (§8.2):
  the labels don't parse; the size is retired or not allowed for the
  repo; the repo is missing an App permission Crew needs; the run is a
  fork PR on a repo that refuses them. A disabled repo's jobs aren't
  ours at all.

  Pure: everything it needs is passed in.
  """

  alias CrewProtocol.Labels

  @type result :: %{
          classification: String.t(),
          unsatisfiable_reason: String.t() | nil,
          label_key: [String.t()],
          size_id: term(),
          arch: String.t() | nil,
          aliased: boolean(),
          spare: boolean()
        }

  @doc """
  `context` has `:repo`, `:sizes` and `:aliases` (as `Labels.parse/3`
  takes them), `:missing_permissions` and `:fork` (`true`, `false` or
  `nil` while unknown).
  """
  @spec classify([String.t()], map()) :: result()
  def classify(labels, context) do
    key = Labels.key(labels)

    base = %{
      label_key: key,
      size_id: nil,
      arch: nil,
      aliased: false,
      spare: false,
      unsatisfiable_reason: nil
    }

    if context.repo.enabled do
      parsed(Labels.parse(labels, context.sizes, context.aliases), base, context)
    else
      Map.put(base, :classification, "not_ours")
    end
  end

  defp parsed(result, base, context) do
    case result do
      :not_ours ->
        Map.put(base, :classification, "not_ours")

      {:unsatisfiable, reason} ->
        unsatisfiable(base, reason)

      {:ours, parsed} ->
        parsed_base = %{
          base
          | size_id: parsed.size_id,
            arch: Atom.to_string(parsed.arch),
            aliased: parsed.alias,
            spare: parsed.spare
        }

        case static_reason(parsed, context) do
          nil -> Map.put(parsed_base, :classification, "ours")
          reason -> unsatisfiable(parsed_base, reason)
        end
    end
  end

  defp unsatisfiable(base, reason),
    do: %{base | unsatisfiable_reason: reason} |> Map.put(:classification, "unsatisfiable")

  defp static_reason(parsed, context) do
    size_name = Enum.find_value(context.sizes, &(&1.id == parsed.size_id && &1.name))
    allowed = context.repo.allowed_sizes

    cond do
      allowed != nil and size_name not in allowed ->
        "size #{size_name} not allowed for this repo"

      context.missing_permissions != [] ->
        perms = Enum.map_join(context.missing_permissions, ", ", fn {p, l} -> "#{p} (#{l})" end)
        "the App is missing permissions Crew needs: #{perms}"

      context.fork == true and context.repo.fork_prs == "refuse" ->
        "fork PRs are refused on this repo"

      true ->
        nil
    end
  end
end
