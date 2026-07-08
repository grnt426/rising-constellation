defmodule Instance.Faction.Government.Rules.Myrmezir do
  @moduledoc """
  Myrmezir — Democracy.

  * All three seats are elected directly: one person, one vote.
  * Candidates declare themselves for exactly one seat (checked across
    the whole election group).
  * Fixed mandate: the whole cycle re-runs every term. Sitting members
    keep their seats (acting heads) until the new results land.
  * Direct democracy teeth: any member may call a NO-CONFIDENCE vote on
    any seat (one person one vote, passes at half the active
    membership), and lex enactment is a REFERENDUM — the President
    proposes a law set, the faction approves or rejects it within 24h.
  """

  @behaviour Instance.Faction.Government.Rules

  alias Instance.Faction.Government
  alias Instance.Faction.Government.Rules

  @impl true
  def initial_ballots(ctx), do: seat_ballots(Rules.seats(), "cycle-1", ctx)

  @impl true
  def by_election_ballots(seat, ctx), do: seat_ballots([seat], nil, ctx)

  @impl true
  def after_close(government, %{question: :depose} = ballot, result, ctx),
    do: Rules.settle_deposition(government, ballot, result, ctx)

  def after_close(government, %{question: :laws} = ballot, result, ctx) do
    keys = Map.get(ballot.meta, :keys, [])

    case result do
      {:approved, _totals} ->
        {government, apply_events} = Government.apply_laws(government, keys, ctx)
        {government, apply_events ++ [%{type: :laws_changed, laws: keys, by: nil}]}

      {:rejected, _totals} ->
        {government, [%{type: :laws_rejected, laws: keys}]}
    end
  end

  def after_close(government, ballot, result, ctx),
    do: Rules.seat_from_result(government, ballot, result, ctx)

  @impl true
  def laws_referendum?(), do: true

  # Every seat answers to the assembly: one person, one vote, half the
  # active membership to unseat. Silence protects the incumbent.
  @impl true
  def deposition_ballot(government, seat, ctx) do
    %{
      kind: :approval,
      seat: seat,
      question: :depose,
      candidates: [],
      open_candidacy: nil,
      duration: ctx.constants.government_approval_duration,
      meta: %{target: Map.get(government.seats, seat)}
    }
  end

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
