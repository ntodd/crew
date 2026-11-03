defmodule Crew.SetupTest do
  use Crew.DataCase

  test "boot gives the deployment an id even when the App comes from the environment" do
    assert Crew.Settings.deployment_id() == nil
    Crew.Setup.on_boot()
    assert CrewProtocol.Names.deployment_id?(Crew.Settings.deployment_id())

    id = Crew.Settings.deployment_id()
    Crew.Setup.on_boot()
    assert Crew.Settings.deployment_id() == id
  end
end
