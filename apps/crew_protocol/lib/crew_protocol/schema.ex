defmodule CrewProtocol.Schema do
  @moduledoc """
  A small, strict validator for protocol payloads (Foreman's, extended).

  A spec is a keyword list of `field: {type, opts}`. Casting turns a map
  with string (wire) or atom keys into a map with atom keys, and refuses
  anything the spec doesn't name. Dumping turns it back into string keys.

  Every string has a stated maximum: 4096 bytes unless the field says
  otherwise with `max:`. Out-of-range values are refused, never clamped.

  Options:
    * `required: true`
    * `default: value`
    * `max:` / `min:` for strings and text (bytes), lists (items) and
      numbers (value)
    * `check:` a remote capture `(value -> :ok | {:error, msg} |
      {:error, [{subfield, msg}]})`, run after the value is cast
  """

  @type error :: {String.t(), String.t()}
  @type spec :: keyword({atom() | tuple(), keyword()})

  @uuid ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/
  @slug ~r/\A[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\z/
  @code ~r/\A[a-z][a-z0-9_]{0,63}\z/
  @version ~r/\A\d{1,4}\.\d{1,4}\.\d{1,4}(?:-[0-9A-Za-z.]{1,32})?\z/
  @sha256 ~r/\A[0-9a-f]{64}\z/
  @hex16 ~r/\A[0-9a-f]{16}\z/
  @step_ref ~r/\A[a-zA-Z0-9_-]{1,64}\z/
  @label ~r/\A[a-z0-9][a-z0-9._-]{0,99}\z/
  @hostname ~r/\A[A-Za-z0-9](?:[A-Za-z0-9.-]{0,251}[A-Za-z0-9])?(?::\d{1,5})?\z/
  @repo ~r/\A[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})\/[A-Za-z0-9._-]{1,100}\z/

  @max_string 4096
  @max_text 1_048_576

  @spec cast(term(), spec()) :: {:ok, map()} | {:error, [error()]}
  def cast(input, spec) when is_map(input), do: cast_object(input, spec, "")
  def cast(_input, _spec), do: {:error, [{"", "must be an object"}]}

  @spec dump(map(), spec()) :: map()
  def dump(value, spec) when is_map(value) do
    Enum.reduce(spec, %{}, fn {field, {type, _opts}}, acc ->
      case Map.fetch(value, field) do
        {:ok, v} -> Map.put(acc, Atom.to_string(field), dump_value(v, type))
        :error -> acc
      end
    end)
  end

  defp dump_value(nil, _type), do: nil
  defp dump_value(v, {:object, spec}), do: dump(v, spec)
  defp dump_value(v, {:list, type}), do: Enum.map(v, &dump_value(&1, type))

  defp dump_value(v, {:map_of, _key, type}),
    do: Map.new(v, fn {k, x} -> {k, dump_value(x, type)} end)

  defp dump_value(v, _type) when is_atom(v) and not is_boolean(v), do: Atom.to_string(v)
  defp dump_value(v, _type), do: v

  defp cast_object(input, spec, prefix) do
    known = MapSet.new(spec, fn {field, _} -> Atom.to_string(field) end)

    unknown_errors =
      input
      |> Map.keys()
      |> Enum.map(&key_to_string/1)
      |> Enum.reject(&MapSet.member?(known, &1))
      |> Enum.map(&{path(prefix, &1), "is not allowed"})

    {values, errors} =
      Enum.reduce(spec, {%{}, unknown_errors}, fn {field, {type, opts}}, {acc, errs} ->
        name = Atom.to_string(field)
        p = path(prefix, name)

        case fetch(input, field, name) do
          {:ok, nil} -> missing(acc, errs, field, type, opts, p)
          {:ok, raw} -> put_cast(acc, errs, field, cast_checked(raw, type, opts, p))
          :error -> missing(acc, errs, field, type, opts, p)
        end
      end)

    case errors do
      [] -> {:ok, values}
      errors -> {:error, Enum.reverse(errors)}
    end
  end

  defp missing(acc, errs, field, type, opts, p) do
    cond do
      Keyword.has_key?(opts, :default) ->
        put_cast(acc, errs, field, cast_checked(Keyword.fetch!(opts, :default), type, opts, p))

      Keyword.get(opts, :required, false) ->
        {acc, [{p, "is required"} | errs]}

      true ->
        {acc, errs}
    end
  end

  defp put_cast(acc, errs, field, {:ok, v}), do: {Map.put(acc, field, v), errs}
  defp put_cast(acc, errs, _field, {:error, more}), do: {acc, Enum.reverse(more) ++ errs}

  defp fetch(input, field, name) do
    case Map.fetch(input, name) do
      {:ok, v} -> {:ok, v}
      :error -> Map.fetch(input, field)
    end
  end

  defp key_to_string(k) when is_atom(k), do: Atom.to_string(k)
  defp key_to_string(k) when is_binary(k), do: k
  defp key_to_string(k), do: inspect(k)

  defp path("", name), do: name
  defp path(prefix, name), do: prefix <> "." <> name

  defp err(p, msg), do: {:error, [{p, msg}]}

  defp cast_checked(raw, type, opts, p) do
    with {:ok, v} <- cast_value(raw, type, opts, p),
         :ok <- check_bounds(v, type, opts, p),
         :ok <- run_check(v, opts, p) do
      {:ok, v}
    end
  end

  defp check_bounds(v, type, opts, p) do
    bounds(v, Keyword.get(opts, :max, default_max(type)), Keyword.get(opts, :min), p)
  end

  defp bounds(v, max, _min, p) when is_binary(v) and is_integer(max) and byte_size(v) > max,
    do: err(p, "is too long")

  defp bounds(v, max, min, p) when is_list(v), do: list_bounds(length(v), max, min, p)
  defp bounds(v, max, min, p) when is_number(v), do: number_bounds(v, max, min, p)
  defp bounds(_v, _max, _min, _p), do: :ok

  defp list_bounds(n, max, _min, p) when is_integer(max) and n > max,
    do: err(p, "has more than #{max} items")

  defp list_bounds(n, _max, min, p) when is_integer(min) and n < min,
    do: err(p, "has fewer than #{min} items")

  defp list_bounds(_n, _max, _min, _p), do: :ok

  defp number_bounds(v, max, _min, p) when is_number(max) and v > max,
    do: err(p, "must be at most #{max}")

  defp number_bounds(v, _max, min, p) when is_number(min) and v < min,
    do: err(p, "must be at least #{min}")

  defp number_bounds(_v, _max, _min, _p), do: :ok

  defp default_max(:string), do: @max_string
  defp default_max(:text), do: @max_text
  defp default_max(:base64), do: @max_text
  defp default_max(_), do: nil

  defp run_check(v, opts, p) do
    case Keyword.get(opts, :check) do
      nil ->
        :ok

      fun ->
        case fun.(v) do
          :ok -> :ok
          {:error, msg} when is_binary(msg) -> err(p, msg)
          {:error, list} when is_list(list) -> {:error, Enum.map(list, &sub_error(&1, p))}
        end
    end
  end

  defp sub_error({field, msg}, p), do: {path(p, key_to_string(field)), msg}

  # -- types -----------------------------------------------------------

  defp cast_value(v, {:object, spec}, _opts, p) when is_map(v), do: cast_object(v, spec, p)
  defp cast_value(_v, {:object, _}, _opts, p), do: err(p, "must be an object")

  defp cast_value(v, {:list, type}, opts, p) when is_list(v) do
    max = Keyword.get(opts, :max)

    if is_integer(max) and length(v) > max do
      err(p, "has more than #{max} items")
    else
      cast_list(v, type, p)
    end
  end

  defp cast_value(_v, {:list, _}, _opts, p), do: err(p, "must be a list")

  defp cast_value(v, {:map_of, key_type, value_type}, _opts, p) when is_map(v) do
    Enum.reduce_while(v, {:ok, %{}}, fn {k, x}, {:ok, acc} ->
      with {:ok, key} <- cast_value(key_to_string(k), key_type, [], p),
           {:ok, value} <- cast_value(x, value_type, [], path(p, key)) do
        {:cont, {:ok, Map.put(acc, key, value)}}
      else
        {:error, e} -> {:halt, {:error, e}}
      end
    end)
  end

  defp cast_value(_v, {:map_of, _, _}, _opts, p), do: err(p, "must be an object")

  defp cast_value(v, {:enum, values}, _opts, p) do
    if v in values, do: {:ok, v}, else: err(p, "must be one of: #{Enum.join(values, ", ")}")
  end

  defp cast_value(v, :string, _opts, p) when is_binary(v) do
    cond do
      v == "" -> err(p, "can't be blank")
      not String.valid?(v) -> err(p, "must be UTF-8")
      String.contains?(v, <<0>>) -> err(p, "must not contain NUL bytes")
      true -> {:ok, v}
    end
  end

  # Text may be empty. Senders scrub bytes that aren't UTF-8 first
  # (`CrewProtocol.Text.scrub/1`), since JSON can't carry them.
  defp cast_value(v, :text, _opts, p) when is_binary(v) do
    cond do
      not String.valid?(v) -> err(p, "must be UTF-8")
      String.contains?(v, <<0>>) -> err(p, "must not contain NUL bytes")
      true -> {:ok, v}
    end
  end

  defp cast_value(v, :boolean, _opts, _p) when is_boolean(v), do: {:ok, v}
  defp cast_value(_v, :boolean, _opts, p), do: err(p, "must be a boolean")

  defp cast_value(v, :integer, _opts, _p) when is_integer(v) and v >= 0, do: {:ok, v}
  defp cast_value(_v, :integer, _opts, p), do: err(p, "must be a non-negative integer")

  defp cast_value(v, :int, _opts, _p) when is_integer(v), do: {:ok, v}
  defp cast_value(_v, :int, _opts, p), do: err(p, "must be an integer")

  defp cast_value(v, :number, _opts, _p) when is_number(v) and v >= 0, do: {:ok, v}
  defp cast_value(_v, :number, _opts, p), do: err(p, "must be a non-negative number")

  defp cast_value(v, :json, _opts, _p) when is_map(v), do: {:ok, v}
  defp cast_value(_v, :json, _opts, p), do: err(p, "must be an object")

  defp cast_value(v, :uuid, _opts, p), do: match(v, @uuid, p, "must be a UUID")
  defp cast_value(v, :slug, _opts, p), do: match(v, @slug, p, "must be a lowercase DNS label")
  defp cast_value(v, :code, _opts, p), do: match(v, @code, p, "must be a lowercase code")

  defp cast_value(v, :version, _opts, p),
    do: match(v, @version, p, "must be a version like 1.2.3")

  defp cast_value(v, :sha256, _opts, p),
    do: match(v, @sha256, p, "must be a lowercase hex SHA-256")

  defp cast_value(v, :hex16, _opts, p), do: match(v, @hex16, p, "must be 16 lowercase hex digits")
  defp cast_value(v, :step_ref, _opts, p), do: match(v, @step_ref, p, "must be a step reference")

  defp cast_value(v, :label, _opts, p),
    do: match(v, @label, p, "must be a lowercase runner label")

  defp cast_value(v, :hostname, _opts, p), do: match(v, @hostname, p, "must be a host name")
  defp cast_value(v, :repo, _opts, p), do: match(v, @repo, p, "must look like owner/name")

  defp cast_value(v, :box_name, _opts, p) do
    if CrewProtocol.Names.box_name?(v),
      do: {:ok, v},
      else: err(p, "must be a lowercase DNS label of at most 40 characters")
  end

  defp cast_value(v, :runner_name, _opts, p) do
    case CrewProtocol.Names.parse_runner_name(v) do
      {:ok, _} -> {:ok, v}
      :error -> err(p, "must be a Crew runner name")
    end
  end

  defp cast_value(v, :base64, _opts, p) when is_binary(v) do
    case Base.decode64(v) do
      {:ok, _} -> {:ok, v}
      :error -> err(p, "must be base64")
    end
  end

  defp cast_value(v, :pem, _opts, p) when is_binary(v) do
    if String.valid?(v) and String.starts_with?(v, "-----BEGIN ") and
         not String.contains?(v, <<0>>),
       do: {:ok, v},
       else: err(p, "must be PEM")
  end

  defp cast_value(v, type, _opts, p) when type in [:https_url, :url] and is_binary(v) do
    if String.valid?(v),
      do: cast_url(v, p, if(type == :https_url, do: ["https"], else: ["https", "http"])),
      else: err(p, "must be UTF-8")
  end

  defp cast_value(_v, _type, _opts, p), do: err(p, "must be a string")

  defp cast_list(v, type, p) do
    v
    |> Enum.with_index()
    |> Enum.reduce({[], []}, fn {item, i}, {ok, errs} ->
      case cast_checked(item, type, [], p) do
        {:ok, x} ->
          {[x | ok], errs}

        {:error, e} ->
          {ok, Enum.reduce(e, errs, fn {ep, m}, acc -> [{ep, "item #{i} #{m}"} | acc] end)}
      end
    end)
    |> case do
      {ok, []} -> {:ok, Enum.reverse(ok)}
      {_, errs} -> {:error, Enum.reverse(errs)}
    end
  end

  defp match(v, regex, p, msg) when is_binary(v) do
    if Regex.match?(regex, v), do: {:ok, v}, else: err(p, msg)
  end

  defp match(_v, _regex, p, _msg), do: err(p, "must be a string")

  defp cast_url(v, p, schemes) do
    case URI.new(v) do
      {:ok, %URI{scheme: scheme, host: host, userinfo: nil}}
      when is_binary(host) and host != "" ->
        cond do
          scheme not in schemes -> err(p, "must use #{Enum.join(schemes, " or ")}")
          String.contains?(v, [" ", "\n", "\r", "\t"]) -> err(p, "must not contain whitespace")
          true -> {:ok, v}
        end

      {:ok, %URI{userinfo: info}} when is_binary(info) ->
        err(p, "must not contain credentials")

      _ ->
        err(p, "must be a URL")
    end
  end
end
