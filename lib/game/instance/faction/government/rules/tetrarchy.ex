defmodule Instance.Faction.Government.Rules.Tetrarchy do
  @moduledoc """
  Tetrarchy — Monarchy.

  * Leader ("Tetrarch") elected by weighted plurality: every member votes,
    vote power is 3/2/1 by scoreboard third (aristocratic ranking), and
    only the top 5 players are eligible.
  * The Tetrarch appoints (and freely replaces) the Quaestor (:economy)
    and Strategos (:military).
  * No scheduled renewal — the ruler is eternal, unless DEPOSED: any
    member may call a deposition vote, which is the leader election
    inverted — same 3/2/1 scoreboard weights, and it passes only when
    the approving weight reaches half of the TOTAL snapshot weight
    (silence protects the incumbent). A rebuffed coup arms the
    faction-wide deposition cooldown.
  """

  @behaviour Instance.Faction.Government.Rules

  alias Instance.Faction.Government
  alias Instance.Faction.Government.Rules

  @eligible_count 5

  @impl true
  def initial_ballots(ctx), do: [leader_ballot(ctx)]

  @impl true
  def by_election_ballots(:leader, ctx), do: [leader_ballot(ctx)]
  def by_election_ballots(_seat, _ctx), do: []

  @impl true
  def after_close(government, %{question: :depose} = ballot, result, ctx),
    do: Rules.settle_deposition(government, ballot, result, ctx)

  def after_close(government, %{seat: :leader} = ballot, result, ctx),
    do: Rules.seat_from_result(government, ballot, result, ctx)

  def after_close(government, _ballot, _result, _ctx), do: {government, []}

  # "Deposition = the same ballot inverted": the weighted electorate
  # votes to unseat the Tetrarch. Council seats are appointed, so the
  # only deposable chair is the throne.
  @impl true
  def deposition_ballot(government, :leader, ctx) do
    %{
      kind: :approval,
      seat: :leader,
      question: :depose,
      candidates: [],
      open_candidacy: nil,
      weights: third_weights(active_scoreboard(ctx)),
      duration: ctx.constants.government_approval_duration,
      meta: %{target: Map.get(government.seats, :leader)}
    }
  end

  def deposition_ballot(_government, _seat, _ctx), do: nil

  @impl true
  def appoint(government, actor_id, seat, appointee, _ctx)
      when seat in [:economy, :military] do
    if Government.leader?(government, actor_id) do
      {government, events} = Government.fill_seat(government, seat, appointee)
      {:ok, government, events}
    else
      {:error, :not_leader}
    end
  end

  def appoint(_government, _actor_id, _seat, _appointee, _ctx), do: {:error, :not_appointable}

  @impl true
  def term_spec(_ctx), do: nil

  @impl true
  def on_term_expired(government, _ctx), do: {government, []}

  # Weighted plurality: candidates are the scoreboard top 5, weights are
  # 3/2/1 by scoreboard third, both snapshotted at ballot open so a
  # mid-vote scoreboard swing can't retro-change already-cast votes.
  # The scoreboard is filtered to ACTIVE members first (user rule
  # 2026-07-07): an AFK grandee neither runs, votes with weight, nor
  # inflates the deposition bar.
  defp leader_ballot(ctx) do
    ranked = active_scoreboard(ctx)

    candidates =
      ranked
      |> Enum.take(@eligible_count)
      |> Enum.map(fn {player, _points} -> %{player_id: player.id, name: player.name} end)

    %{
      kind: :plurality,
      seat: :leader,
      candidates: candidates,
      open_candidacy: nil,
      weights: third_weights(ranked),
      duration: ctx.constants.government_election_duration
    }
  end

  defp active_scoreboard(ctx) do
    active = ctx.active_player_ids.()
    Enum.filter(Rules.scoreboard(ctx), fn {player, _points} -> player.id in active end)
  end

  defp third_weights(ranked) do
    count = length(ranked)
    third = ceil(count / 3)

    ranked
    |> Enum.with_index()
    |> Map.new(fn {{player, _points}, index} ->
      weight =
        cond do
          index < third -> 3
          index < third * 2 -> 2
          true -> 1
        end

      {player.id, weight}
    end)
  end
end
