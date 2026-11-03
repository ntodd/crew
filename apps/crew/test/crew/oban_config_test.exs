defmodule Crew.ObanConfigTest do
  use ExUnit.Case, async: true

  @plugins Application.compile_env!(:crew, [Oban, :plugins])

  defp pruner_max_age do
    Enum.find_value(@plugins, fn
      {Oban.Plugins.Pruner, opts} -> Keyword.fetch!(opts, :max_age)
      _ -> nil
    end)
  end

  test "finished jobs are pruned within an hour" do
    assert pruner_max_age() <= 3600
  end

  # Uniqueness looks at finished jobs too, so pruning one sooner than its
  # unique period would let a duplicate in.
  test "finished jobs outlive every worker's unique period" do
    {:ok, modules} = :application.get_key(:crew, :modules)

    periods =
      for module <- modules,
          Code.ensure_loaded?(module),
          function_exported?(module, :__opts__, 0),
          period = get_in(module.__opts__(), [:unique, :period]),
          is_integer(period),
          do: {module, period}

    assert periods != []

    for {module, period} <- periods,
        do: assert(period <= pruner_max_age(), "#{inspect(module)} is unique for #{period}s")
  end
end
