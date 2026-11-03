defmodule CrewGuest.WorkerLog do
  @moduledoc """
  Parses the runner worker's diagnostic log (`_diag/Worker_*.log`) for
  timeline record updates (§16.2). It's the one place that knows the
  format, and it's tolerant: whatever it can't read it skips, and the
  steps fall back to "Step 1…n" in page order (`CrewGuest.Steps`).

  **The format, as modelled on actions/runner** (spike S5 records fixtures
  from the pinned runner version in `test/fixtures/worker/`):
  - each entry starts with a `HostTraceListener` header,
    `[<yyyy-MM-dd HH:mm:ssZ> <type> <source>] <message>`, and continues
    on the following lines until the next header;
  - the worker's `Job message:` entry is a JSON dump of the job request,
    whose `steps` carry each step's record id and, when the workflow set
    one, its display name (`displayNameToken`);
  - any entry may embed JSON: an object (or array of objects) with a GUID
    `id`, `stepId`, `timelineRecordId` or `recordId` and at least one of
    `state`, `result`, `order`, `startTime` or `finishTime` is taken as an
    update of that record. That covers serialized `TimelineRecord`s
    (`id`, `name`, `order`, `state`, `result`, `startTime`, `finishTime`)
    and the per-step telemetry the worker publishes when a step completes
    (`stepId`, `result`, `startTime`, `finishTime`);
  - the steps runner logs `Processing step: DisplayName='<name>'` as a
    step starts, so the next step telemetry is taken to be that step's,
    and carries the name as a `display_name` hint. A name from a record
    or from the plan wins over it.

  **Updates:**
  - `{:planned, record_id, name}`, a step's display name from the plan;
  - `{:record, %{id: ...}}` with whichever of `name`, `order`, `state`
    (`pending`, `in_progress`, `completed`), `conclusion` (`success`,
    `failure`, `cancelled`, `skipped`), `started_at`, `completed_at` (Unix
    ms) and `display_name` the entry had;
  - `{:job, record_id}` for a record that's the job (or a stage), not a
    step.
  """

  defstruct buf: "", entry: nil, entry_bytes: 0, processing: nil

  @type update ::
          {:planned, String.t(), String.t()} | {:record, map()} | {:job, String.t()}

  @header ~r/\A\[\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}Z \S+\s+[^\]]*\] ?(.*)\z/s
  @guid ~r/\A[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\z/
  @id_keys ~w(id stepId timelineRecordId recordId)
  @record_keys ~w(state result order startTime finishTime)
  # An entry bigger than this (a huge dump) is skipped rather than held.
  @max_entry 8 * 1_048_576
  @max_depth 8

  def new, do: %__MODULE__{}

  @doc "Parses a whole log."
  @spec parse(binary()) :: [update()]
  def parse(log) do
    {updates, parser} = feed(new(), log)
    {last, _parser} = flush(parser)
    updates ++ last
  end

  @doc "Feeds a chunk. An entry's updates come once the next entry starts."
  @spec feed(%__MODULE__{}, binary()) :: {[update()], %__MODULE__{}}
  def feed(%__MODULE__{} = p, chunk) do
    [partial | complete] = (p.buf <> chunk) |> :binary.split("\n", [:global]) |> Enum.reverse()

    {updates, p} =
      complete
      |> Enum.reverse()
      |> Enum.reduce({[], %{p | buf: ""}}, fn line, {acc, p} ->
        {updates, p} = line(p, line)
        {[updates | acc], p}
      end)

    {updates |> Enum.reverse() |> List.flatten(), %{p | buf: partial}}
  end

  @doc "Parses whatever is held: the last entry and any unterminated line."
  @spec flush(%__MODULE__{}) :: {[update()], %__MODULE__{}}
  def flush(%__MODULE__{} = p) do
    {updates, p} = if p.buf == "", do: {[], p}, else: line(%{p | buf: ""}, p.buf)
    {last, _p} = finish_entry(p)
    {updates ++ last, %__MODULE__{}}
  end

  defp line(p, raw) do
    raw = String.trim_trailing(raw, "\r")

    case Regex.run(@header, raw, capture: :all_but_first) do
      [message] ->
        {updates, p} = finish_entry(p)
        {updates, %{p | entry: [message], entry_bytes: byte_size(message)}}

      nil ->
        {[], append(p, raw)}
    end
  end

  # Lines before the first header belong to no entry.
  defp append(%{entry: nil} = p, _raw), do: p
  defp append(%{entry: :skipped} = p, _raw), do: p

  defp append(p, raw) do
    bytes = p.entry_bytes + byte_size(raw) + 1

    if bytes > @max_entry,
      do: %{p | entry: :skipped, entry_bytes: 0},
      else: %{p | entry: [raw | p.entry], entry_bytes: bytes}
  end

  defp finish_entry(%{entry: lines} = p) when is_list(lines) do
    lines |> Enum.reverse() |> Enum.join("\n") |> entry(%{p | entry: nil})
  rescue
    # Tolerant by design: an entry that trips the parser is skipped.
    _ -> {[], %{p | entry: nil}}
  end

  defp finish_entry(p), do: {[], %{p | entry: nil}}

  defp entry("Job message:" <> rest, p), do: {rest |> decode() |> planned(), p}

  defp entry("Processing step: DisplayName='" <> rest, p) do
    name = rest |> String.trim_trailing() |> String.trim_trailing("'")
    {[], %{p | processing: text(name)}}
  end

  defp entry(message, p) do
    if String.contains?(message, ["{", "["]) and String.contains?(message, ~s(")) do
      message |> decode() |> records(0, []) |> Enum.reverse() |> hint(p)
    else
      {[], p}
    end
  end

  # The first step telemetry after "Processing step" is that step's.
  defp hint(updates, p) do
    {updates, processing} =
      Enum.map_reduce(updates, p.processing, fn
        {:record, %{telemetry: :step} = r}, name when name != nil ->
          {{:record, r |> Map.delete(:telemetry) |> Map.put(:display_name, name)}, nil}

        {:record, r}, name ->
          {{:record, Map.delete(r, :telemetry)}, name}

        other, name ->
          {other, name}
      end)

    {updates, %{p | processing: processing}}
  end

  # The JSON in a message starts at its first `{` or `[`. The telemetry
  # line ends its object with a full stop.
  defp decode(message) do
    case :binary.match(message, ["{", "["]) do
      {start, _} ->
        json =
          message
          |> binary_part(start, byte_size(message) - start)
          |> String.trim_trailing()
          |> String.trim_trailing(".")

        case Jason.decode(json) do
          {:ok, value} -> value
          {:error, _} -> nil
        end

      :nomatch ->
        nil
    end
  end

  defp planned(%{"steps" => steps}) when is_list(steps) do
    for %{} = step <- steps,
        id = guid(step["id"]),
        name = display_name(step),
        do: {:planned, id, name}
  end

  defp planned(_job), do: []

  defp display_name(step) do
    case step["displayName"] || step["displayNameToken"] do
      name when is_binary(name) and name != "" -> name
      %{"lit" => name} when is_binary(name) and name != "" -> name
      _ -> nil
    end
  end

  defp records(_value, depth, acc) when depth > @max_depth, do: acc

  defp records(list, depth, acc) when is_list(list),
    do: Enum.reduce(list, acc, &records(&1, depth + 1, &2))

  defp records(%{} = map, depth, acc) do
    case record(map) do
      nil -> map |> Map.values() |> Enum.reduce(acc, &records(&1, depth + 1, &2))
      update -> [update | acc]
    end
  end

  defp records(_value, _depth, acc), do: acc

  defp record(map) do
    with id when is_binary(id) <- @id_keys |> Enum.find_value(&map[&1]) |> guid(),
         true <- Enum.any?(@record_keys, &Map.has_key?(map, &1)) do
      cond do
        job?(map["type"]) -> {:job, id}
        telemetry?(map) -> {:record, map |> record(id) |> Map.put(:telemetry, :step)}
        true -> {:record, record(map, id)}
      end
    else
      _ -> nil
    end
  end

  # Telemetry for a step of the job itself, not one inside a composite
  # action.
  defp telemetry?(map), do: Map.has_key?(map, "stepId") and map["isEmbedded"] != true

  defp record(map, id) do
    update =
      [
        name: text(map["name"]),
        order: order(map["order"]),
        state: state(map["state"]),
        conclusion: conclusion(map["result"]),
        started_at: time(map["startTime"]),
        completed_at: time(map["finishTime"])
      ]
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Map.new()
      |> Map.put(:id, id)

    # Telemetry only exists for a finished step.
    if Map.has_key?(update, :conclusion),
      do: Map.put_new(update, :state, "completed"),
      else: update
  end

  defp job?(type) when is_binary(type), do: String.downcase(type) in ~w(job stage phase)
  defp job?(_type), do: false

  defp guid(id) when is_binary(id) do
    if Regex.match?(@guid, id) and id != "00000000-0000-0000-0000-000000000000",
      do: String.downcase(id)
  end

  defp guid(_id), do: nil

  defp text(name) when is_binary(name) and name != "", do: name
  defp text(_name), do: nil

  defp order(n) when is_integer(n) and n >= 0, do: n
  defp order(_n), do: nil

  defp state(state) when is_binary(state) do
    case state |> String.downcase() |> String.replace("_", "") do
      "pending" -> "pending"
      "inprogress" -> "in_progress"
      "completed" -> "completed"
      _ -> nil
    end
  end

  defp state(0), do: "pending"
  defp state(1), do: "in_progress"
  defp state(2), do: "completed"
  defp state(_state), do: nil

  defp conclusion(result) when is_binary(result) do
    case String.downcase(result) do
      r when r in ~w(succeeded succeededwithissues) -> "success"
      "failed" -> "failure"
      r when r in ~w(canceled cancelled abandoned) -> "cancelled"
      "skipped" -> "skipped"
      _ -> nil
    end
  end

  defp conclusion(n) when n in [0, 1], do: "success"
  defp conclusion(2), do: "failure"
  defp conclusion(n) when n in [3, 5], do: "cancelled"
  defp conclusion(4), do: "skipped"
  defp conclusion(_result), do: nil

  defp time(iso) when is_binary(iso) do
    with {:error, _} <- DateTime.from_iso8601(iso),
         {:ok, naive} <- NaiveDateTime.from_iso8601(iso) do
      naive |> DateTime.from_naive!("Etc/UTC") |> unix_ms()
    else
      {:ok, dt, _offset} -> unix_ms(dt)
      {:error, _} -> nil
    end
  end

  defp time(_iso), do: nil

  # .NET's DateTime.MinValue ("0001-01-01T00:00:00") means unset.
  defp unix_ms(%DateTime{year: year}) when year < 2000, do: nil
  defp unix_ms(dt), do: DateTime.to_unix(dt, :millisecond)
end
