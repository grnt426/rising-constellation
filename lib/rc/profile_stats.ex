defmodule RC.ProfileStats do
  @moduledoc """
  Aggregate, public-safe game statistics for one profile.

  Feeds the public profile endpoint (`GET /api/profiles/:pid`) and the
  Discord `/player` card. Everything here is derived from game records —
  no account fields, no PII.

  Three blocks:

    * `:legacy`   — wins / participations in *official* legacy matches:
      instances flagged `discord_ready` (the promoted, community-run
      games) at Legacy speed (`game_data->>'speed' == "slow"`), counted
      once the match has ended. A win is the profile's faction holding
      `final_rank == 1` on an instance with a `victories` row.
    * `:daily`    — daily-challenge totals: gold/silver/bronze placements
      (leaderboard ranks 1-3, same ordering as `Daily.leaderboard/2`,
      counted only for settled dates — today's board is still moving),
      runs completed (score > 0: race DNFs and idle runs score 0), and
      total days played.
    * `:factions` — matches played per faction across every game type
      except dailies, counting games that actually started (instance
      left the created/open lobby states).
  """

  import Ecto.Query

  alias Daily.Entry
  alias RC.Instances.Registration
  alias RC.Instances.Victory
  alias RC.Repo

  def for_profile(profile_id) do
    %{
      legacy: official_legacy(profile_id),
      daily: daily(profile_id),
      factions: factions_played(profile_id)
    }
  end

  defp official_legacy(profile_id) do
    from(r in Registration,
      join: f in assoc(r, :faction),
      join: i in assoc(f, :instance),
      left_join: v in Victory,
      on: v.instance_id == i.id,
      where: r.profile_id == ^profile_id,
      where: i.discord_ready == true,
      where: i.state == "ended",
      where: fragment("? ->> 'speed' = 'slow'", i.game_data),
      select: %{
        participations: count(r.id),
        wins: fragment("count(*) FILTER (WHERE ? = 1 AND ? IS NOT NULL)", f.final_rank, v.id)
      }
    )
    |> Repo.one()
    |> Map.update!(:wins, &(&1 || 0))
  end

  defp daily(profile_id) do
    totals =
      from(e in Entry,
        where: e.profile_id == ^profile_id,
        select: %{
          played: count(e.id),
          completed: fragment("count(*) FILTER (WHERE ? > 0)", e.score)
        }
      )
      |> Repo.one()

    settled_before = Date.to_iso8601(Daily.today())

    # Placements are never stored (see Daily.leaderboard/2) — rank every
    # settled day with the same ordering the leaderboard uses, then count
    # this profile's podium finishes. ISO dates compare lexicographically,
    # so a plain string < works for "settled".
    ranked =
      from(e in Entry,
        where: e.date < ^settled_before,
        select: %{
          profile_id: e.profile_id,
          pos:
            over(row_number(),
              partition_by: e.date,
              order_by: [desc: e.score, desc: e.tiebreak, asc: e.updated_at]
            )
        }
      )

    medals =
      from(r in subquery(ranked),
        where: r.profile_id == ^profile_id and r.pos <= 3,
        group_by: r.pos,
        select: {r.pos, count()}
      )
      |> Repo.all()
      |> Map.new()

    %{
      gold: Map.get(medals, 1, 0),
      silver: Map.get(medals, 2, 0),
      bronze: Map.get(medals, 3, 0),
      completed: totals.completed || 0,
      played: totals.played
    }
  end

  defp factions_played(profile_id) do
    from(r in Registration,
      join: f in assoc(r, :faction),
      join: i in assoc(f, :instance),
      where: r.profile_id == ^profile_id,
      where: fragment("COALESCE(? ->> 'game_mode_type', '') != 'daily'", i.game_data),
      where: i.state not in ["created", "open"],
      group_by: f.faction_ref,
      select: {f.faction_ref, count(r.id)}
    )
    |> Repo.all()
    |> Map.new()
  end
end
