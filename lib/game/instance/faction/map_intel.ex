defmodule Instance.Faction.MapIntel do
  @moduledoc """
  What the galaxy map draws around systems and totals on the sector card:
  who stands where (fleets and other agents), how well the faction's own
  systems hold, and what each faction earns sector by sector, as far as
  the viewing faction can read it.

  A compact projection of the Galactic Survey rows, so it follows the same
  visibility gates (`GalacticSurvey`, `Faction.StellarSystem.obfuscate/4`)
  and shares the survey's per-faction cache: asking for one never rebuilds
  the other.

  Systems with nothing to draw are left out. The limit of the survey applies
  here too: an agent standing in a system the faction has no contact with
  is not listed.
  """

  @doc """
  Projects survey `rows` for the faction `faction_key`.

      %{
        systems: [%{id, sector_id, own, siege, defense, stability,
                    counter_intelligence, agents: [%{id, type, faction, level, upkeep}]}],
        sectors: [%{id, faction, systems, technology, ideology, credit}]
      }

  A `sectors` entry sums one faction's systems in one sector, counting only
  those whose income the viewing faction can read (its own, and any other
  at contact 4 or more); `systems` is how many that is. A faction with no
  readable system in a sector has no entry there.

  `agents` holds the agents in orbit (not the governor, not students).
  `upkeep` is nil for anything but a fleet whose army the faction can read.
  The three system values are nil below the contact level that shows them.
  """
  def project(rows, faction_key) when is_list(rows) do
    %{
      systems: rows |> Enum.map(&system(&1, faction_key)) |> Enum.reject(&is_nil/1),
      sectors: sectors(rows)
    }
  end

  defp system(row, faction_key) do
    own? = row.faction == faction_key
    agents = Enum.map(row.agents || [], &Map.take(&1, [:id, :type, :faction, :level, :upkeep]))
    siege? = Map.get(row, :siege, false)

    if own? or agents != [] or siege? do
      %{
        id: row.id,
        sector_id: row.sector_id,
        own: own?,
        siege: siege?,
        defense: Map.get(row, :defense),
        stability: Map.get(row, :stability),
        counter_intelligence: Map.get(row, :counter_intelligence),
        agents: agents
      }
    else
      nil
    end
  end

  # Income by sector and faction. A row carries a system's income only from
  # the contact level that shows it (GalacticSurvey: nil below 4), so each
  # sum covers exactly the systems the faction can read. Neutral systems
  # belong to no faction and are left out.
  defp sectors(rows) do
    rows
    |> Enum.filter(&(&1.faction != nil and is_number(Map.get(&1, :current_credit))))
    |> Enum.group_by(&{&1.sector_id, &1.faction})
    |> Enum.map(fn {{sector_id, faction}, readable} ->
      %{
        id: sector_id,
        faction: faction,
        systems: length(readable),
        technology: sum(readable, :current_sci),
        ideology: sum(readable, :current_appeal),
        credit: sum(readable, :current_credit)
      }
    end)
  end

  defp sum(rows, field) do
    Enum.reduce(rows, 0, fn row, acc ->
      case Map.get(row, field) do
        n when is_number(n) -> acc + n
        _ -> acc
      end
    end)
  end
end
