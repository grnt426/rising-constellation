defmodule RC.Archive do
  @moduledoc """
  Legacy match archive: read side for the portal pages. Rows are written by
  `RC.Archive.Importer` (see `RC.Release.import_archive/3`); unpublished
  archives are only visible to admins so a fresh import can be checked
  before players see it.
  """

  import Ecto.Query, warn: false

  alias RC.Repo
  alias RC.Archive.{FactionDay, Match, Player, Unlock}

  def list_matches(params, include_unpublished? \\ false) do
    Match
    |> visible(include_unpublished?)
    |> order_by([m], desc: m.ended_at)
    |> select(
      [m],
      struct(m, [
        :id,
        :instance_id,
        :name,
        :map_name,
        :speed,
        :started_at,
        :ended_at,
        :victory_type,
        :winner_faction,
        :player_count,
        :system_count,
        :factions,
        :published
      ])
    )
    |> Repo.paginate(Map.put_new(params, "page_size", 25))
  end

  def get_match(id, include_unpublished? \\ false) do
    Match
    |> visible(include_unpublished?)
    |> Repo.get(id)
    |> case do
      nil ->
        nil

      match ->
        Repo.preload(match,
          faction_days: from(d in FactionDay, order_by: [asc: d.faction, asc: d.day]),
          players: from(p in Player, order_by: [asc: p.faction, asc: p.name]),
          unlocks: from(u in Unlock, order_by: [asc: u.kind, asc: u.key, asc: u.faction])
        )
    end
  end

  def set_published(id, published) when is_boolean(published) do
    case Repo.get(Match, id) do
      nil -> {:error, :not_found}
      match -> match |> Ecto.Changeset.change(published: published) |> Repo.update()
    end
  end

  def set_published_for_instance(instance_id, published) do
    case Repo.get_by(Match, instance_id: instance_id) do
      nil -> {:error, :not_found}
      match -> set_published(match.id, published)
    end
  end

  @doc """
  `%{instance_id => match_id}` for the given instances — the lobby's archive
  links. Same visibility rule as the reads: unpublished imports only for
  admins.
  """
  def match_ids_by_instance([], _include_unpublished?), do: %{}

  def match_ids_by_instance(instance_ids, include_unpublished?) do
    Match
    |> visible(include_unpublished?)
    |> where([m], m.instance_id in ^instance_ids)
    |> select([m], {m.instance_id, m.id})
    |> Repo.all()
    |> Map.new()
  end

  defp visible(query, true), do: query
  defp visible(query, false), do: where(query, [m], m.published == true)
end
