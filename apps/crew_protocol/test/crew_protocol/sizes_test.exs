defmodule CrewProtocol.SizesTest do
  use ExUnit.Case, async: true

  alias CrewProtocol.Sizes

  @ok %{name: "m", vcpus: 4, memory_mib: 8192, disk_gib: 60}

  test "a valid size" do
    assert Sizes.validate(@ok) == :ok
  end

  describe "names" do
    test "a lowercase DNS label of 1-12 characters" do
      for name <- ~w(m xs big-mem a1 abcdefghijkl) do
        assert Sizes.validate(%{@ok | name: name}) == :ok, name
      end

      for name <- ["", "abcdefghijklm", "Big", "-m", "m-", "m_l", "a b"] do
        assert {:error, [{:name, _}]} = Sizes.validate(%{@ok | name: name}), name
      end
    end

    test "can't be spare or end in -spare, which mean spare capacity in a label" do
      assert Sizes.name_error("spare") == "can't be spare"
      assert Sizes.name_error("big-spare") == "can't end in -spare"
      assert Sizes.name_error("spares") == nil
      assert Sizes.name_error("sparex") == nil
      assert Sizes.name_error("spare-m") == nil
    end

    test "can't be an arch, end in an arch, or contain crew" do
      for name <- ~w(x64 arm64 big-x64 m-arm64 crew mycrew crewm) do
        assert {:error, [{:name, _}]} = Sizes.validate(%{@ok | name: name}), name
      end
    end
  end

  test "vcpus is 1 or an even number up to 32" do
    for v <- [1, 2, 4, 30, 32], do: assert(Sizes.validate(%{@ok | vcpus: v}) == :ok)

    for v <- [0, 3, 5, 33, 34, -2, 2.0] do
      assert {:error, [{:vcpus, _}]} = Sizes.validate(%{@ok | vcpus: v}), inspect(v)
    end
  end

  test "memory_mib is at least 1024 and a multiple of 256" do
    for v <- [1024, 1280, 32_768], do: assert(Sizes.validate(%{@ok | memory_mib: v}) == :ok)

    for v <- [768, 1000, 1025, 0] do
      assert {:error, [{:memory_mib, _}]} = Sizes.validate(%{@ok | memory_mib: v}), inspect(v)
    end
  end

  test "disk_gib is 10 to 2000" do
    for v <- [10, 2000], do: assert(Sizes.validate(%{@ok | disk_gib: v}) == :ok)

    for v <- [9, 2001, 0] do
      assert {:error, [{:disk_gib, _}]} = Sizes.validate(%{@ok | disk_gib: v}), inspect(v)
    end
  end

  test "every problem is reported" do
    assert {:error, errors} = Sizes.validate(%{name: "x64", vcpus: 3, memory_mib: 1, disk_gib: 1})
    assert errors |> Keyword.keys() |> Enum.sort() == [:disk_gib, :memory_mib, :name, :vcpus]
  end

  test "the default sizes from the spec are valid" do
    for size <- Sizes.defaults() do
      assert Sizes.validate(size) == :ok, size.name
    end

    assert Enum.map(Sizes.defaults(), & &1.name) == ~w(xs s m l xl)
    assert [%{name: "m"}] = Enum.filter(Sizes.defaults(), & &1.is_default)
  end
end
