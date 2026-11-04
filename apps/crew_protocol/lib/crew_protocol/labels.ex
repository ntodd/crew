defmodule CrewProtocol.Labels do
  @moduledoc """
  The label grammar (§7.2) and label aliases (§7.3).

  A job opts into Crew with exactly one Crew label:

      crew                 default size, any arch
      crew-<size>          that size, any arch
      crew-<arch>          default size, that arch
      crew-<size>-<arch>   that size and arch            <arch> ∈ { x64, arm64 }

  next to labels from the generic set `{self-hosted, linux, x64, arm64}`.

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
          alias: boolean()
        }

  def generic, do: @generic

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
          _ -> {:ours, %{size_id: size_id, arch: arch, key: key, alias: true}}
        end
    end
  end

  defp parse_crew(crew, others, key, sizes) do
    with :ok <- only_generic(crew, others),
         {size_name, crew_arch} = split(crew),
         {:ok, size} <- find_size(size_name, sizes),
         {:ok, arch} <- arch(crew_arch, others) do
      {:ours, %{size_id: size.id, arch: arch, key: key, alias: false}}
    end
  end

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
      nil -> {:unsatisfiable, "unknown size #{name}"}
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
