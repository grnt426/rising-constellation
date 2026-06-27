defmodule RC.InstanceFirsts do
  @moduledoc """
  Context for `RC.Instances.InstanceFirst`. The only interesting
  operation is `claim/1`, which atomically tries to insert a "first to
  X" row and reports whether the caller actually was first.
  """

  import Ecto.Query, warn: false

  alias RC.Repo
  alias RC.Instances.InstanceFirst

  @doc """
  Attempt to claim a "first" for the given instance + first_key. Uses
  Postgres `ON CONFLICT DO NOTHING` against the unique index — if the
  insert returns a row, this caller was the first. If it returns
  nothing, someone else already claimed it.

  Returns:
    * `{:ok, %InstanceFirst{}}` — this caller is the first.
    * `{:already_claimed, %InstanceFirst{} | nil}` — someone else got
      there first; the existing row is included when we can fetch it
      (it's nil only if the row was concurrently deleted, which only
      happens on instance teardown).
  """
  def claim(attrs) when is_map(attrs) do
    changeset = InstanceFirst.changeset(%InstanceFirst{}, attrs)

    case Repo.insert(changeset, on_conflict: :nothing, returning: true) do
      {:ok, %InstanceFirst{id: nil}} ->
        # ON CONFLICT DO NOTHING returns a struct with id=nil when the
        # row already existed. Look up the prior winner and report it.
        {:already_claimed, get(attrs[:instance_id] || attrs["instance_id"], attrs[:first_key] || attrs["first_key"])}

      {:ok, %InstanceFirst{} = first} ->
        {:ok, first}

      {:error, _changeset} = err ->
        err
    end
  end

  @doc """
  Look up an existing first claim. Returns `nil` if no one has claimed it.
  """
  def get(instance_id, first_key) do
    Repo.get_by(InstanceFirst, instance_id: instance_id, first_key: first_key)
  end
end
