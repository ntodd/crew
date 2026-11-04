defmodule CrewAgent.Conformance do
  @moduledoc """
  Conformance mode (§11.6): instead of starting the runner, crew-guest
  runs the guest image's fixed script (`/opt/crew/conformance/check`)
  and reports each check as a log line, then powers off. The driver
  conformance suite (`test/conformance/`) uses it to look inside real
  guests, where a real job would need GitHub.

  **Only this box can turn it on.** A VM's payload carries a
  `conformance` object only when the agent's own config has
  `CREW_CONFORMANCE=1` (`${CREW_DATA_DIR}/agent/env`, root's on a box).
  `vm.start` has no field for it, and `CrewProtocol.Command` refuses
  unknown fields, so the control plane can't ask for it.

  **Nothing in it runs.** The object names checks from the script's
  fixed list and gives the few values they need (addresses to probe,
  counts), all checked by `CrewProtocol.Guest.cast_conformance/1` here
  and again in the guest.

  What each VM runs: the object registered for its id with `put/2`
  before its `vm.start` (in-process only: the suite does this), else
  `default/0`.
  """

  alias CrewAgent.Config
  alias CrewProtocol.Guest

  @default_checks ~w(sizing disk dns https payload docker tls_clients isolation ipv6 spoof)

  @doc "The checks a VM runs when nothing was registered for it."
  def default, do: %{"checks" => @default_checks}

  @doc "Registers the conformance object for a VM about to start. Refused unless it validates."
  @spec put(String.t(), map()) :: :ok | {:error, [String.t()]}
  def put(vm_id, params) do
    with {:ok, params} <- Guest.cast_conformance(params) do
      :persistent_term.put(key(vm_id), params)
    end
  end

  @doc "What's registered for a VM that hasn't started yet."
  def registered(vm_id), do: :persistent_term.get(key(vm_id), nil)

  @doc """
  The VM's `conformance` object for its payload: `nil` unless the box is
  in conformance mode. Takes what was registered for it either way.
  """
  @spec payload(Config.t(), String.t()) :: map() | nil
  def payload(%Config{conformance: true}, vm_id), do: take(vm_id) || default()

  def payload(%Config{}, vm_id) do
    take(vm_id)
    nil
  end

  defp take(vm_id) do
    params = registered(vm_id)
    if params, do: :persistent_term.erase(key(vm_id))
    params
  end

  defp key(vm_id), do: {__MODULE__, vm_id}
end
