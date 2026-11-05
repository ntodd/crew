defmodule CrewProtocol.GuestMemoryTest do
  use ExUnit.Case, async: true

  alias CrewProtocol.GuestMemory

  # crew-vmctl (Go) has the same table: vmctl.BootMiB.
  test "a VM boots with its size plus what the guest kernel keeps" do
    assert GuestMemory.boot_mib(1024) == 1090
    assert GuestMemory.boot_mib(2048) == 2133
    assert GuestMemory.boot_mib(4096) == 4219
    assert GuestMemory.boot_mib(8192) == 8391
    assert GuestMemory.boot_mib(32_768) == 33_422
  end

  # The kernel's share, as measured on vz and Firecracker (arm64): about
  # 44 MiB, plus 1/400 (page tables and the like), plus 1/64 for struct
  # page, plus swiotlb's 8 MiB (swiotlb=4096 on the command line).
  defp kept(boot), do: 44 + boot / 400 + boot / 64 + 8

  test "so MemTotal lands within a few MiB of the size, at every size" do
    for gib <- [1, 2, 3, 4, 6, 8, 12, 16, 24, 32, 64] do
      size = gib * 1024
      boot = GuestMemory.boot_mib(size)
      assert abs(boot - kept(boot) - size) <= 16, "#{gib} GiB"
    end
  end
end
