#!/usr/bin/env elixir
# Collects the Machine calls recorded in Quint ITF traces of
# models/vm_lifecycle.qnt into one JSON file for
# apps/crew/test/crew/vms/machine_replay_test.exs.
#
#   quint run models/vm_lifecycle.qnt --invariant=safe --mbt --seed=0x1 \
#     --max-samples=400 --max-steps=80 --n-traces=400 \
#     --out-itf=/tmp/traces/t{seq}.itf.json
#   elixir models/export_steps.exs \
#     apps/crew/test/fixtures/quint/vm_lifecycle_steps.json /tmp/traces/*.itf.json
#
# Each step is {before, event, after, effects, ignored}, with ITF's
# encodings flattened: sets to lists, bigints to integers, unit variants to
# []. Steps are deduplicated and sorted, so the file only changes when the
# model does.

defmodule ExportSteps do
  def run([out | files]) when files != [] do
    steps =
      files
      |> Enum.flat_map(&steps_in/1)
      |> Enum.map(&flatten/1)
      |> Enum.uniq()
      |> Enum.sort_by(&{&1["before"]["state"], &1["event"]["tag"], JSON.encode!(&1)})

    body =
      steps
      |> Enum.map_join(",\n", &("  " <> JSON.encode!(&1)))
      |> then(&("[\n" <> &1 <> "\n]\n"))

    File.mkdir_p!(Path.dirname(out))
    File.write!(out, body)
    IO.puts("#{length(steps)} distinct steps from #{length(files)} traces -> #{out}")
  end

  def run(_), do: IO.puts("usage: elixir models/export_steps.exs OUT.json TRACE.itf.json...")

  defp steps_in(file) do
    %{"states" => states} = file |> File.read!() |> JSON.decode!()
    Enum.flat_map(states, fn %{"S" => %{"steps" => steps}} -> steps end)
  end

  defp flatten(%{"#set" => items}), do: Enum.map(items, &flatten/1)
  defp flatten(%{"#tup" => items}), do: Enum.map(items, &flatten/1)
  defp flatten(%{"#bigint" => n}), do: String.to_integer(n)
  defp flatten(%{} = map), do: Map.new(map, fn {k, v} -> {k, flatten(v)} end)
  defp flatten(list) when is_list(list), do: Enum.map(list, &flatten/1)
  defp flatten(other), do: other
end

ExportSteps.run(System.argv())
