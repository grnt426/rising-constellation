defmodule Instance.Faction.Government.Ballot do
  use TypedStruct
  use Util.MakeEnumerable

  alias Core.CooldownValue
  alias Instance.Faction.Government.Ballot

  # A single vote event inside a faction government: electing a seat,
  # approving an appointee, etc. The engine (Government module) owns the
  # lifecycle — this module owns the per-ballot state transitions and
  # the tally.
  #
  # Ballot kinds map the five faction election systems onto one
  # primitive, "a ballot where voters attach a stake to a candidate":
  #
  #   :plurality     — free vote, optionally weighted (Tetrarchy thirds).
  #   :approval      — approve/reject a single proposed appointee (Synelle).
  #   :stake_pledge  — voters pledge a share of their ideology income
  #                    (Cardan); stakes are SECRET, only a quorum boolean
  #                    is ever broadcast.
  #   :stake_bid     — voters escrow credits on a candidate (ARK); running
  #                    per-candidate totals are public (it's an auction).
  #
  # SECRECY: `votes` and `weights` are never serialized (see jason/0).
  # Everything the client may see is recomputed into `public` after each
  # mutation. A viewer's own vote travels only through the per-viewer
  # `get_government` RPC reply, never through faction broadcasts.

  @results_precision 1

  def jason(),
    do: [
      only: [
        :id,
        :group,
        :kind,
        :seat,
        :question,
        :candidates,
        :open_candidacy,
        :cooldown,
        :public
      ]
    ]

  typedstruct enforce: true do
    field(:id, integer())
    field(:group, String.t() | nil)
    field(:kind, atom())
    field(:seat, atom())
    field(:question, atom())
    field(:candidates, [map()])
    field(:open_candidacy, atom() | nil)
    field(:votes, map())
    field(:weights, map() | nil)
    field(:cooldown, %CooldownValue{})
    field(:quorum, map() | nil)
    field(:meta, map())
    field(:public, map())
  end

  def new(id, spec) do
    %Ballot{
      id: id,
      group: Map.get(spec, :group),
      kind: Map.fetch!(spec, :kind),
      seat: Map.fetch!(spec, :seat),
      question: Map.get(spec, :question, :elect),
      candidates: Map.get(spec, :candidates, []),
      open_candidacy: Map.get(spec, :open_candidacy),
      votes: %{},
      weights: Map.get(spec, :weights),
      cooldown: CooldownValue.new(Map.fetch!(spec, :duration)),
      quorum: Map.get(spec, :quorum),
      meta: Map.get(spec, :meta, %{}),
      public: %{}
    }
    |> refresh_public()
  end

  def next_tick(%Ballot{} = ballot, elapsed_time) do
    %{ballot | cooldown: CooldownValue.next_tick(ballot.cooldown, elapsed_time)}
  end

  def expired?(%Ballot{} = ballot), do: not CooldownValue.locked?(ballot.cooldown)

  def candidate?(%Ballot{} = ballot, player_id),
    do: Enum.any?(ballot.candidates, &(&1.player_id == player_id))

  # Candidacy is validated by the engine (roster membership, open_candidacy
  # policy, cross-ballot constraints); this only guards double-adds.
  def add_candidate(%Ballot{} = ballot, %{player_id: _, name: _} = candidate) do
    if candidate?(ballot, candidate.player_id) do
      {:error, :already_candidate}
    else
      {:ok, refresh_public(%{ballot | candidates: ballot.candidates ++ [candidate]})}
    end
  end

  # One vote per voter; re-casting replaces the previous vote except for
  # :stake_bid, where the auction only moves up (handled by the engine,
  # which passes the already-accumulated stake).
  def cast_vote(%Ballot{} = ballot, voter_id, vote) do
    order = Map.get(ballot.meta, :cast_counter, 0)
    vote = Map.put(vote, :order, Map.get(Map.get(ballot.votes, voter_id, %{}), :order, order))

    ballot = %{
      ballot
      | votes: Map.put(ballot.votes, voter_id, vote),
        meta: Map.put(ballot.meta, :cast_counter, order + 1)
    }

    {:ok, refresh_public(ballot)}
  end

  def voter_stake(%Ballot{} = ballot, voter_id) do
    case Map.get(ballot.votes, voter_id) do
      nil -> 0
      vote -> Map.get(vote, :stake, 0)
    end
  end

  @doc """
  Public (broadcast-safe) view of a voter's own ballot entry, for the
  per-viewer `get_government` reply.
  """
  def own_vote(%Ballot{} = ballot, voter_id) do
    case Map.get(ballot.votes, voter_id) do
      nil -> nil
      vote -> Map.take(vote, [:choice, :stake, :pct])
    end
  end

  @doc """
  Tally the ballot. Returns one of:

    {:winner, %{player_id, name}, totals}
    {:approved, totals} | {:rejected, totals}
    {:failed, reason, totals}

  `totals` is the per-candidate aggregate list (no voter identities) used
  for the post-close results display. Quorum for grouped ballots is NOT
  checked here — the engine owns cross-ballot quorum.
  """
  @doc """
  Approval tally: passes when at least half the faction's ACTIVE members
  approved. Silence counts against the nominee — an unanswered
  nomination is a failed nomination (this arms Synelle's dissolution
  counter), so a majority of votes cast is deliberately NOT the bar.
  """
  def tally_approval(%Ballot{kind: :approval} = ballot, active_count) do
    {approve, reject} =
      Enum.reduce(ballot.votes, {0, 0}, fn {_voter, vote}, {a, r} ->
        case vote.choice do
          :approve -> {a + 1, r}
          :reject -> {a, r + 1}
        end
      end)

    totals = [
      %{choice: :approve, amount: approve},
      %{choice: :reject, amount: reject},
      %{choice: :required, amount: required_approvals(active_count)}
    ]

    if approve >= required_approvals(active_count),
      do: {:approved, totals},
      else: {:rejected, totals}
  end

  defp required_approvals(active_count), do: max(ceil(active_count / 2), 1)

  def tally(%Ballot{} = ballot) do
    totals = candidate_totals(ballot)
    total_amount = Enum.reduce(totals, 0, &(&1.amount + &2))

    cond do
      Enum.empty?(ballot.candidates) ->
        {:failed, :no_candidates, totals}

      total_amount <= 0 ->
        {:failed, :no_votes, totals}

      true ->
        [best | rest] = Enum.sort_by(totals, &{-&1.amount, &1.first_order})

        # Dead heat on both amount and cast order can't happen (orders are
        # unique), so `best` is deterministic: highest amount, earliest to
        # have received a vote among tied leaders.
        _ = rest
        winner = Enum.find(ballot.candidates, &(&1.player_id == best.player_id))
        {:winner, winner, totals}
    end
  end

  @doc "Sum of all stakes on this ballot (Cardan group quorum input)."
  def total_stake(%Ballot{} = ballot) do
    Enum.reduce(ballot.votes, 0, fn {_voter, vote}, acc -> acc + Map.get(vote, :stake, 0) end)
  end

  @doc """
  Per-candidate aggregates: `%{player_id, name, amount, share, first_order}`.
  `share` is the candidate's percentage of the grand total (post-close
  results display); voter identities never appear.
  """
  def candidate_totals(%Ballot{} = ballot) do
    base =
      Map.new(ballot.candidates, fn c ->
        {c.player_id, %{player_id: c.player_id, name: c.name, amount: 0, first_order: nil}}
      end)

    totals =
      Enum.reduce(ballot.votes, base, fn {voter_id, vote}, acc ->
        amount =
          case ballot.kind do
            :plurality -> weight_of(ballot, voter_id)
            _ -> Map.get(vote, :stake, 0)
          end

        Map.update(acc, vote.choice, nil, fn entry ->
          first_order = min(entry.first_order || vote.order, vote.order)
          %{entry | amount: entry.amount + amount, first_order: first_order}
        end)
      end)
      |> Map.values()
      |> Enum.reject(&is_nil/1)

    grand_total = Enum.reduce(totals, 0, &(&1.amount + &2))

    Enum.map(totals, fn entry ->
      share =
        if grand_total > 0,
          do: Float.round(entry.amount / grand_total * 100, @results_precision),
          else: 0.0

      entry
      |> Map.put(:share, share)
      |> Map.update!(:first_order, &(&1 || 0))
    end)
  end

  defp weight_of(%Ballot{weights: nil}, _voter_id), do: 1
  defp weight_of(%Ballot{weights: weights}, voter_id), do: Map.get(weights, voter_id, 1)

  # `public` is the only vote-derived data that rides the faction
  # broadcast. Stake identities and per-candidate numbers stay hidden
  # while a ballot is open, with two exceptions: :stake_bid is an open
  # auction (running totals public by design), and quorum ballots expose
  # a BUCKETED progress stage (0..3) that feeds the staged indicator
  # without revealing the sums.
  def refresh_public(%Ballot{} = ballot) do
    public = %{
      vote_count: map_size(ballot.votes),
      quorum_stage: quorum_stage(ballot),
      totals: if(ballot.kind == :stake_bid, do: strip_orders(candidate_totals(ballot)))
    }

    %{ballot | public: public}
  end

  defp strip_orders(totals), do: Enum.map(totals, &Map.drop(&1, [:first_order]))

  # The engine injects the group-wide stage via meta (:quorum_stage)
  # after each mutation; a ballot with no quorum spec reports nil (UI
  # hides the indicator).
  defp quorum_stage(%Ballot{quorum: nil}), do: nil
  defp quorum_stage(%Ballot{meta: meta}), do: Map.get(meta, :quorum_stage, 0)
end
