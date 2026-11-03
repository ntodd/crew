defmodule Crew.VMs.VMEvent do
  @moduledoc "Something that happened to a VM, kept for its page."
  use Crew.Schema

  schema "vm_events" do
    belongs_to :vm, Crew.VMs.VM
    field :kind, :string
    field :payload, :map
    field :at, :utc_datetime_usec
  end
end
