defmodule Crew.ActivityTest do
  use Crew.DataCase

  alias Crew.Activity

  test "records an event and broadcasts it" do
    Activity.subscribe()
    event = Activity.record("box_joined", "m3max joined", box_id: CrewProtocol.uuid7())
    assert_receive {:activity, %Activity.Event{id: id, message: "m3max joined"}}
    assert id == event.id
  end

  test "recent/1 is newest first" do
    first = Activity.record("notice", "first")
    second = Activity.record("notice", "second")
    scope = Crew.Scope.for_user(user_fixture(role: "admin"))
    assert [%{id: a}, %{id: b} | _] = Activity.recent(scope, 10)
    assert {a, b} == {second.id, first.id}
  end

  test "members see repo events masked, in the stored history too" do
    member = Crew.Scope.for_user(user_fixture())
    admin = Crew.Scope.for_user(user_fixture(role: "admin"))
    repo_id = CrewProtocol.uuid7()

    Activity.record("fork_refused", "Refused a fork PR on acme/secret-project",
      repo_id: repo_id,
      masked: "Refused a fork PR in another repo"
    )

    assert [%{message: "Refused a fork PR in another repo"}] = Activity.recent(member, 10)
    assert [%{message: "Refused a fork PR on acme/secret-project"}] = Activity.recent(admin, 10)
  end

  test "a repo event without a masked text still never shows the repo" do
    member = Crew.Scope.for_user(user_fixture())
    Activity.record("notice", "acme/secret-project did a thing", repo_id: CrewProtocol.uuid7())
    assert [%{message: message}] = Activity.recent(member, 10)
    refute message =~ "secret-project"
  end

  test "only known kinds" do
    assert_raise FunctionClauseError, fn -> Activity.record("made_up", "x") end
  end
end
