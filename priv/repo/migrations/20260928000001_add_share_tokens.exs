defmodule RC.Repo.Migrations.AddShareTokens do
  use Ecto.Migration

  import Ecto.Query

  # Unguessable per-row share tokens (see RC.ShareToken). New rows get one
  # from the schemas' autogenerate; existing rows are backfilled here.
  # Generated in Elixir rather than SQL because dev/CI run Postgres 12,
  # which has no core gen_random_uuid().
  @tables ["scenarios", "instances"]

  def up do
    for table <- @tables do
      alter(table(table), do: add(:share_token, :string))
    end

    flush()

    for table <- @tables do
      table
      |> from(select: [:id])
      |> repo().all()
      |> Enum.each(fn %{id: id} ->
        repo().query!("UPDATE #{table} SET share_token = $1 WHERE id = $2", [token(), id])
      end)

      alter(table(table), do: modify(:share_token, :string, null: false))
      create(unique_index(table, [:share_token]))
    end
  end

  def down do
    for table <- @tables do
      alter(table(table), do: remove(:share_token))
    end
  end

  # Same shape as RC.ShareToken.generate/0, inlined so the migration
  # never depends on application code that may change later.
  defp token, do: 12 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
end
