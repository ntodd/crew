defmodule CrewGuest.PagesTest do
  use ExUnit.Case, async: true

  alias CrewGuest.Pages

  @moduletag :tmp_dir

  @timeline "4a3b2c1d-0000-4000-8000-000000000001"
  @rec1 "7f1c2a0e-5b8d-4c3e-9a1f-2d4e6b8c0a13"
  @rec2 "8e2d3b1f-6c9e-4d4f-8b2a-3e5f7c9d1b24"

  describe "parse_name/1" do
    test "reads {timelineId}_{timelineRecordId}_{n}.log" do
      assert {:ok, %{record: @rec1, n: 3}} = Pages.parse_name("#{@timeline}_#{@rec1}_3.log")
      assert :error = Pages.parse_name("#{@timeline}_#{@rec1}.log")
      assert :error = Pages.parse_name("#{@timeline}_#{@rec1}_x.log")
      assert :error = Pages.parse_name("notes.txt")
    end
  end

  describe "parse_line/2" do
    test "takes t from the line's UTC ISO-8601 prefix, with .NET's seven digits" do
      assert {t, "##[group]Run actions/checkout@v4"} =
               Pages.parse_line(
                 "2026-11-03T10:15:01.1234567Z ##[group]Run actions/checkout@v4",
                 0
               )

      assert t == DateTime.to_unix(~U[2026-11-03 10:15:01.123Z], :millisecond)
    end

    test "a line without a prefix (a message with a newline in it) keeps the last t" do
      assert {99, "  continued"} = Pages.parse_line("  continued", 99)
      assert {99, "2026-13-99T00:00:00Z nope"} = Pages.parse_line("2026-13-99T00:00:00Z nope", 99)
    end

    test "a prefix with nothing after it is an empty line" do
      assert {_t, ""} = Pages.parse_line("2026-11-03T10:15:01.0000000Z", 0)
      assert {_t, ""} = Pages.parse_line("2026-11-03T10:15:01.0000000Z ", 0)
    end
  end

  describe "following pages" do
    setup %{tmp_dir: dir} do
      test = self()

      pages =
        start_supervised!(
          {Pages,
           dir: dir,
           tick_ms: 20,
           on_lines: fn lines -> send(test, {:lines, lines}) end,
           on_activity: fn record, first_t, last_t ->
             send(test, {:activity, record, first_t, last_t})
           end}
        )

      %{pages: pages}
    end

    test "emits each line with t, step_ref and text, in order", %{tmp_dir: dir} do
      page = page_path(dir, @rec1, 1)

      File.write!(page, [
        <<0xEF, 0xBB, 0xBF>>,
        line("2026-11-03T10:15:01.0000000Z", "##[group]Run make test"),
        line("2026-11-03T10:15:02.0000000Z", "ok 1\r")
      ])

      assert [l1, l2] = collect(2)
      assert l1.text == "##[group]Run make test"
      assert l1.step_ref == @rec1
      assert l1.t == DateTime.to_unix(~U[2026-11-03 10:15:01Z], :millisecond)
      assert l2.text == "ok 1"

      assert_receive {:activity, @rec1, t1, t2}
      assert t1 == l1.t and t2 == l2.t
    end

    test "keeps reading a page as it grows, joining partial lines", %{tmp_dir: dir} do
      page = page_path(dir, @rec1, 1)
      File.write!(page, line("2026-11-03T10:15:01.0000000Z", "first"))
      assert [%{text: "first"}] = collect(1)

      File.write!(page, "2026-11-03T10:15:02.0000000Z sec", [:append])
      refute_receive {:lines, _}, 150
      File.write!(page, "ond\n", [:append])
      assert [%{text: "second"}] = collect(1)
    end

    test "a deleted page is still read to the end through its open descriptor",
         %{tmp_dir: dir} do
      page = page_path(dir, @rec1, 1)
      File.write!(page, line("2026-11-03T10:15:01.0000000Z", "before"))
      assert [%{text: "before"}] = collect(1)

      # The runner finishes the page and its uploader deletes it at once.
      File.write!(page, Enum.map(1..50, &line("2026-11-03T10:15:02.0000000Z", "after #{&1}")), [
        :append
      ])

      File.rm!(page)

      texts = 50 |> collect() |> Enum.map(& &1.text)
      assert texts == Enum.map(1..50, &"after #{&1}")
    end

    test "follows a record's pages in order of n, finishing each before the next",
         %{tmp_dir: dir} do
      # Page 2 shows up before page 1 has been read (a roll-over at 8 MB).
      File.write!(page_path(dir, @rec1, 1), Enum.map(1..3, &line(ts(&1), "p1 #{&1}")))
      File.write!(page_path(dir, @rec1, 2), Enum.map(4..5, &line(ts(&1), "p2 #{&1}")))

      texts = 5 |> collect() |> Enum.map(& &1.text)
      assert texts == ["p1 1", "p1 2", "p1 3", "p2 4", "p2 5"]
    end

    test "maps each record to its own step ref", %{tmp_dir: dir} do
      File.write!(page_path(dir, @rec1, 1), line(ts(1), "one"))
      assert [%{step_ref: @rec1}] = collect(1)
      File.write!(page_path(dir, @rec2, 1), line(ts(2), "two"))
      assert [%{step_ref: @rec2}] = collect(1)
    end

    test "an overlong line is cut at 64 KiB and the rest of it dropped", %{tmp_dir: dir} do
      page = page_path(dir, @rec1, 1)
      File.write!(page, ["2026-11-03T10:15:01.0000000Z ", String.duplicate("x", 200_000)])
      File.write!(page, ["\n", line(ts(2), "next")], [:append])

      assert [long, next] = collect(2)
      assert byte_size(long.text) <= 65_536
      assert next.text == "next"
    end

    test "keeps going, by scanning, when its watcher dies", %{tmp_dir: dir, pages: pages} do
      File.write!(page_path(dir, @rec1, 1), line(ts(1), "one"))
      assert [_] = collect(1)

      %{watcher: watcher} = :sys.get_state(pages)
      Process.exit(watcher, :kill)
      File.write!(page_path(dir, @rec2, 1), line(ts(2), "two"))

      assert [%{text: "two"}] = collect(1)
      assert Process.alive?(pages)
    end

    test "ignores files that aren't pages", %{tmp_dir: dir} do
      File.write!(Path.join(dir, "README"), "hello\n")
      refute_receive {:lines, _}, 150
    end

    test "finish/1 reads what's left, including a last line with no newline",
         %{tmp_dir: dir, pages: pages} do
      page = page_path(dir, @rec1, 1)
      File.write!(page, line(ts(1), "one"))
      assert [_] = collect(1)

      File.write!(page, "2026-11-03T10:15:09.0000000Z tail without newline", [:append])
      :ok = Pages.finish(pages)
      assert [%{text: "tail without newline"}] = collect(1)
    end
  end

  test "pages already there when it starts are read", %{tmp_dir: dir} do
    File.write!(page_path(dir, @rec1, 1), line(ts(1), "early"))
    test = self()

    start_supervised!(
      {Pages, dir: dir, tick_ms: 20, on_lines: fn lines -> send(test, {:lines, lines}) end}
    )

    assert [%{text: "early"}] = collect(1)
  end

  defp page_path(dir, record, n), do: Path.join(dir, "#{@timeline}_#{record}_#{n}.log")
  defp line(ts, text), do: "#{ts} #{text}\n"
  defp ts(s), do: "2026-11-03T10:15:#{String.pad_leading("#{s}", 2, "0")}.0000000Z"

  # Collects exactly n emitted lines.
  defp collect(n, acc \\ [])
  defp collect(n, acc) when length(acc) >= n, do: acc

  defp collect(n, acc) do
    receive do
      {:lines, lines} -> collect(n, acc ++ lines)
    after
      3_000 -> flunk("expected #{n} lines, got #{inspect(acc)}")
    end
  end
end
