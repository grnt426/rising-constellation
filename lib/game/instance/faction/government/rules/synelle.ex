defmodule Instance.Faction.Government.Rules.Synelle do
  @moduledoc """
  Synelle — Republic.

  * Leader elected by plurality after open nomination (anyone may
    nominate anyone, including themselves).
  * The leader nominates cabinet members; each nomination goes to a
    24-hour faction approval vote (`government_approval_duration`) that
    passes only when at least HALF the active membership approves —
    silence counts against the nominee.
  * Three consecutive failed nominations dissolve the government: the
    leadership is deemed insolvent, the leader abdicates immediately,
    and a fresh leader election opens. This bounds a cabinet-less
    republic to ~3 days instead of the full 11-day term.
  * The leader's term expires every `government_term_synelle`: the
    leader steps down immediately (no acting leader) and a fresh leader
    election opens. Council members keep acting.

  Snap elections and the 3/4 crisis vote are a later phase.
  """

  @behaviour Instance.Faction.Government.Rules

  alias Instance.Faction.Government
  alias Instance.Faction.Government.Rules

  @max_failed_nominations 3
  @fails_key :synelle_failed_nominations

  @impl true
  def initial_ballots(ctx), do: [leader_ballot(ctx)]

  @impl true
  def by_election_ballots(:leader, ctx), do: [leader_ballot(ctx)]
  def by_election_ballots(_seat, _ctx), do: []

  @impl true
  def after_close(government, %{question: :elect, seat: :leader} = ballot, result, _ctx) do
    # A new mandate starts with a clean slate of nomination credit.
    government = Government.put_meta(government, @fails_key, 0)
    Rules.seat_from_result(government, ballot, result)
  end

  def after_close(government, %{question: :approve} = ballot, result, ctx) do
    [appointee] = ballot.candidates

    case result do
      {:approved, _totals} ->
        government = Government.put_meta(government, @fails_key, 0)
        {government, events} = Government.fill_seat(government, ballot.seat, appointee)
        {government, events}

      {:rejected, _totals} ->
        fails = Government.get_meta(government, @fails_key, 0) + 1
        government = Government.put_meta(government, @fails_key, fails)

        rejection = %{
          type: :appointment_rejected,
          seat: ballot.seat,
          name: appointee.name,
          failed_rounds: fails
        }

        if fails >= @max_failed_nominations do
          government = Government.put_meta(government, @fails_key, 0)
          {government, vacate_events} = Government.vacate_seat(government, :leader)
          {government, open_events} = Government.open_ballots(government, [leader_ballot(ctx)])

          {government,
           [rejection, %{type: :government_dissolved, reason: :failed_nominations}] ++
             vacate_events ++ open_events}
        else
          {government, [rejection]}
        end
    end
  end

  def after_close(government, _ballot, _result, _ctx), do: {government, []}

  # The leader proposes; the faction disposes. Each appointment opens an
  # approval ballot instead of filling the seat directly.
  @impl true
  def appoint(government, actor_id, seat, appointee, ctx)
      when seat in [:economy, :military] do
    cond do
      not Government.leader?(government, actor_id) ->
        {:error, :not_leader}

      Government.open_ballot_for_seat?(government, seat) ->
        {:error, :ballot_already_open}

      true ->
        spec = %{
          kind: :approval,
          seat: seat,
          question: :approve,
          candidates: [appointee],
          open_candidacy: nil,
          duration: ctx.constants.government_approval_duration
        }

        {government, events} = Government.open_ballots(government, [spec])

        {:ok, government,
         [%{type: :appointment_proposed, seat: seat, name: appointee.name} | events]}
    end
  end

  def appoint(_government, _actor_id, _seat, _appointee, _ctx), do: {:error, :not_appointable}

  @impl true
  def term_spec(ctx),
    do: %{duration: ctx.constants.government_term_synelle, scope: :leader}

  @impl true
  def on_term_expired(government, ctx) do
    {government, vacate_events} = Government.vacate_seat(government, :leader)
    {government, open_events} = Government.open_ballots(government, [leader_ballot(ctx)])

    {government,
     [%{type: :elections_opened, seats: [:leader], renewal: true}] ++
       vacate_events ++ open_events}
  end

  defp leader_ballot(ctx) do
    %{
      kind: :plurality,
      seat: :leader,
      candidates: [],
      open_candidacy: :anyone,
      duration: ctx.constants.government_election_duration
    }
  end
end
