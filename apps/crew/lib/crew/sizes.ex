defmodule Crew.Sizes do
  @moduledoc """
  Sizes (§7.1), label aliases (§7.3) and what `CrewProtocol.Labels`
  parses with. Changing either re-parses the queued jobs (§7.4); the
  jobs context subscribes to `sizes`.
  """
  import Ecto.Query

  alias Crew.{Audit, Repo, Scope}
  alias Crew.Sizes.{LabelAlias, Size}

  @topic "sizes"

  def subscribe, do: Phoenix.PubSub.subscribe(Crew.PubSub, @topic)
  defp changed, do: Phoenix.PubSub.broadcast(Crew.PubSub, @topic, :sizes_changed)

  def list, do: Size |> order_by([s], asc: s.vcpus, asc: s.memory_mib, asc: s.name) |> Repo.all()

  def get!(id), do: Repo.get!(Size, id)
  def get(id), do: Repo.get(Size, id)

  def default, do: Repo.one(from s in Size, where: s.is_default and is_nil(s.retired_at))

  @doc "Sizes as `CrewProtocol.Labels.parse/3` takes them."
  def for_parse do
    for s <- list(),
        do: %{id: s.id, name: s.name, is_default: s.is_default, retired: Size.retired?(s)}
  end

  def list_aliases, do: LabelAlias |> order_by(:labels_key) |> preload(:size) |> Repo.all()

  def aliases_for_parse do
    for a <- Repo.all(LabelAlias),
        do: %{labels: a.labels, size_id: a.size_id, arch: String.to_existing_atom(a.arch)}
  end

  def change(%Size{} = size, attrs \\ %{}), do: Size.changeset(size, attrs)

  def create(scope, attrs), do: admin(scope, fn -> save(scope, %Size{}, attrs, "size.create") end)

  def update(scope, %Size{} = size, attrs),
    do: admin(scope, fn -> save(scope, size, attrs, "size.update") end)

  defp save(scope, size, attrs, action) do
    with {:ok, size} <- size |> Size.changeset(attrs) |> Repo.insert_or_update() do
      Audit.log(scope, action, size, %{"name" => size.name})
      changed()
      {:ok, size}
    end
  end

  @doc "Makes `size` the one default (§7.1: exactly one)."
  def make_default(scope, %Size{} = size) do
    admin(scope, fn ->
      if Size.retired?(size) do
        {:error, :retired}
      else
        Repo.transact(fn ->
          Repo.update_all(from(s in Size, where: s.is_default), set: [is_default: false])
          {:ok, size} = size |> Ecto.Changeset.change(is_default: true) |> Repo.update()
          Audit.log(scope, "size.default", size, %{"name" => size.name})
          {:ok, size}
        end)
        |> tap(fn _ -> changed() end)
      end
    end)
  end

  @doc "Retires a size: jobs asking for it become unsatisfiable (§7.1)."
  def retire(scope, %Size{} = size) do
    admin(scope, fn ->
      if size.is_default do
        {:error, :default}
      else
        with {:ok, size} <-
               size |> Ecto.Changeset.change(retired_at: DateTime.utc_now()) |> Repo.update() do
          Audit.log(scope, "size.retire", size, %{"name" => size.name})
          changed()
          {:ok, size}
        end
      end
    end)
  end

  def unretire(scope, %Size{} = size) do
    admin(scope, fn ->
      with {:ok, size} <- size |> Ecto.Changeset.change(retired_at: nil) |> Repo.update() do
        Audit.log(scope, "size.unretire", size, %{"name" => size.name})
        changed()
        {:ok, size}
      end
    end)
  end

  def create_alias(scope, attrs) do
    admin(scope, fn ->
      with {:ok, a} <- %LabelAlias{} |> LabelAlias.changeset(attrs) |> Repo.insert() do
        Audit.log(scope, "alias.create", a, %{"labels" => a.labels})
        changed()
        {:ok, a}
      end
    end)
  end

  def delete_alias(scope, %LabelAlias{} = a) do
    admin(scope, fn ->
      with {:ok, a} <- Repo.delete(a) do
        Audit.log(scope, "alias.delete", a, %{"labels" => a.labels})
        changed()
        {:ok, a}
      end
    end)
  end

  defp admin(scope, fun) do
    if Scope.admin?(scope), do: fun.(), else: {:error, :unauthorized}
  end
end
