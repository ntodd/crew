defmodule Crew do
  @moduledoc """
  The Crew control plane's core: accounts, GitHub, repos, jobs, the
  scheduler, boxes, VMs and their logs and metrics. `CrewWeb`
  depends on it, never the other way around.
  """
  use Boundary, deps: [], exports: :all
end
