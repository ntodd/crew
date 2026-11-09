defmodule CrewProtocol.LabelsPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias CrewProtocol.{Labels, Sizes}

  # The parse as it was before the -spare suffix, kept as the oracle for
  # "a label that parses today parses the same way afterwards".
  defmodule Before do
    @moduledoc false
    @generic ~w(self-hosted linux x64 arm64)
    @arches %{"x64" => :x64, "arm64" => :arm64}

    def parse(labels, sizes, aliases) do
      key = Labels.key(labels)

      case Enum.split_with(key, &Labels.crew_label?/1) do
        {[], _} -> parse_alias(key, sizes, aliases)
        {[crew], others} -> parse_crew(crew, others, key, sizes)
        {_, _} -> {:unsatisfiable, "more than one Crew label"}
      end
    end

    defp parse_alias(key, sizes, aliases) do
      case Enum.find(aliases, &(Labels.key(&1.labels) == key)) do
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
  end

  @arch_names ["x64", "arm64"]

  # A lowercase DNS label of 1 to 12 characters, the shape of a size name
  # before the name rules (§7.1).
  defp dns_label do
    gen all(
          first <- member_of(~c"abcdefghijklmnopqrstuvwxyz0123456789"),
          middle <- list_of(member_of(~c"abcdefghijklmnopqrstuvwxyz0123456789-"), max_length: 10),
          last <- member_of(~c"abcdefghijklmnopqrstuvwxyz0123456789")
        ) do
      List.to_string([first | middle] ++ [last])
    end
  end

  defp valid_name do
    filter(dns_label(), &is_nil(Sizes.name_error(&1)))
  end

  # Names that collide with the suffix or the arches, as sizes made before
  # the rule may have.
  defp any_name do
    one_of([
      valid_name(),
      member_of(["spare", "l-spare", "x-spare", "s-x64-spare", "m", "l", "spare-arm64"]),
      map(valid_name(), &(&1 <> "-spare"))
    ])
  end

  defp size_table(name_gen) do
    gen all(
          names <- uniq_list_of(name_gen, min_length: 1, max_length: 6),
          retired <- list_of(boolean(), length: length(names)),
          default <- integer(-1..(length(names) - 1))
        ) do
      for {{name, r}, i} <- names |> Enum.zip(retired) |> Enum.with_index() do
        %{id: "id-" <> name, name: name, is_default: i == default, retired: r}
      end
    end
  end

  property "-spare after any valid Crew label gives the same size and arch, spare" do
    check all(
            sizes <- size_table(valid_name()),
            chosen <- valid_name(),
            crew_arch <- member_of([nil | @arch_names]),
            generic <- list_of(member_of(["self-hosted", "linux"]), max_length: 2),
            repeat_arch <- boolean()
          ) do
      sizes =
        [%{id: "id-" <> chosen, name: chosen, is_default: false, retired: false}] ++
          Enum.reject(sizes, &(&1.name == chosen))

      refute Enum.any?(sizes, &(&1.name == "spare" or String.ends_with?(&1.name, "-spare")))

      crew = Enum.join(["crew", chosen] ++ List.wrap(crew_arch), "-")
      arch_labels = if repeat_arch and crew_arch, do: [crew_arch], else: []
      regular = [crew | generic] ++ arch_labels
      spare = [crew <> "-spare" | generic] ++ arch_labels

      assert {:ours, r} = Labels.parse(regular, sizes, [])
      assert {:ours, s} = Labels.parse(spare, sizes, [])
      assert r.spare == false
      assert s.spare == true
      assert s.size_id == "id-" <> chosen
      assert {s.size_id, s.arch} == {r.size_id, r.arch}
      assert s.key == Labels.key(spare)
      assert (crew <> "-spare") in s.key
    end
  end

  property "-spare after the default size's labels gives the default, spare" do
    check all(
            sizes <- size_table(valid_name()),
            crew_arch <- member_of([nil | @arch_names])
          ) do
      sizes = [%{id: "default", name: "zz0", is_default: true, retired: false} | sizes]
      sizes = Enum.map(sizes, &if(&1.id == "default", do: &1, else: %{&1 | is_default: false}))
      crew = Enum.join(["crew" | List.wrap(crew_arch)], "-")

      assert {:ours, %{size_id: "default", spare: true} = s} =
               Labels.parse([crew <> "-spare"], sizes, [])

      assert s.arch == if(crew_arch, do: String.to_atom(crew_arch), else: :any)
    end
  end

  property "a label set that parses today parses the same way, regular; other failures stay" do
    check all(
            sizes <- size_table(any_name()),
            aliases <- alias_list(sizes),
            labels <- label_set(sizes),
            max_runs: 500
          ) do
      # Only an unknown size can parse differently now.
      case Before.parse(labels, sizes, aliases) do
        {:ours, parsed} ->
          assert Labels.parse(labels, sizes, aliases) == {:ours, Map.put(parsed, :spare, false)}

        {:unsatisfiable, "unknown size " <> _} ->
          :ok

        other ->
          assert Labels.parse(labels, sizes, aliases) == other
      end
    end
  end

  defp alias_list(sizes) do
    list_of(
      gen all(
            labels <-
              list_of(member_of(["self-hosted", "linux", "x64", "spare", "gpu"]), max_length: 3),
            size <- member_of(sizes),
            arch <- member_of([:any, :x64, :arm64])
          ) do
        %{labels: labels, size_id: size.id, arch: arch}
      end,
      max_length: 2
    )
  end

  defp crew_label(sizes) do
    gen all(
          size <- one_of([constant(nil), map(member_of(sizes), & &1.name), any_name()]),
          arch <- member_of([nil | @arch_names]),
          suffix <- member_of([nil, "spare"]),
          order <- boolean()
        ) do
      parts = [size, arch, suffix] |> Enum.reject(&is_nil/1)
      parts = if order, do: parts, else: Enum.reverse(parts)
      Enum.join(["crew" | parts], "-")
    end
  end

  defp label_set(sizes) do
    gen all(
          crews <- list_of(crew_label(sizes), max_length: 2),
          others <-
            list_of(member_of(["self-hosted", "linux", "x64", "arm64", "spare", "gpu"]),
              max_length: 3
            )
        ) do
      crews ++ others
    end
  end
end
