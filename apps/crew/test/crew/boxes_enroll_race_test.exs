defmodule Crew.BoxesEnrollRaceTest do
  @moduledoc """
  A join token enrolls one agent, however many race for it (§10.2). On
  Postgres enrollments run at once, each in its own transaction on its
  own connection, so this runs outside the sandbox, against rows it
  commits and removes afterwards. SQLite takes one writer at a time, so
  there's no race there to test.
  """
  use ExUnit.Case, async: false

  if Crew.Repo.database() == "postgres" do
    import Ecto.Query

    alias Crew.{Boxes, Repo}
    alias Crew.Boxes.{Box, JoinToken}
    alias Ecto.Adapters.SQL.Sandbox

    setup do
      name = "race#{System.unique_integer([:positive])}"

      {scope, box} =
        unboxed(fn ->
          user =
            Repo.insert!(%Crew.Accounts.User{
              login: name,
              github_id: System.unique_integer([:positive]),
              name: "Race",
              role: "admin"
            })

          scope = Crew.Scope.for_user(user)
          # A box that's enrolled once already: a second token for it
          # re-enrolls, which replaces its key.
          {:ok, first} = token(scope, name)
          {:ok, box} = Boxes.enroll(first, %{"public_key" => key()})
          {scope, box}
        end)

      on_exit(fn -> unboxed(fn -> cleanup(name, scope.user.id) end) end)
      %{scope: scope, box: box, name: name}
    end

    test "only one of several enrollments racing for a token gets the box", ctx do
      {:ok, raw} = unboxed(fn -> token(ctx.scope, ctx.name) end)
      keys = for _ <- 1..8, do: key()
      parent = self()

      tasks =
        for k <- keys do
          Task.async(fn ->
            send(parent, {:ready, self()})
            receive do: (:go -> :ok)
            unboxed(fn -> Boxes.enroll(raw, %{"public_key" => k}) end)
          end)
        end

      # All at once.
      for _ <- tasks, do: assert_receive({:ready, _}, 5_000)
      for t <- tasks, do: send(t.pid, :go)
      results = Task.await_many(tasks, 30_000)

      assert Enum.count(results, &match?({:ok, _}, &1)) == 1,
             "#{Enum.count(results, &match?({:ok, _}, &1))} of 8 enrolled with one token"

      assert Enum.count(results, &(&1 == {:error, :invalid_token})) == 7

      # The box has the one winner's key.
      winner = Enum.find_index(results, &match?({:ok, _}, &1))
      stored = unboxed(fn -> Repo.get!(Box, ctx.box.id).public_key end)
      assert stored == Base.decode64!(Enum.at(keys, winner))
    end

    test "a token that's been used is refused, and stays used", ctx do
      {:ok, raw} = unboxed(fn -> token(ctx.scope, ctx.name) end)
      assert {:ok, _} = unboxed(fn -> Boxes.enroll(raw, %{"public_key" => key()}) end)

      assert {:error, :invalid_token} =
               unboxed(fn -> Boxes.enroll(raw, %{"public_key" => key()}) end)
    end

    defp unboxed(fun), do: Sandbox.unboxed_run(Repo, fun)

    defp token(scope, name),
      do: Boxes.create_join_token(scope, %{"box_name" => name, "box_type" => "mac-vm"})

    defp key do
      {public, _} = CrewProtocol.Auth.generate_keypair()
      Base.encode64(public)
    end

    defp cleanup(name, user_id) do
      box_ids = Repo.all(from b in Box, where: b.name == ^name, select: b.id)
      subjects = [name | Enum.map(box_ids, &to_string/1)]
      Repo.delete_all(from e in Crew.Activity.Event, where: e.box_id in ^box_ids)
      Repo.delete_all(from t in JoinToken, where: t.box_name == ^name)

      Repo.delete_all(
        from e in Crew.Audit.Event, where: e.actor_id == ^user_id or e.subject_id in ^subjects
      )

      Repo.delete_all(from b in Box, where: b.id in ^box_ids)
      Repo.delete_all(from u in Crew.Accounts.User, where: u.id == ^user_id)
    end
  end
end
