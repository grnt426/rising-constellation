defmodule Daily.Rotation do
  # Minimum number of days before an objective may play again (a gap of 7
  # means Monday's goal can come back next Monday at the earliest).
  @cooldown_days 7

  @moduledoc """
  Decides which objective each daily date plays.

  The original rotation rolled every date independently off the date digest,
  so nothing stopped a goal coming back the next day (and the day after —
  Tide of Invention ran three of four days in September 2026). Players hated
  it. Since the first epoch below, the rotation is a **shuffled deck with a
  cooldown**:

    * Each epoch's objectives are dealt as a deck: a deterministic shuffle
      seeded from the epoch and the deck number. A deck of N objectives covers
      exactly N consecutive days, so every objective plays exactly once per
      deck — no goal is starved, none dominates.
    * Deck boundaries are where a plain shuffle could still repeat (the last
      card of one deck equals the first card of the next). So each day takes
      the first card in the deck that hasn't played in the previous
      #{@cooldown_days - 1} days, deferring cooling cards to later in the same
      deck. An objective therefore waits at least #{@cooldown_days} days
      between plays.

  Everything is a pure function of the date — the walk replays from the first
  epoch every call (a few thousand cheap steps even years out) — so every
  player, the API, the Discord blast and `mix daily.preview` agree without
  shared state.

  ## Stability rules

  Past dates must never change: the Discord winners blast and the leaderboard
  re-derive an ended day's objective from its date.

    * Dates before the first epoch keep the legacy independent roll, against
      the catalog frozen in `@legacy_objectives`.
    * **Adding an objective:** append a new epoch dated at a future rotation
      (after the deploy) with the new key list; never edit an existing
      epoch's list. The new epoch starts a fresh deck and still honours the
      cooldown against the days before it. `test/daily/objective_rotation_test.exs`
      fails while the catalog and the latest epoch disagree.
    * An epoch's `from` must be later than the deploy that introduces it,
      or the in-progress day's objective changes under players mid-day.
  """

  # The catalog as it stood when the legacy roll was retired, in its display
  # order at the time. The legacy roll indexes into this list, so it must
  # never change — even if objectives are later added, reordered or removed.
  @legacy_objectives ~w(
    coffers_of_the_realm archives_of_ages weight_of_faith golden_flow
    tide_of_invention rising_creed forge_unceasing the_triumvirate
    charter_of_prosperity destroyers_blueprint fleet_in_being_raiders
    fleet_in_being_vanguard monumental fleet_in_being_armada land_rush
    hegemon siege_breaker headhunter the_bequest
  )a

  # Append-only. Each epoch deals decks of its `objectives` from `from`
  # (inclusive) until the next epoch begins.
  @epochs [
    %{from: ~D[2026-09-28], objectives: @legacy_objectives}
  ]

  @doc "Minimum days between two plays of the same objective."
  def cooldown_days, do: @cooldown_days

  @doc "The epoch list (oldest first). Exposed for tests."
  def epochs, do: @epochs

  @doc "The legacy catalog the pre-epoch roll indexes into. Exposed for tests."
  def legacy_objectives, do: @legacy_objectives

  @doc """
  The objective key (atom) for `date` (a `Date` or ISO-8601 string).
  """
  def objective_for(%Date{} = date) do
    %{from: first} = hd(@epochs)

    if Date.compare(date, first) == :lt do
      legacy_pick(date)
    else
      walk(first, date)
    end
  end

  def objective_for(date_iso) when is_binary(date_iso), do: objective_for(Date.from_iso8601!(date_iso))

  # The pre-epoch roll: one digest byte indexes the frozen legacy catalog.
  # Byte 7 is what Daily.Generator has always used for the objective.
  defp legacy_pick(date) do
    bytes = Daily.Generator.digest_bytes(Date.to_iso8601(date))
    Enum.at(@legacy_objectives, rem(Enum.at(bytes, 7), length(@legacy_objectives)))
  end

  # Replay the rotation day by day from the first epoch up to `target`.
  # `history` is the recent plays, newest first, capped to the cooldown
  # window; it starts with the legacy days right before the first epoch so
  # the switch-over can't repeat either.
  defp walk(first, target) do
    history =
      for offset <- 1..(@cooldown_days - 1), do: legacy_pick(Date.add(first, -offset))

    state = %{history: history, deck: [], deck_no: 0, epoch: nil}

    Enum.reduce(Date.range(first, target), {nil, state}, fn date, {_, state} ->
      step(date, state)
    end)
    |> elem(0)
  end

  defp step(date, state) do
    epoch = epoch_for(date)

    # Entering a new epoch drops whatever was left of the old deck.
    state = if epoch != state.epoch, do: %{state | epoch: epoch, deck: [], deck_no: 0}, else: state

    state =
      if state.deck == [],
        do: %{state | deck: shuffle(epoch, state.deck_no), deck_no: state.deck_no + 1},
        else: state

    pick = draw(state.deck, state.history)

    history = Enum.take([pick | state.history], @cooldown_days - 1)
    {pick, %{state | deck: List.delete(state.deck, pick), history: history}}
  end

  # First card that's off cooldown. The fallback (every remaining card is
  # cooling) can't happen while an epoch has at least @cooldown_days
  # objectives; if it ever does, play the one that's been waiting longest.
  defp draw(deck, history) do
    Enum.find(deck, &(&1 not in history)) ||
      Enum.max_by(deck, fn key -> Enum.find_index(history, &(&1 == key)) end)
  end

  defp epoch_for(date) do
    @epochs
    |> Enum.filter(&(Date.compare(&1.from, date) != :gt))
    |> List.last()
  end

  # Deterministic shuffle: order the keys by a hash of (epoch, deck, key).
  # Independent of the list's own order, so reordering an epoch's list (which
  # you shouldn't do anyway) wouldn't reshuffle it.
  defp shuffle(%{from: from, objectives: objectives}, deck_no) do
    prefix = "tetrarchy-daily-deck:v1:#{Date.to_iso8601(from)}:#{deck_no}:"
    Enum.sort_by(objectives, &:crypto.hash(:sha256, prefix <> Atom.to_string(&1)))
  end
end
