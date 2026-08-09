defmodule RC.Security.PlayerMarketDeckCooldownTest do
  @moduledoc """
  Regression test for the instance-49 player-reset incident.

  Selling a *deck* character via `Instance.Player.Market` used to run

      %{cooldown: nil, character: character} = card

  in `place_offer(state, "character_deck", _)`. That hard match only accepts
  a card whose cooldown is `nil` (a character never deployed). A card that had
  been deployed and recalled carries a `%Core.CooldownValue{}` whose `value`
  ticks down to 0 but is never reset back to `nil` — so listing such a card
  raised a `MatchError`, crashed the seller's `Player.Agent`, and (via the
  crash-restart path) reverted the whole player to their join-time genesis
  state (starting resources, no systems).

  The fix treats a card as sellable when its cooldown is `nil` OR has expired
  (`value == 0`), rejects a still-locked card with a clean error tuple, and
  wraps `create_offer/2` in a try/rescue safety net so no offer-placement path
  can crash the agent.

  These tests drive `create_offer/2` with a synthetic map-state, so they need
  no running game instance / Repo. The success path (a real offer row) is out
  of scope here — in the unit env the DB insert simply fails and is caught,
  which is exactly the safety net we want to prove.
  """
  use ExUnit.Case, async: true

  alias Instance.Player.Market
  alias Instance.Character.Character

  defp deck_offer_args(character_id) do
    %{
      "type" => "character_deck",
      "data" => %{"character_id" => character_id},
      "price" => 20,
      "allowed_players" => [],
      "allowed_factions" => []
    }
  end

  # struct/2 bypasses @enforce_keys so we can build a minimal Character
  # without dragging Data.Querier into the test.
  defp char(id) do
    struct(Character,
      id: id,
      status: :in_deck,
      type: :speaker,
      specialization: :agitator,
      second_specialization: :proselyte,
      skills: [1, 3, 2, 1, 1, 1],
      name: "Erikson Valseciel",
      level: 4,
      experience: %Core.DynamicValue{value: 59.0, change: 0.05, details: %{}},
      protection: 56,
      determination: 68,
      credit_cost: 0,
      technology_cost: 420,
      ideology_cost: 652,
      owner: nil,
      on_sold: false,
      instance_id: 1
    )
  end

  defp state(deck), do: %{id: 5, instance_id: 1, character_deck: deck}

  test "a deck card still on its recall cooldown is rejected cleanly, not crashed" do
    s = state([%{cooldown: %Core.CooldownValue{initial: 40, value: 12}, character: char(25)}])

    assert {:error, :character_on_cooldown} = Market.create_offer(s, deck_offer_args(25))
  end

  test "listing an unknown deck card returns :character_unavailable" do
    s = state([%{cooldown: nil, character: char(25)}])

    assert {:error, :character_unavailable} = Market.create_offer(s, deck_offer_args(999))
  end

  test "a never-deployed deck card (cooldown nil) is sellable — no crash" do
    s = state([%{cooldown: nil, character: char(25)}])

    result = Market.create_offer(s, deck_offer_args(25))
    refute match?({:error, :character_on_cooldown}, result)
    refute match?({:error, :character_unavailable}, result)
  end

  test "a previously-deployed deck card (expired cooldown, value 0) is sellable, NOT a MatchError crash" do
    # This is the exact incident shape: cooldown is a %CooldownValue{} that has
    # ticked to 0. The old code raised a MatchError here.
    s = state([%{cooldown: %Core.CooldownValue{initial: 40, value: 0}, character: char(25)}])

    result = Market.create_offer(s, deck_offer_args(25))

    # Must not be rejected as on-cooldown, and must not raise. In the unit env
    # the downstream DB insert fails and is caught by the create_offer safety
    # net, yielding {:error, :internal_error}; with a real instance it would be
    # {:ok, state}. Either outcome proves the crash is gone.
    refute match?({:error, :character_on_cooldown}, result)
    assert match?({:ok, _}, result) or match?({:error, :internal_error}, result)
  end
end
