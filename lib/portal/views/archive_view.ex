defmodule Portal.ArchiveView do
  use Portal, :view

  @list_fields [
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
  ]

  def render("index.json", %{matches: matches}) do
    Enum.map(matches, &Map.take(&1, @list_fields))
  end

  # Series are columnar — `series[faction][metric]` is a list indexed by
  # day - 1 (nil where a metric wasn't recorded that day) — which is what
  # the charts consume directly and far smaller than row objects.
  def render("show.json", %{match: match}) do
    days = match.summary["days"] || 0

    series =
      match.faction_days
      |> Enum.group_by(& &1.faction)
      |> Map.new(fn {faction, rows} ->
        by_day = Map.new(rows, &{&1.day, &1.metrics})
        keys = rows |> Enum.flat_map(&Map.keys(&1.metrics)) |> Enum.uniq()

        metrics =
          Map.new(keys, fn key ->
            {key, Enum.map(1..max(days, 1), fn d -> by_day |> Map.get(d, %{}) |> Map.get(key) end)}
          end)

        {faction, metrics}
      end)

    match
    |> Map.take(@list_fields ++ [:summary, :map])
    |> Map.merge(%{
      series: series,
      players: Enum.map(match.players, &Map.take(&1, [:profile_id, :name, :faction, :metrics, :series])),
      unlocks: Enum.map(match.unlocks, &Map.take(&1, [:kind, :key, :faction, :player_count, :first_day]))
    })
  end
end
