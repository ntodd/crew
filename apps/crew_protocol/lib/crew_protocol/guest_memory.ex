defmodule CrewProtocol.GuestMemory do
  @moduledoc """
  What a job VM boots with, so its guest sees its size's memory (§11.6
  item 2: `MemTotal` within 64 MiB of `memory_mib`).

  The guest kernel keeps part of what it's given: about 44 MiB for its
  image and early allocations, 1/64 for `struct page`, a little more per
  GiB, and swiotlb's bounce buffer, which the command line holds to 8 MiB
  (`swiotlb=4096`). Measured on vz and Firecracker (arm64) at 1 to 8 GiB:
  without this, a 2 GiB VM saw 81 MiB less and an 8 GiB one 261 MiB less.

  So a VM boots with its size plus `reserve_mib/1`, and placement counts
  that reserve with the VMM's overhead (§8.3). crew-vmctl has the same
  formula (`vmctl.BootMiB`) and checks Firecracker's config against it.
  """

  @doc "The MiB a VM of this size boots with on top of its size."
  @spec reserve_mib(pos_integer()) :: pos_integer()
  def reserve_mib(memory_mib) when is_integer(memory_mib) and memory_mib > 0,
    do: 48 + div(memory_mib * 37, 2000)

  @doc "The memory a VM of this size boots with."
  @spec boot_mib(pos_integer()) :: pos_integer()
  def boot_mib(memory_mib), do: memory_mib + reserve_mib(memory_mib)
end
