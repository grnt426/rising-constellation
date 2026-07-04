defmodule Instance.Faction.Government.Rules.Tetrarchy do
  @moduledoc """
  Tetrarchy — Monarchy.

  * Leader ("Tetrarch") elected by weighted plurality: every member votes,
    vote power is 3/2/1 by scoreboard third (aristocratic ranking), and
    only the top 5 players are eligible.
  * The Tetrarch appoints (and freely replaces) the Quaestor (:economy)
    and Strategos (:military).
  * No scheduled renewal — the ruler is eternal. (Deposition votes are a
    later phase, together with the stability-debuff mechanics.)
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
  def after_close(government, %{seat: :leader} = ballot, result, _ctx),
    do: Rules.seat_from_result(government, ballot, result)

  def after_close(government, _ballot, _result, _ctx), do: {government, []}

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
  defp leader_ballot(ctx) do
    ranked = Rules.scoreboard(ctx)

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
