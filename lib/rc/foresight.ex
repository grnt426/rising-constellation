defmodule RC.Foresight do
  @moduledoc """
  Foresight — friendly match predictions with Foresight Tokens and
  Foresight Points (docs/foresight.md).

  Placement (`commit/4`), the join-time refund hook (`return_on_join/2`),
  portal queries, and settlement orchestration (`settle/2`, `void/2`).
  The math itself lives in `RC.Foresight.Settlement` (pure); this module
  owns the database choreography:

    * balance debits are race-safe conditional `update_all`s (the
      `RC.Offers.transition_status/3` doctrine) — no locks;
    * the courtesy allowance is enforced by a partial unique index, not
      by application checks;
    * settlement is exactly-once via the `foresight_settlements` latch —
      the inline victory hook and the sweeper can race freely.
  """

  import Ecto.Query, warn: false

  require Logger

  alias Ecto.Multi
  alias RC.Accounts.Account
  alias RC.Accounts.Profile
  alias RC.Foresight.Prediction
  alias RC.Foresight.Settlement
  alias RC.Foresight.SettlementRecord
  alias RC.Instances.Faction
  alias RC.Instances.Instance
  alias RC.Instances.InstanceState
  alias RC.Instances.Registration
  alias RC.Instances.Victory
  alias RC.Repo

  # Rule 3: the window opens at match start (faction choice is locked
  # then, killing the predict-then-join dodge). paused/not_running still
  # count as started.
  @started_states ~w(running paused not_running)
  # Legacy / Tactical / Flash. Excludes "daily" (and any future
  # non-competitive speeds).
  @predictable_speeds ~w(slow medium fast)

  ## Placement

  @doc """
  Commits `tokens` FT from `account_id` on `faction_id` winning
  `instance_id`. Returns `{:ok, %Prediction{}}` or `{:error, reason}`
  with an atom reason suitable for the API layer:

  `:invalid_tokens`, `:not_found`, `:not_predictable`,
  `:match_not_started`, `:window_closed`, `:unknown_faction`,
  `:own_faction_only`, `:single_faction_per_match`,
  `:insufficient_tokens`, `:courtesy_in_use`
  """
  def commit(account_id, instance_id, faction_id, tokens) do
    with :ok <- check_tokens(tokens),
         {:ok, instance} <- fetch_instance(instance_id),
         :ok <- check_predictable(instance),
         :ok <- check_window(instance_id),
         {:ok, faction} <- fetch_faction(instance, faction_id),
         :ok <- check_own_faction(account_id, instance_id, faction_id),
         :ok <- check_single_faction(account_id, instance_id, faction_id) do
      place(account_id, instance_id, faction, tokens)
    end
  end

  defp check_tokens(tokens) when is_integer(tokens) and tokens > 0, do: :ok
  defp check_tokens(_tokens), do: {:error, :invalid_tokens}

  defp fetch_instance(instance_id) do
    case Repo.get(Instance, instance_id) |> Repo.preload(:factions) do
      nil -> {:error, :not_found}
      instance -> {:ok, instance}
    end
  end

  defp check_predictable(instance) do
    speed = Map.get(instance.game_data || %{}, "speed")

    cond do
      instance.is_bot_only -> {:error, :not_predictable}
      speed not in @predictable_speeds -> {:error, :not_predictable}
      instance.state not in @started_states -> {:error, :match_not_started}
      true -> :ok
    end
  end

  defp check_window(instance_id) do
    if decided_or_settled?(instance_id), do: {:error, :window_closed}, else: :ok
  end

  defp fetch_faction(instance, faction_id) do
    case Enum.find(instance.factions, &(&1.id == faction_id)) do
      nil -> {:error, :unknown_faction}
      faction -> {:ok, faction}
    end
  end

  # Rule 5: a registered player may only back their own faction.
  defp check_own_faction(account_id, instance_id, faction_id) do
    case registered_faction_id(account_id, instance_id) do
      nil -> :ok
      ^faction_id -> :ok
      _other -> {:error, :own_faction_only}
    end
  end

  # Rule 6: all of an account's predictions in a match target one faction.
  defp check_single_faction(account_id, instance_id, faction_id) do
    conflicting =
      from(p in Prediction,
        where:
          p.account_id == ^account_id and p.instance_id == ^instance_id and
            p.status == "active" and p.faction_id != ^faction_id
      )
      |> Repo.exists?()

    if conflicting, do: {:error, :single_faction_per_match}, else: :ok
  end

  defp place(account_id, instance_id, faction, tokens) do
    Multi.new()
    |> Multi.run(:debit, fn repo, _changes -> debit(repo, account_id, tokens) end)
    |> Multi.insert(:prediction, fn %{debit: credited_tokens} ->
      Prediction.changeset(%Prediction{}, %{
        account_id: account_id,
        instance_id: instance_id,
        faction_id: faction.id,
        faction_ref: faction.faction_ref,
        tokens: tokens,
        credited_tokens: credited_tokens
      })
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{prediction: prediction}} ->
        {:ok, prediction}

      {:error, :debit, reason, _changes} ->
        {:error, reason}

      {:error, :prediction, %Ecto.Changeset{} = changeset, _changes} ->
        if courtesy_conflict?(changeset),
          do: {:error, :courtesy_in_use},
          else: {:error, :invalid_tokens}
    end
  end

  # Race-safe debit: the plain path is one conditional decrement; the
  # courtesy path (rule 4) compare-and-swaps whatever balance remains to
  # zero and mints the shortfall. Returns {:ok, credited_tokens}.
  defp debit(repo, account_id, tokens) do
    {count, _} =
      from(a in Account, where: a.id == ^account_id and a.foresight_tokens >= ^tokens)
      |> repo.update_all(inc: [foresight_tokens: -tokens])

    case count do
      1 -> {:ok, 0}
      0 -> courtesy_debit(repo, account_id, tokens)
    end
  end

  defp courtesy_debit(repo, account_id, tokens) do
    if tokens > Settlement.courtesy_limit() do
      {:error, :insufficient_tokens}
    else
      balance =
        from(a in Account, where: a.id == ^account_id, select: a.foresight_tokens)
        |> repo.one()

      case balance do
        nil ->
          {:error, :not_found}

        balance when balance >= tokens ->
          # Raced with a concurrent credit — retry the plain path once.
          {count, _} =
            from(a in Account, where: a.id == ^account_id and a.foresight_tokens >= ^tokens)
            |> repo.update_all(inc: [foresight_tokens: -tokens])

          if count == 1, do: {:ok, 0}, else: {:error, :insufficient_tokens}

        balance ->
          debited = max(balance, 0)

          {count, _} =
            from(a in Account, where: a.id == ^account_id and a.foresight_tokens == ^balance)
            |> repo.update_all(set: [foresight_tokens: balance - debited])

          if count == 1, do: {:ok, tokens - debited}, else: {:error, :insufficient_tokens}
      end
    end
  end

  defp courtesy_conflict?(changeset) do
    Enum.any?(changeset.errors, fn
      {:account_id, {_msg, opts}} -> opts[:constraint] == :unique
      _other -> false
    end)
  end

  ## Join-time refund hook (rule 5)

  @doc """
  Called when `account_id` registers into `instance_id`: their active
  predictions on that match are voided and the debited tokens returned,
  so nobody games the own-faction rule by predicting first. Decided
  matches are left alone — settlement owns them. Never raises.
  """
  def return_on_join(account_id, instance_id) do
    unless decided_or_settled?(instance_id) do
      from(p in Prediction,
        where: p.account_id == ^account_id and p.instance_id == ^instance_id and p.status == "active"
      )
      |> Repo.all()
      |> Enum.each(&void_prediction/1)
    end

    :ok
  rescue
    error ->
      Logger.error("[foresight] return_on_join(#{account_id}, #{instance_id}) failed: #{Exception.message(error)}")
      :ok
  end

  defp void_prediction(prediction) do
    refund = prediction.tokens - prediction.credited_tokens
    now = DateTime.utc_now()

    Multi.new()
    |> Multi.run(:mark, fn repo, _changes ->
      {count, _} =
        from(p in Prediction, where: p.id == ^prediction.id and p.status == "active")
        |> repo.update_all(
          set: [status: "void", tokens_recovered: refund, points_awarded: 0, settled_at: now, updated_at: now]
        )

      if count == 1, do: {:ok, :marked}, else: {:error, :already_settled}
    end)
    |> Multi.update_all(
      :credit,
      fn _changes -> from(a in Account, where: a.id == ^prediction.account_id) end,
      inc: [foresight_tokens: refund]
    )
    |> Repo.transaction()
  end

  ## Portal queries

  @doc """
  Per-faction active token totals, the caller's own predictions, and the
  window state for one match.
  """
  def instance_summary(instance_id, account_id) do
    totals =
      from(p in Prediction,
        where: p.instance_id == ^instance_id and p.status == "active",
        group_by: [p.faction_id, p.faction_ref],
        select: %{faction_id: p.faction_id, faction_ref: p.faction_ref, tokens: sum(p.tokens)}
      )
      |> Repo.all()

    mine =
      from(p in Prediction,
        where: p.instance_id == ^instance_id and p.account_id == ^account_id,
        order_by: [asc: p.inserted_at]
      )
      |> Repo.all()

    state =
      from(i in Instance, where: i.id == ^instance_id, select: i.state)
      |> Repo.one()

    open = state in @started_states and not decided_or_settled?(instance_id)

    %{totals: totals, mine: mine, open: open}
  end

  @doc """
  Balances plus the caller's active and recently settled predictions —
  the durable "what happened while you were away" read.
  """
  def account_overview(account_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 25)

    {tokens, points} =
      from(a in Account, where: a.id == ^account_id, select: {a.foresight_tokens, a.foresight_points})
      |> Repo.one() || {0, 0}

    active =
      from(p in Prediction,
        where: p.account_id == ^account_id and p.status == "active",
        order_by: [desc: p.inserted_at]
      )
      |> Repo.all()

    settled =
      from(p in Prediction,
        where: p.account_id == ^account_id and p.status != "active",
        order_by: [desc: p.settled_at],
        limit: ^limit
      )
      |> Repo.all()

    %{tokens: tokens, points: points, active: active, settled: settled}
  end

  ## Settlement

  @doc """
  Settles all active predictions on `instance_id`. `ranking` is the
  Victory agent's export (winner first, entries with `:id` = factions row
  id and `:key`) on the fast path; the sweeper passes nil and the winner
  is derived from `factions.final_rank == 1`.

  Returns `{:ok, plan}`, `:already_settled`, `:noop` (no predictions), or
  `{:error, term}`. Idempotent and safe to race — the latch decides.
  """
  def settle(instance_id, ranking \\ nil) do
    cond do
      settled?(instance_id) ->
        :already_settled

      not has_active_predictions?(instance_id) ->
        :noop

      true ->
        predictions = active_predictions(instance_id)
        plan = Settlement.plan(prediction_maps(predictions), settlement_ctx(instance_id, predictions, ranking))
        apply_plan(instance_id, plan)
    end
  end

  @doc """
  Never-raise wrapper for the Victory-agent hook — a settlement bug must
  not crash the Victory tick server; the sweeper is the safety net.
  """
  def settle_safely(instance_id, ranking) do
    settle(instance_id, ranking)
  rescue
    error ->
      Logger.error("[foresight] settle(#{instance_id}) failed: #{Exception.message(error)}")
      :error
  end

  @doc """
  Voids every active prediction on `instance_id` under the given outcome
  (`"void_no_winner"` for winner-less endings, `"void_instance_deleted"`
  when the instance row is gone). Same latch as `settle/2`.
  """
  def void(instance_id, outcome) when outcome in ["void_no_winner", "void_instance_deleted"] do
    cond do
      settled?(instance_id) ->
        :already_settled

      not has_active_predictions?(instance_id) ->
        :noop

      true ->
        predictions = active_predictions(instance_id)

        plan =
          prediction_maps(predictions)
          |> Settlement.plan(%{
            winning_faction_id: nil,
            winning_faction_ref: nil,
            started_at: nil,
            decided_at: nil,
            human_players: 0,
            registered_factions: %{}
          })
          |> Map.put(:outcome, outcome)

        apply_plan(instance_id, plan)
    end
  end

  @doc "True once a victories row or a settlement exists for the instance."
  def decided_or_settled?(instance_id) do
    Repo.exists?(from(v in Victory, where: v.instance_id == ^instance_id)) or settled?(instance_id)
  end

  def settled?(instance_id) do
    Repo.exists?(from(s in SettlementRecord, where: s.instance_id == ^instance_id))
  end

  defp has_active_predictions?(instance_id) do
    Repo.exists?(from(p in Prediction, where: p.instance_id == ^instance_id and p.status == "active"))
  end

  defp active_predictions(instance_id) do
    from(p in Prediction, where: p.instance_id == ^instance_id and p.status == "active")
    |> Repo.all()
  end

  defp prediction_maps(predictions) do
    Enum.map(predictions, &Map.take(&1, [:id, :account_id, :faction_id, :tokens, :credited_tokens, :inserted_at]))
  end

  defp settlement_ctx(instance_id, predictions, ranking) do
    {winning_faction_id, winning_faction_ref} = winner(instance_id, ranking)

    started_at =
      from(s in InstanceState,
        where: s.instance_id == ^instance_id and s.state == "running",
        select: min(s.inserted_at)
      )
      |> Repo.one()

    decided_at =
      from(v in Victory, where: v.instance_id == ^instance_id, select: v.inserted_at)
      |> Repo.one()

    account_ids = predictions |> Enum.map(& &1.account_id) |> Enum.uniq()

    registered_factions =
      from(r in Registration,
        join: p in Profile,
        on: p.id == r.profile_id,
        join: f in Faction,
        on: f.id == r.faction_id,
        where: f.instance_id == ^instance_id and p.account_id in ^account_ids,
        select: {p.account_id, r.faction_id}
      )
      |> Repo.all()
      |> Map.new()

    %{
      winning_faction_id: winning_faction_id,
      winning_faction_ref: winning_faction_ref,
      started_at: started_at,
      decided_at: decided_at,
      human_players: human_players(instance_id),
      registered_factions: registered_factions
    }
  end

  defp winner(_instance_id, [first | _rest]), do: {first.id, to_string(first.key)}

  defp winner(instance_id, _ranking) do
    from(f in Faction,
      where: f.instance_id == ^instance_id and f.final_rank == 1,
      select: {f.id, f.faction_ref}
    )
    |> Repo.one() || {nil, nil}
  end

  defp human_players(instance_id) do
    from(r in Registration,
      join: p in Profile,
      on: p.id == r.profile_id,
      join: f in Faction,
      on: f.id == r.faction_id,
      where: f.instance_id == ^instance_id and p.is_bot == false,
      select: count(r.id)
    )
    |> Repo.one()
  end

  defp registered_faction_id(account_id, instance_id) do
    from(r in Registration,
      join: p in Profile,
      on: p.id == r.profile_id,
      join: f in Faction,
      on: f.id == r.faction_id,
      where: p.account_id == ^account_id and f.instance_id == ^instance_id,
      select: r.faction_id,
      limit: 1
    )
    |> Repo.one()
  end

  # Applies a settlement plan in one transaction: latch first (the unique
  # index arbitrates racing settlers), then per-prediction outcomes, then
  # per-account balance/point credits.
  defp apply_plan(instance_id, plan) do
    now = DateTime.utc_now()

    latch =
      SettlementRecord.changeset(%SettlementRecord{}, %{
        instance_id: instance_id,
        outcome: plan.outcome,
        winning_faction_ref: plan.winning_faction_ref,
        pool_tokens: plan.pool_tokens,
        tokens_recovered: plan.tokens_recovered,
        points_minted: plan.points_minted
      })

    multi = Multi.insert(Multi.new(), :latch, latch)

    multi =
      Enum.reduce(plan.entries, multi, fn entry, acc ->
        Multi.update_all(
          acc,
          "prediction_#{entry.id}",
          fn _changes -> from(p in Prediction, where: p.id == ^entry.id and p.status == "active") end,
          set: [
            status: entry.status,
            tokens_recovered: entry.tokens_recovered,
            bonus_tokens: entry.bonus_tokens,
            points_awarded: entry.points_awarded,
            settled_at: now,
            updated_at: now
          ]
        )
      end)

    credits =
      plan.entries
      |> Enum.group_by(& &1.account_id)
      |> Enum.map(fn {account_id, entries} ->
        {account_id, Enum.sum(for e <- entries, do: e.tokens_recovered + e.bonus_tokens),
         Enum.sum(for e <- entries, do: e.points_awarded)}
      end)
      |> Enum.reject(fn {_account_id, tokens, points} -> tokens == 0 and points == 0 end)

    multi =
      Enum.reduce(credits, multi, fn {account_id, tokens, points}, acc ->
        Multi.update_all(
          acc,
          "credit_#{account_id}",
          fn _changes -> from(a in Account, where: a.id == ^account_id) end,
          inc: [foresight_tokens: tokens, foresight_points: points]
        )
      end)

    case Repo.transaction(multi) do
      {:ok, _changes} ->
        notify_settled(instance_id, plan)
        {:ok, plan}

      {:error, :latch, _changeset, _changes} ->
        :already_settled

      {:error, step, reason, _changes} ->
        {:error, {step, reason}}
    end
  end

  # Best-effort push so connected players see their settlement instantly;
  # the prediction rows are the durable record for everyone else.
  defp notify_settled(instance_id, plan) do
    plan.entries
    |> Enum.map(& &1.account_id)
    |> Enum.uniq()
    |> Enum.each(fn account_id ->
      Portal.Controllers.PortalChannel.broadcast_change("portal:user:#{account_id}", %{
        foresight: %{instance_id: instance_id, outcome: plan.outcome}
      })
    end)
  rescue
    error -> Logger.warning("[foresight] settlement notify failed: #{Exception.message(error)}")
  end
end
