defmodule Crew.Logs.Index do
  @moduledoc """
  A log's index, kept next to it as `index.json` and updated as lines are
  written: what the job page needs before it has the lines (§17.6).

  - `steps`: each step's first line, by `step_ref`;
  - `groups`: `[start, end | nil, title]` for `::group::`/`##[group]` up
    to the matching end; the runner doesn't nest them, so a new group
    closes an open one. The first 1000 groups are kept;
  - `annotations`: `::error`, `::warning` and `::notice` (and the
    runner's `##[error]` forms), at most #{1000}.
  """

  @max_groups 1000
  @max_annotations 1000
  @ansi ~r/\e(?:\[[0-?]*[ -\/]*[@-~]|\][^\a\e]*(?:\a|\e\\)|[@-Z\\-_])/
  @group ~r/\A(?:::group::|##\[group\])(.*)\z/s
  @endgroup ~r/\A(?:::endgroup::|##\[endgroup\])/
  @annotation ~r/\A(?:::(error|warning|notice)(?:\s(.*?))?::|##\[(error|warning|notice)\])(.*)\z/s

  defstruct steps: %{}, groups_rev: [], group_count: 0, annotations: [], open: nil

  def new, do: %__MODULE__{}

  @doc "The retained groups in log order, including the currently open group."
  def groups(index), do: Enum.reverse(index.groups_rev)

  @doc "The index with `lines` (in order) added."
  def add(%__MODULE__{} = index, lines), do: Enum.reduce(lines, index, &add_line/2)

  defp add_line(%{n: n} = line, index) when is_integer(n) do
    index = step(index, line)
    text = String.replace(line.text, @ansi, "")

    cond do
      match = Regex.run(@group, text) -> open_group(index, n, String.trim(Enum.at(match, 1)))
      Regex.match?(@endgroup, text) -> close_group(index, n)
      true -> annotate(index, n, text)
    end
  end

  defp add_line(_line, index), do: index

  defp step(index, %{step_ref: ref, n: n}) when is_binary(ref),
    do: %{index | steps: Map.put_new(index.steps, ref, n)}

  defp step(index, _line), do: index

  defp open_group(index, n, title) do
    index = close_group(index, n - 1)

    if index.group_count == @max_groups do
      index
    else
      %{
        index
        | groups_rev: [[n, nil, title] | index.groups_rev],
          group_count: index.group_count + 1,
          open: n
      }
    end
  end

  defp close_group(%{open: nil} = index, _n), do: index

  defp close_group(%{groups_rev: [[start, nil, title] | rest]} = index, n) do
    %{index | groups_rev: [[start, n, title] | rest], open: nil}
  end

  defp annotate(index, n, text) do
    with true <- length(index.annotations) < @max_annotations,
         [_ | parts] <- Regex.run(@annotation, text) do
      [level1, props, level2, message] = pad(parts, 4)
      props = parse_props(props)

      annotation = %{
        n: n,
        level: if(level1 != "", do: level1, else: level2),
        text: String.trim(message),
        file: props["file"],
        line: props["line"] && parse_int(props["line"])
      }

      %{index | annotations: index.annotations ++ [annotation]}
    else
      _ -> index
    end
  end

  defp pad(list, n), do: list ++ List.duplicate("", n - length(list))

  defp parse_props(""), do: %{}

  defp parse_props(props) do
    props
    |> String.split(",", trim: true)
    |> Enum.flat_map(fn kv ->
      case String.split(kv, "=", parts: 2) do
        [k, v] -> [{String.trim(k), String.trim(v)}]
        _ -> []
      end
    end)
    |> Map.new()
  end

  defp parse_int(text) do
    case Integer.parse(text) do
      {n, _} -> n
      :error -> nil
    end
  end

  # -- storage -----------------------------------------------------------------------

  def encode(%__MODULE__{} = index),
    do:
      Jason.encode!(%{
        steps: index.steps,
        groups: groups(index),
        annotations: index.annotations,
        open: index.open
      })

  def decode(json) do
    case Jason.decode(json) do
      {:ok, map} ->
        groups = (map["groups"] || []) |> Enum.take(@max_groups) |> Enum.reverse()

        open =
          case groups do
            [[start, nil, _] | _] -> start
            _ -> nil
          end

        %__MODULE__{
          steps: map["steps"] || %{},
          groups_rev: groups,
          group_count: length(groups),
          annotations:
            Enum.map(map["annotations"] || [], fn a ->
              %{n: a["n"], level: a["level"], text: a["text"], file: a["file"], line: a["line"]}
            end),
          open: open
        }

      _ ->
        new()
    end
  end
end
