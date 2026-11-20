defmodule CrewProtocol.Labels do
  @moduledoc """
  The label grammar (§7.2) and label aliases (§7.3).

  A job opts into Crew with exactly one Crew label:

      crew                 default size, any arch
      crew-<size>          that size, any arch
      crew-<arch>          default size, that arch
      crew-<size>-<arch>   that size and arch            <arch> ∈ { x64, arm64 }

  next to labels from the generic set `{self-hosted, linux, x64, arm64}`.
  Any of the four takes a `-spare` suffix, always last (`crew-l-spare`,
  `crew-l-arm64-spare`): the job runs on spare capacity (§7.2).

  A label that parsed before the suffix existed parses the same way, so a
  size named `spare` or `x-spare` keeps its label. Only a Crew label whose
  size is unknown and that ends in `-spare` is parsed again without it.

  `parse/3` lowercases, deduplicates and sorts the labels into the
  **label key**: a runner for the class is registered with exactly that
  key as its labels.
  """

  @generic ~w(self-hosted linux x64 arm64)
  @arches %{"x64" => :x64, "arm64" => :arm64}

  @type size :: %{
          required(:id) => term(),
          required(:name) => String.t(),
          optional(atom()) => term()
        }
  @type label_alias :: %{labels: [String.t()], size_id: term(), arch: :any | :x64 | :arm64}
  @type parsed :: %{
          size_id: term(),
          arch: :any | :x64 | :arm64,
          key: [String.t()],
          alias: boolean(),
          spare: boolean()
        }

  @doc "The label key: lowercased, deduplicated and sorted."
  @spec key([String.t()]) :: [String.t()]
  def key(labels), do: labels |> Enum.map(&String.downcase/1) |> Enum.uniq() |> Enum.sort()

  def crew_label?(label), do: label == "crew" or String.starts_with?(label, "crew-")

  @spec parse([String.t()], [size()], [label_alias()]) ::
          {:ours, parsed()} | :not_ours | {:unsatisfiable, String.t()}
  def parse(labels, sizes, aliases) do
    key = key(labels)

    case Enum.split_with(key, &crew_label?/1) do
      {[], _} -> parse_alias(key, sizes, aliases)
      {[crew], others} -> parse_crew(crew, others, key, sizes)
      {_, _} -> {:unsatisfiable, "more than one Crew label"}
    end
  end

  defp parse_alias(key, sizes, aliases) do
    case Enum.find(aliases, &(key(&1.labels) == key)) do
      nil ->
        :not_ours

      %{size_id: size_id, arch: arch} ->
        case Enum.find(sizes, &(&1.id == size_id)) do
          nil -> {:unsatisfiable, "the alias's size no longer exists"}
          %{retired: true, name: name} -> {:unsatisfiable, "size #{name} retired"}
          _ -> {:ours, %{size_id: size_id, arch: arch, key: key, alias: true, spare: false}}
        end
    end
  end

  defp parse_crew(crew, others, key, sizes) do
    case parse_crew_label(crew, others, key, sizes) do
      {:unknown_size, name} -> parse_spare(crew, name, others, key, sizes)
      result -> result
    end
  end

  # Today's parse of one Crew label, with an unknown size left for the
  # -spare checks.
  defp parse_crew_label(crew, others, key, sizes) do
    with :ok <- only_generic(crew, others),
         {size_name, crew_arch} = split(crew),
         {:ok, size} <- find_size(size_name, sizes),
         {:ok, arch} <- arch(crew_arch, others) do
      {:ours, %{size_id: size.id, arch: arch, key: key, alias: false, spare: false}}
    end
  end

  # The size didn't parse. A label ending in -spare is parsed again
  # without it, and that result stands; one with -spare before its arch
  # is told where it goes.
  defp parse_spare(crew, size_name, others, key, sizes) do
    cond do
      String.ends_with?(crew, "-spare") ->
        case parse_crew_label(String.replace_suffix(crew, "-spare", ""), others, key, sizes) do
          {:ours, parsed} -> {:ours, %{parsed | spare: true}}
          {:unknown_size, name} -> unknown_size(name)
          result -> result
        end

      label = misplaced_spare(crew, size_name, sizes) ->
        {:unsatisfiable, "-spare goes last: #{label}"}

      true ->
        unknown_size(size_name)
    end
  end

  # crew-l-spare-arm64 → crew-l-arm64-spare, when l is a size; and
  # crew-spare-arm64 → crew-arm64-spare.
  defp misplaced_spare(crew, size_name, sizes) do
    with {_, arch} when arch != :any <- split(crew),
         {:ok, base} <- without_spare(size_name, sizes) do
      "#{base}-#{arch}-spare"
    else
      _ -> nil
    end
  end

  defp without_spare("spare", _sizes), do: {:ok, "crew"}

  defp without_spare(size_name, sizes) do
    name = String.replace_suffix(size_name, "-spare", "")
    if name != size_name and Enum.any?(sizes, &(&1.name == name)), do: {:ok, "crew-" <> name}
  end

  defp unknown_size(name), do: {:unsatisfiable, "unknown size #{name}"}

  defp only_generic(crew, others) do
    case Enum.reject(others, &(&1 in @generic)) do
      [] -> :ok
      [other | _] -> {:unsatisfiable, "#{crew} can't be combined with #{other}"}
    end
  end

  # "crew" | "crew-<arch>" | "crew-<size>" | "crew-<size>-<arch>"
  defp split("crew"), do: {:default, :any}

  defp split("crew-" <> rest) do
    case Map.fetch(@arches, rest) do
      {:ok, arch} ->
        {:default, arch}

      :error ->
        Enum.find_value(@arches, {rest, :any}, fn {suffix, arch} ->
          if String.ends_with?(rest, "-" <> suffix),
            do: {String.replace_suffix(rest, "-" <> suffix, ""), arch}
        end)
    end
  end

  defp find_size(:default, sizes) do
    case Enum.find(sizes, &(&1[:is_default] && !&1[:retired])) do
      nil -> {:unsatisfiable, "no default size"}
      size -> {:ok, size}
    end
  end

  defp find_size(name, sizes) do
    case Enum.find(sizes, &(&1.name == name)) do
      nil -> {:unknown_size, name}
      %{retired: true} -> {:unsatisfiable, "size #{name} retired"}
      size -> {:ok, size}
    end
  end

  defp arch(crew_arch, others) do
    generic_arches = others |> Enum.flat_map(&List.wrap(@arches[&1])) |> Enum.uniq()

    case {crew_arch, generic_arches} do
      {arch, []} -> {:ok, arch}
      {:any, [arch]} -> {:ok, arch}
      {arch, [arch]} -> {:ok, arch}
      _ -> {:unsatisfiable, "contradictory arch labels"}
    end
  end

  @doc """
  Reads a `runs-on` value as someone would paste it into the label
  tester: a single label, a YAML flow list, or a block list, with or
  without the `runs-on:` key, quoted or not.
  """
  def parse_runs_on(text) when is_binary(text) do
    text
    |> String.replace(~r/^\s*runs-on:\s*/m, "")
    |> String.replace(["[", "]"], " ")
    |> String.split(~r/[,\n]/)
    |> Enum.map(&unquote_label/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp unquote_label(item) do
    item = item |> String.trim() |> String.replace_prefix("- ", "") |> String.trim()

    case item do
      <<q, rest::binary>> when q in [?", ?'] ->
        if String.ends_with?(rest, <<q>>), do: String.slice(rest, 0..-2//1), else: rest

      _ ->
        item
    end
    |> String.trim()
  end
end
