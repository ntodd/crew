defmodule Crew.GitHub.BudgetTest do
  use ExUnit.Case, async: true

  alias Crew.GitHub.Budget

  setup do
    clock = :counters.new(1, [])
    :counters.put(clock, 1, 1_000_000)
    now = fn -> :counters.get(clock, 1) end
    name = :"budget_#{System.unique_integer([:positive])}"
    start_supervised!({Budget, name: name, now: now})
    %{b: name, clock: clock}
  end

  defp advance(clock, ms), do: :counters.add(clock, 1, ms)

  defp headers(remaining, limit, reset_s) do
    %{
      "x-ratelimit-remaining" => [to_string(remaining)],
      "x-ratelimit-limit" => [to_string(limit)],
      "x-ratelimit-reset" => [to_string(reset_s)]
    }
  end

  test "a read is allowed and released", %{b: b} do
    assert {:ok, ref} = Budget.acquire(b, 1, :normal, :read)
    assert :ok = Budget.release(b, 1, ref, 200, headers(4999, 5000, 2000))
    assert %{remaining: 4999, limit: 5000} = Budget.info(b, 1)
  end

  describe "below 20% of the hourly budget" do
    setup %{b: b} do
      {:ok, ref} = Budget.acquire(b, 1, :normal, :read)
      # Reset an hour from the test clock's start (1_000_000 ms).
      :ok = Budget.release(b, 1, ref, 200, headers(900, 5000, 1000 + 3600))
      :ok
    end

    test "essential calls are always made", %{b: b} do
      assert {:ok, _} = Budget.acquire(b, 1, :essential, :read)
    end

    test "normal calls wait for the reset", %{b: b} do
      assert {:error, {:delayed, until_ms}} = Budget.acquire(b, 1, :normal, :read)
      assert until_ms == (1000 + 3600) * 1000
    end

    test "optional calls are skipped", %{b: b} do
      assert {:error, :skipped} = Budget.acquire(b, 1, :optional, :read)
    end

    test "after the reset, everything goes again", %{b: b, clock: clock} do
      advance(clock, 3601 * 1000)
      assert {:ok, _} = Budget.acquire(b, 1, :optional, :read)
    end

    test "other installations aren't affected", %{b: b} do
      assert {:ok, _} = Budget.acquire(b, 2, :optional, :read)
    end
  end

  test "at most 20 requests in flight per installation", %{b: b} do
    refs = for _ <- 1..20, do: elem(Budget.acquire(b, 1, :normal, :read), 1)
    assert {:error, :busy} = Budget.acquire(b, 1, :normal, :read, wait: 0)
    assert {:ok, _} = Budget.acquire(b, 2, :normal, :read)

    :ok = Budget.release(b, 1, hd(refs), 200, %{})
    assert {:ok, _} = Budget.acquire(b, 1, :normal, :read)
  end

  test "a caller waiting for a slot gets one when another finishes", %{b: b} do
    refs = for _ <- 1..20, do: elem(Budget.acquire(b, 1, :normal, :read), 1)
    task = Task.async(fn -> Budget.acquire(b, 1, :normal, :read, wait: 2000) end)
    Process.sleep(50)
    :ok = Budget.release(b, 1, hd(refs), 200, %{})
    assert {:ok, _} = Task.await(task)
  end

  test "a waiter granted a slot is held to a backoff that arrived while it waited", %{b: b} do
    refs = for _ <- 1..20, do: elem(Budget.acquire(b, 1, :normal, :read), 1)
    task = Task.async(fn -> Budget.acquire(b, 1, :normal, :read, wait: 2000) end)
    Process.sleep(50)
    :ok = Budget.release(b, 1, hd(refs), 429, %{"retry-after" => ["60"]})
    assert {:error, {:backoff, _}} = Task.await(task)
  end

  test "a normal waiter is held to a budget that ran low while it waited", %{b: b} do
    refs = for _ <- 1..20, do: elem(Budget.acquire(b, 1, :normal, :read), 1)
    task = Task.async(fn -> Budget.acquire(b, 1, :normal, :read, wait: 2000) end)
    Process.sleep(50)
    :ok = Budget.release(b, 1, hd(refs), 200, headers(100, 5000, 1000 + 3600))
    assert {:error, {:delayed, _}} = Task.await(task)
  end

  test "a crashed caller's slot is given back", %{b: b} do
    for _ <- 1..19, do: Budget.acquire(b, 1, :normal, :read)
    pid = spawn(fn -> Budget.acquire(b, 1, :normal, :read) end)
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, _, _, _}
    assert {:ok, _} = Budget.acquire(b, 1, :normal, :read, wait: 500)
  end

  describe "writes" do
    test "are paced at 60 a minute", %{b: b, clock: clock} do
      for _ <- 1..60 do
        {:ok, ref} = Budget.acquire(b, 1, :essential, :jit)
        :ok = Budget.release(b, 1, ref, 201, %{})
      end

      assert {:error, {:write_limited, retry}} = Budget.acquire(b, 1, :essential, :jit)
      # The window is a sliding minute: the oldest write leaves it first.
      assert retry == 1_000_000 + 60_000
      advance(clock, 60_001)
      assert {:ok, _} = Budget.acquire(b, 1, :essential, :jit)
    end

    test "and 450 an hour", %{b: b, clock: clock} do
      for _ <- 1..450 do
        advance(clock, 1000)
        {:ok, ref} = Budget.acquire(b, 1, :essential, :jit)
        :ok = Budget.release(b, 1, ref, 201, %{})
      end

      advance(clock, 60_000)
      assert {:error, {:write_limited, _}} = Budget.acquire(b, 1, :essential, :jit)
    end

    test "JIT generation is served first: reaping deletes leave it some room", %{b: b} do
      for _ <- 1..50 do
        {:ok, ref} = Budget.acquire(b, 1, :essential, :delete)
        :ok = Budget.release(b, 1, ref, 204, %{})
      end

      assert {:error, {:write_limited, _}} = Budget.acquire(b, 1, :essential, :delete)
      assert {:ok, _} = Budget.acquire(b, 1, :essential, :jit)
    end

    test "reads don't use the write bucket", %{b: b} do
      for _ <- 1..60 do
        {:ok, ref} = Budget.acquire(b, 1, :essential, :jit)
        :ok = Budget.release(b, 1, ref, 201, %{})
      end

      assert {:ok, _} = Budget.acquire(b, 1, :normal, :read)
    end
  end

  describe "403 and 429" do
    test "back off for retry-after", %{b: b, clock: clock} do
      {:ok, ref} = Budget.acquire(b, 1, :normal, :read)
      :ok = Budget.release(b, 1, ref, 429, %{"retry-after" => ["30"]})

      assert {:error, {:backoff, until}} = Budget.acquire(b, 1, :essential, :read)
      assert until == 1_000_000 + 30_000
      advance(clock, 30_001)
      assert {:ok, _} = Budget.acquire(b, 1, :essential, :read)
    end

    test "a 403 with nothing left backs off until the reset", %{b: b} do
      {:ok, ref} = Budget.acquire(b, 1, :normal, :read)
      :ok = Budget.release(b, 1, ref, 403, headers(0, 5000, 1500))
      assert {:error, {:backoff, 1_500_000}} = Budget.acquire(b, 1, :essential, :read)
    end

    test "a 403 that isn't a rate limit doesn't back off", %{b: b} do
      {:ok, ref} = Budget.acquire(b, 1, :normal, :read)
      :ok = Budget.release(b, 1, ref, 403, headers(4000, 5000, 1500))
      assert {:ok, _} = Budget.acquire(b, 1, :normal, :read)
    end
  end
end
