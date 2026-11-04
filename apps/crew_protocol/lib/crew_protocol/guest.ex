defmodule CrewProtocol.Guest do
  @moduledoc """
  Bodies of the guest API (§13.4).

  Nothing from the guest is trusted: the job has root and can replace
  crew-guest. Unlike agent events, guest bodies are cleaned rather than
  refused where that's harmless: unknown fields are dropped, strings are
  capped on a UTF-8 boundary, and timestamps are clamped to the VM's
  lifetime. What can't be cleaned (a state that isn't the guest's to
  report, a bad step ref) is refused.

  `life` is `{started_ms, now_ms}`, the VM's lifetime so far in Unix
  milliseconds.
  """

  alias CrewProtocol.Text

  @states ~w(runner_listening job_started job_finished job_refused)
  @step_statuses ~w(pending queued in_progress completed)
  @step_conclusions ~w(success failure cancelled skipped neutral)
  @step_ref ~r/\A[a-zA-Z0-9_-]{1,64}\z/

  @max_detail 1024
  @max_step_name 512
  @max_steps 1000
  @max_line 65_536

  @type life :: {integer(), integer()}

  def states, do: @states
  def max_steps, do: @max_steps

  @spec cast_state(term(), life()) :: {:ok, map()} | {:error, atom()}
  def cast_state(%{} = body, life) do
    case body["state"] do
      state when state in @states ->
        {:ok,
         %{state: state, at: clamp(body["at"], life), detail: text(body["detail"], @max_detail)}}

      _ ->
        {:error, :bad_state}
    end
  end

  def cast_state(_body, _life), do: {:error, :bad_body}

  @spec cast_steps(term(), life()) :: {:ok, [map()]} | {:error, atom()}
  def cast_steps(%{"steps" => steps}, _life) when is_list(steps) and length(steps) > @max_steps,
    do: {:error, :too_many_steps}

  def cast_steps(%{"steps" => steps}, life) when is_list(steps),
    do: {:ok, Enum.flat_map(steps, &step(&1, life))}

  def cast_steps(_body, _life), do: {:error, :bad_body}

  defp step(%{} = s, life) do
    with ref when is_binary(ref) <- s["ref"],
         true <- Regex.match?(@step_ref, ref) do
      [
        %{
          ref: ref,
          name: blank_to(text(s["name"], @max_step_name), ref),
          number: non_neg_int(s["number"], 10_000),
          status: if(s["status"] in @step_statuses, do: s["status"], else: "pending"),
          started_at: maybe_clamp(s["started_at"], life),
          completed_at: maybe_clamp(s["completed_at"], life),
          conclusion: if(s["conclusion"] in @step_conclusions, do: s["conclusion"])
        }
      ]
    else
      _ -> []
    end
  end

  defp step(_s, _life), do: []

  @spec cast_log_line(term(), life()) :: {:ok, map()} | {:error, atom()}
  def cast_log_line(%{} = line, life) do
    ref = line["step_ref"]

    cond do
      not is_binary(line["text"]) ->
        {:error, :bad_text}

      not (is_nil(ref) or (is_binary(ref) and Regex.match?(@step_ref, ref))) ->
        {:error, :bad_step_ref}

      true ->
        {text, truncated} = line["text"] |> Text.scrub() |> Text.cut(@max_line)
        {:ok, %{t: clamp(line["t"], life), step_ref: ref, text: text, truncated: truncated}}
    end
  end

  def cast_log_line(_line, _life), do: {:error, :bad_body}

  @doc """
  Reads an NDJSON body of log lines. Lines that don't parse or validate
  are skipped and counted: `{:ok, lines, skipped}`.
  """
  def parse_ndjson(body, life) when is_binary(body) do
    {lines, skipped} =
      body
      |> String.split("\n", trim: true)
      |> Enum.reduce({[], 0}, fn raw, {acc, skipped} ->
        with {:ok, map} <- Jason.decode(raw),
             {:ok, line} <- cast_log_line(map, life) do
          {[line | acc], skipped}
        else
          _ -> {acc, skipped + 1}
        end
      end)

    {:ok, Enum.reverse(lines), skipped}
  end

  @spec cast_metrics(term(), life()) :: {:ok, map()} | {:error, atom()}
  def cast_metrics(%{} = m, life) do
    {:ok,
     %{
       t: clamp(m["t"], life),
       cpu_pct: pct(m["cpu_pct"]),
       mem_used_mib: non_neg_int(m["mem_used_mib"], 16_777_216),
       mem_total_mib: non_neg_int(m["mem_total_mib"], 16_777_216),
       disk_used_mib: non_neg_int(m["disk_used_mib"], 1_073_741_824),
       net_rx_bytes: non_neg_int(m["net_rx_bytes"], 1_000_000_000_000_000),
       net_tx_bytes: non_neg_int(m["net_tx_bytes"], 1_000_000_000_000_000)
     }}
  end

  def cast_metrics(_m, _life), do: {:error, :bad_body}

  @doc """
  The body of `GET /v1/payload`. `mirrors` are the registries the box's
  cache serves (§15.1, Design A): crew-guest points dockerd at the cache
  for each, and only for hosts Crew knows.
  """
  def payload(%{jit_config: jit, ca_pem: ca, policy: policy, size: size, labels: labels} = p) do
    %{
      "jit_config" => jit,
      "ca_pem" => ca,
      "mirrors" => Enum.filter(Map.get(p, :mirrors) || [], &(&1 in CrewProtocol.Hosts.names())),
      "policy" => %{
        "fork_prs" => to_string(policy.fork_prs),
        "repo_full_name" => policy.repo_full_name
      },
      "size" => Map.new(size, fn {k, v} -> {to_string(k), v} end),
      "labels" => labels
    }
    |> put_conformance(Map.get(p, :conformance))
  end

  defp put_conformance(payload, nil), do: payload

  defp put_conformance(payload, conformance) do
    case cast_conformance(conformance) do
      {:ok, c} -> Map.put(payload, "conformance", c)
      {:error, reasons} -> raise ArgumentError, "bad conformance object: #{inspect(reasons)}"
    end
  end

  # -- conformance mode (§11.6) ----------------------------------------------------

  @conformance_checks ~w(sizing disk dns https payload foreign_token docker buildx kind
                         tls_clients isolation ipv6 spoof conntrack listen ticks
                         console_flood api_flood)
  @label ~r/\A[a-z0-9][a-z0-9_.:-]{0,63}\z/
  @token ~r/\A[A-Za-z0-9_-]{16,128}\z/

  @doc "The checks a conformance object may name: the guest image's script runs only these."
  def conformance_checks, do: @conformance_checks

  @doc """
  Checks a `conformance` object (conformance mode, §11.6). It goes from
  the agent to the guest, never from the control plane, and only when the
  agent's own config has `CREW_CONFORMANCE=1`. The guest image's fixed
  script (`/opt/crew/conformance/check`) reads it: which of its own checks
  to run, and the few values they need. Nothing in it is a command, a
  path or free text: checks come from a fixed list, addresses must be
  IPv4, numbers are bounded, labels and tokens are plain.

  Unlike the guest's bodies, nothing is cleaned: an unknown field or a bad
  value refuses the whole object (`{:error, reasons}`), on both sides.
  """
  @spec cast_conformance(term()) :: {:ok, map()} | {:error, [String.t()]}
  def cast_conformance(%{} = c) do
    fields = %{
      "checks" => {&checks/1, :required},
      "targets" => {&endpoints(&1, 64), :optional},
      "reach" => {&endpoints(&1, 16), :optional},
      "peers" => {&list_of(&1, 32, fn ip -> ipv4(ip) end), :optional},
      "foreign_tokens" => {&list_of(&1, 4, fn t -> match(t, @token) end), :optional},
      "listen_port" => {&int(&1, 1024, 65_535), :optional},
      "hold_s" => {&int(&1, 0, 3_600), :optional},
      "ticks" => {&int(&1, 0, 100_000), :optional},
      "console_mib" => {&int(&1, 0, 100), :optional},
      "conntrack" => {&conntrack/1, :optional}
    }

    unknown =
      for k <- Map.keys(c), not Map.has_key?(fields, k), do: "#{inspect(k)} is not allowed"

    errors =
      Enum.flat_map(fields, fn {key, {check, need}} ->
        case {Map.fetch(c, key), need} do
          {:error, :required} -> ["#{key} is required"]
          {:error, :optional} -> []
          {{:ok, value}, _} -> if check.(value), do: [], else: ["#{key} is invalid"]
        end
      end)

    case unknown ++ errors do
      [] -> {:ok, c}
      reasons -> {:error, reasons}
    end
  end

  def cast_conformance(_c), do: {:error, ["conformance must be an object"]}

  defp checks(list), do: list_of(list, 32, &(&1 in @conformance_checks))

  defp endpoints(list, max), do: list_of(list, max, &endpoint/1)

  defp endpoint(%{"label" => label, "ip" => ip, "port" => port} = e) when map_size(e) == 3,
    do: match(label, @label) and ipv4(ip) and int(port, 1, 65_535)

  defp endpoint(_e), do: false

  defp conntrack(%{"ip" => ip, "port" => port, "count" => count} = c) when map_size(c) == 3,
    do: ipv4(ip) and int(port, 1, 65_535) and int(count, 1, 4_096)

  defp conntrack(_c), do: false

  defp list_of(list, max, check) when is_list(list) and length(list) <= max,
    do: Enum.all?(list, check)

  defp list_of(_list, _max, _check), do: false

  defp int(v, min, max), do: is_integer(v) and v >= min and v <= max

  defp match(v, re), do: is_binary(v) and Regex.match?(re, v)

  # Dotted quad, no leading zeros, nothing else (`:inet`'s strict parser
  # takes `010.0.0.1` as 10.0.0.1, which a shell tool might read as octal).
  defp ipv4(v) when is_binary(v) do
    Regex.match?(~r/\A(0|[1-9][0-9]{0,2})(\.(0|[1-9][0-9]{0,2})){3}\z/, v) and
      match?({:ok, _}, :inet.parse_ipv4strict_address(String.to_charlist(v)))
  end

  defp ipv4(_v), do: false

  defp clamp(t, {from, to}) when is_integer(t), do: t |> max(from) |> min(to)
  defp clamp(_t, {_from, to}), do: to

  defp maybe_clamp(nil, _life), do: nil
  defp maybe_clamp(t, life) when is_integer(t), do: clamp(t, life)
  defp maybe_clamp(_t, _life), do: nil

  defp text(v, max) when is_binary(v) do
    {t, _} = v |> Text.scrub() |> Text.cut(max)
    t
  end

  defp text(_v, _max), do: nil

  defp blank_to(nil, fallback), do: fallback
  defp blank_to("", fallback), do: fallback
  defp blank_to(v, _fallback), do: v

  defp non_neg_int(v, max) when is_integer(v), do: v |> max(0) |> min(max)
  defp non_neg_int(v, max) when is_float(v), do: non_neg_int(trunc(v), max)
  defp non_neg_int(_v, _max), do: 0

  defp pct(v) when is_number(v), do: v |> max(0) |> min(100) |> Kernel.*(1.0)
  defp pct(_v), do: 0.0
end
