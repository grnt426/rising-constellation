defmodule Instance.Faction.Government.Rules.Synelle do
  @moduledoc """
  Synelle — Republic.

  * Leader elected by plurality after open nomination (anyone may
    nominate anyone, including themselves).
  * The leader nominates cabinet members; each nomination goes to a
    24-hour faction approval vote (`government_approval_duration`) that
    passes only when at least HALF the active membership approves —
    silence counts against the nominee.
  * NOMINATION WINDOW (user decision 2026-07-07): from the moment the
    leader sits with a vacant cabinet seat, they have 24h to nominate.
    Nominations open their approval elections immediately; a window that
    expires with at least one seat still un-nominated counts as TWO
    strikes and restarts. With the three-strike bar this bounds a
    nomination-less leadership to 48h.
  * Three strikes dissolve the government: the leadership is deemed
    insolvent, the leader abdicates immediately, and a fresh leader
    election opens. Rejected nominations count one strike each.
  * SNAP ELECTIONS, both directions: the leader may dissolve the cabinet
    outright (both seats vacate, the nomination window re-arms), and the
    two cabinet members may JOINTLY dissolve the leader (each files a
    consent; when both sitting heads have consented, the leader
    abdicates and a fresh election opens).
  * CRISIS VOTE: any member may call the ¾ vote of no confidence — an
    approval ballot that dissolves the leadership when three quarters of
    the active membership votes for it.
  * The leader's term expires every `government_term_synelle`: the
    leader steps down immediately (no acting leader) and a fresh leader
    election opens. Council members keep acting.
  """

  @behaviour Instance.Faction.Government.Rules

  alias Instance.Faction.Government
  alias Instance.Faction.Government.Rules

  @max_failed_nominations 3
  @window_strikes 2
  @crisis_pct 75
  @fails_key :synelle_failed_nominations
  @window_key :synelle_nomination_window
  @consents_key :synelle_snap_consents
  @cabinet [:economy, :military]

  @impl true
  def initial_ballots(ctx), do: [leader_ballot(ctx)]

  @impl true
  def by_election_ballots(:leader, ctx), do: [leader_ballot(ctx)]
  def by_election_ballots(_seat, _ctx), do: []

  @impl true
  def after_close(government, %{question: :elect, seat: :leader} = ballot, result, ctx) do
    # A new mandate starts with a clean slate: nomination credit,
    # window, and any pending cabinet-revolt consents.
    government =
      government
      |> Government.put_meta(@fails_key, 0)
      |> Government.put_meta(@window_key, nil)
      |> Government.put_meta(@consents_key, [])

    Rules.seat_from_result(government, ballot, result, ctx)
  end

  def after_close(government, %{question: :dissolve} = ballot, result, ctx) do
    case result do
      {:approved, _totals} ->
        {government, events} = dissolve(government, :crisis_vote, ctx)
        {government, events}

      {:rejected, _totals} ->
        government = Government.arm_depose_cooldown(government, ctx)
        {government, [%{type: :deposition_failed, seat: ballot.seat}]}
    end
  end

  def after_close(government, %{question: :approve} = ballot, result, ctx) do
    [appointee] = ballot.candidates

    case result do
      {:approved, _totals} ->
        government = Government.put_meta(government, @fails_key, 0)

        {government, events} =
          Government.fill_seat(government, ballot.seat, appointee,
            keep_other_seats: Government.relaxed?(ctx)
          )

        {government, events}

      {:rejected, _totals} ->
        rejection = %{
          type: :appointment_rejected,
          seat: ballot.seat,
          name: appointee.name,
          failed_rounds: Government.get_meta(government, @fails_key, 0) + 1
        }

        # The rejection re-vacates the seat: the leader gets a FRESH 24h
        # nomination clock (the old one was honored — they nominated).
        government = Government.put_meta(government, @window_key, nil)
        {government, strike_events} = add_strikes(government, 1, ctx)
        {government, [rejection | strike_events]}
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

        # Every vacant seat now nominated → the window clock stands down
        # (it re-arms fresh if a rejection re-opens a vacancy).
        government =
          if unnominated_vacancy?(government),
            do: government,
            else: Government.put_meta(government, @window_key, nil)

        {:ok, government,
         [%{type: :appointment_proposed, seat: seat, name: appointee.name} | events]}
    end
  end

  def appoint(_government, _actor_id, _seat, _appointee, _ctx), do: {:error, :not_appointable}

  # ----------------------------------------------------------------
  # Nomination window (rules tick)
  # ----------------------------------------------------------------

  # The window runs while the leader sits and at least one cabinet seat
  # is vacant with NO approval vote pending (a nominated seat is a
  # nominated seat). Expiry = two strikes, window restarts; no vacancy
  # (or no leader) disarms it.
  @impl true
  def tick(government, elapsed_time, ctx) do
    cond do
      Map.get(government.seats, :leader) == nil or not unnominated_vacancy?(government) ->
        {Government.put_meta(government, @window_key, nil), []}

      true ->
        remaining =
          case Government.get_meta(government, @window_key, nil) do
            nil -> ctx.constants.government_approval_duration
            remaining -> remaining - elapsed_time
          end

        if remaining > 0 do
          {Government.put_meta(government, @window_key, remaining), []}
        else
          government =
            Government.put_meta(government, @window_key, ctx.constants.government_approval_duration)

          expired = %{
            type: :nomination_window_expired,
            strikes: @window_strikes,
            failed_rounds: Government.get_meta(government, @fails_key, 0) + @window_strikes
          }

          {government, strike_events} = add_strikes(government, @window_strikes, ctx)
          {government, [expired | strike_events]}
        end
    end
  end

  defp unnominated_vacancy?(government) do
    Enum.any?(@cabinet, fn seat ->
      Map.get(government.seats, seat) == nil and
        not Government.open_ballot_for_seat?(government, seat)
    end)
  end

  defp add_strikes(government, count, ctx) do
    fails = Government.get_meta(government, @fails_key, 0) + count
    government = Government.put_meta(government, @fails_key, fails)

    if fails >= @max_failed_nominations,
      do: dissolve(government, :failed_nominations, ctx),
      else: {government, []}
  end

  # The leadership falls: leader abdicates immediately, fresh election.
  defp dissolve(government, reason, ctx) do
    government =
      government
      |> Government.put_meta(@fails_key, 0)
      |> Government.put_meta(@window_key, nil)
      |> Government.put_meta(@consents_key, [])

    {government, vacate_events} = Government.vacate_seat(government, :leader)
    {government, open_events} = Government.open_ballots(government, [leader_ballot(ctx)])

    {government,
     [%{type: :government_dissolved, reason: reason}] ++ vacate_events ++ open_events}
  end

  # ----------------------------------------------------------------
  # Snap elections + crisis vote
  # ----------------------------------------------------------------

  # Leader dissolves the cabinet: both seats vacate on the spot and the
  # nomination window re-arms. Refused while an approval vote runs — the
  # faction is mid-decision.
  @impl true
  def snap(government, actor_id, :cabinet, ctx) do
    cond do
      not Government.leader?(government, actor_id) ->
        {:error, :not_leader}

      Enum.any?(@cabinet, &Government.open_ballot_for_seat?(government, &1)) ->
        {:error, :ballot_already_open}

      Enum.all?(@cabinet, &(Map.get(government.seats, &1) == nil)) ->
        {:error, :seat_vacant}

      true ->
        {government, events} =
          Enum.reduce(@cabinet, {government, []}, fn seat, {government, events} ->
            {government, seat_events} = Government.vacate_seat(government, seat)
            {government, events ++ seat_events}
          end)

        government = Government.put_meta(government, @window_key, nil)
        {:ok, government, [%{type: :cabinet_dissolved, by: actor_id} | events]}
    end
  end

  # The cabinet dissolves the leader: BOTH sitting heads must consent.
  # Consents are per-player and only count while their holder still
  # sits, so a reshuffle resets the coup.
  def snap(government, actor_id, :leader, ctx) do
    holders =
      @cabinet
      |> Enum.map(&Map.get(government.seats, &1))
      |> Enum.reject(&is_nil/1)
      |> Enum.map(& &1.player_id)
      |> Enum.uniq()

    cond do
      Map.get(government.seats, :leader) == nil ->
        {:error, :seat_vacant}

      actor_id not in holders ->
        {:error, :not_cabinet}

      length(holders) < 2 ->
        {:error, :cabinet_incomplete}

      true ->
        consents =
          government
          |> Government.get_meta(@consents_key, [])
          |> Enum.filter(&(&1 in holders))
          |> Enum.concat([actor_id])
          |> Enum.uniq()

        if Enum.all?(holders, &(&1 in consents)) do
          {government, events} = dissolve(government, :cabinet_revolt, ctx)
          {:ok, government, events}
        else
          government = Government.put_meta(government, @consents_key, consents)
          {:ok, government, [%{type: :snap_consent, by: actor_id, count: length(consents)}]}
        end
    end
  end

  def snap(government, actor_id, :crisis, ctx) do
    cond do
      Government.open_ballot_for_seat?(government, :leader) ->
        {:error, :ballot_already_open}

      Map.get(government.seats, :leader) == nil ->
        {:error, :seat_vacant}

      Core.CooldownValue.locked?(Map.get(government, :depose_cooldown)) ->
        {:error, :deposition_on_cooldown}

      true ->
        spec = %{
          kind: :approval,
          seat: :leader,
          question: :dissolve,
          candidates: [],
          open_candidacy: nil,
          duration: ctx.constants.government_approval_duration,
          meta: %{approval_pct: @crisis_pct, target: Map.get(government.seats, :leader)}
        }

        {government, events} = Government.open_ballots(government, [spec])
        {:ok, government, [%{type: :crisis_vote_started, by: actor_id} | events]}
    end
  end

  def snap(_government, _actor_id, _target, _ctx), do: {:error, :not_available}

  # The republic funds its laboratories and haggles over its laws:
  # faction research −10%, faction policies +10%.
  @impl true
  def economy_mods(), do: %{patent_cost: 0.9, lex_cost: 1.1}

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
