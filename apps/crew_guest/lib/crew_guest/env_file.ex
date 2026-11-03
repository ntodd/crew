defmodule CrewGuest.EnvFile do
  @moduledoc "`KEY=VALUE` files: `/etc/environment`, the runner's `.env`, `guest.env`."

  @doc """
  Sets `vars` in the text of a `KEY=VALUE` file, keeping every other line
  as it was. Setting the same vars twice leaves one copy of each.
  """
  @spec merge(String.t(), [{String.t(), String.t()}]) :: String.t()
  def merge(existing, vars) do
    keys = MapSet.new(vars, &elem(&1, 0))

    kept =
      existing
      |> String.split("\n")
      |> drop_trailing_blank()
      |> Enum.reject(&MapSet.member?(keys, key(&1)))

    Enum.map_join(kept ++ Enum.map(vars, fn {k, v} -> "#{k}=#{v}" end), "", &(&1 <> "\n"))
  end

  @doc "`KEY='value'` lines that `sh` can source safely."
  @spec shell([{String.t(), String.t()}]) :: String.t()
  def shell(vars), do: Enum.map_join(vars, "", fn {k, v} -> "#{k}=#{quote_sh(v)}\n" end)

  @doc "Single-quotes a value for `sh`."
  def quote_sh(value), do: "'" <> String.replace(value, "'", ~S('\'')) <> "'"

  defp key(line) do
    case String.split(String.trim_leading(line), "=", parts: 2) do
      [key, _value] -> key |> String.trim_leading("export ") |> String.trim()
      _ -> nil
    end
  end

  defp drop_trailing_blank(lines) do
    lines |> Enum.reverse() |> Enum.drop_while(&(&1 == "")) |> Enum.reverse()
  end
end
