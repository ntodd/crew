defmodule CrewGuest.StepRef do
  @moduledoc """
  Maps a timeline record id to a `step_ref`, which the guest API requires
  to match `^[a-zA-Z0-9_-]{1,64}$` (§13.4). Record ids are GUIDs, which
  already do, so they're used as they are. Anything else gets a stable
  hash, so log lines and steps for one record always agree.
  """

  @valid ~r/\A[a-zA-Z0-9_-]{1,64}\z/

  @spec from(String.t()) :: String.t()
  def from(id) when is_binary(id) do
    if Regex.match?(@valid, id) do
      id
    else
      "r-" <> binary_part(Base.encode16(:crypto.hash(:sha256, id), case: :lower), 0, 32)
    end
  end
end
