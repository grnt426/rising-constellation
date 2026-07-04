defmodule Instance.Faction.Government.Rules.Myrmezir do
  @moduledoc """
  Myrmezir — Democracy.

  * All three seats are elected directly: one person, one vote.
  * Candidates declare themselves for exactly one seat (checked across
    the whole election group).
  * Fixed mandate: the whole cycle re-runs every term. Sitting members
    keep their seats (acting heads) until the new results land.
  """

  @behaviour Instance.Faction.Government.Rules

  alias Instance.Faction.Government.Rules

  @impl true
  def initial_ballots(ctx), do: seat_ballots(Rules.seats(), "cycle-1", ctx)

  @impl true
  def by_election_ballots(seat, ctx), do: seat_ballots([seat], nil, ctx)

  @impl true
  def after_close(government, ballot, result, _ctx),
    do: Rules.seat_from_result(government, ballot, result)

  @impl true
  def appoint(_government, _actor_id, _seat, _appointee, _ctx), do: {:error, :elected_seats}

  @impl true
  def term_spec(ctx),
    do: %{duration: ctx.constants.government_term_myrmezir, scope: :all}

  @impl true
  def on_term_expired(government, ctx) do
    cycle = "cycle-#{government.counter}"

    {government, events} =
      Instance.Faction.Government.open_ballots(government, seat_ballots(Rules.seats(), cycle, ctx))

    {government, [%{type: :elections_opened, seats: Rules.seats(), renewal: true} | events]}
  end

  defp seat_ballots(seats, group, ctx) do
    Enum.map(seats, fn seat ->
      %{
        kind: :plurality,
        seat: seat,
        group: group,
        candidates: [],
        open_candidacy: :self_only,
        duration: ctx.constants.government_election_duration
      }
    end)
  end
end
