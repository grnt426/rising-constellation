defmodule RC.Security.CharacterMarketAtomicityTest do
  @moduledoc """
  Regression test for the Stage 4 #C2 follow-up — the Agent Market
  ghost-character bug, observed on the live server.

  The original Stage 4 fix made the canonical hire cost server-derived
  (closing a free-hire vulnerability) but reordered the flow so the
  destructive `:sell_character` ran on the market BEFORE the
  affordability check happened on the buyer side. The result:

    * Buyer with insufficient credit tries to hire a character.
    * Market removes the character from its slot, fills the slot
      with a replacement, broadcasts the new state.
    * Buyer's affordability check fails, returns
      `{:error, :not_enough_credit}` to the client.
    * The character the buyer asked for is gone from the market,
      neither buyer nor seller got it. Ghost character.

  The fix is the new `:sell_if_affordable` market handler, which
  performs the affordability check and the slot take atomically
  inside a single CharacterMarket.Agent handle_call body. Because
  the market is a singleton GenServer (only one handler runs at a
  time) and the buyer's Player.Agent is also single-threaded, no
  interleaving is possible between the check and the take.

  This file directly drives the new on_call/3 with a synthesised
  state, so it does not need a running game instance / Data.Querier.
  The test sets `state.tick.running? = false` so the `@decorate
  tick()` decorator becomes a no-op and we can pump state in
  directly.
  """
  use ExUnit.Case, async: true

  alias Instance.CharacterMarket.Agent, as: MarketAgent
  alias Instance.CharacterMarket.CharacterMarket
  alias Instance.Character.Character

  describe ":sell_if_affordable handler atomicity" do
    test "insufficient credit leaves the market state UNCHANGED" do
      char = build_character(id: 42, credit_cost: 1_000, technology_cost: 0, ideology_cost: 0)
      state = build_state(char)

      # Buyer has 500 credit (cost is 1000), abundant tech/ideology.
      result = MarketAgent.on_call({:sell_if_affordable, 42, {500, 9_999, 9_999}}, self(), state)

      assert {:reply, {:error, :not_enough_credit}, returned_state} = result

      assert returned_state == state,
             "Stage 4 #C2 follow-up: market state must NOT mutate on affordability failure (ghost character)"
    end

    test "insufficient technology leaves the market state UNCHANGED" do
      char = build_character(id: 43, credit_cost: 0, technology_cost: 1_000, ideology_cost: 0)
      state = build_state(char)

      result = MarketAgent.on_call({:sell_if_affordable, 43, {9_999, 500, 9_999}}, self(), state)

      assert {:reply, {:error, :not_enough_technology}, returned_state} = result
      assert returned_state == state
    end

    test "insufficient ideology leaves the market state UNCHANGED" do
      char = build_character(id: 44, credit_cost: 0, technology_cost: 0, ideology_cost: 1_000)
      state = build_state(char)

      result = MarketAgent.on_call({:sell_if_affordable, 44, {9_999, 9_999, 500}}, self(), state)

      assert {:reply, {:error, :not_enough_ideology}, returned_state} = result
      assert returned_state == state
    end

    test "non-existent character_id returns :character_unavailable without mutating state" do
      char = build_character(id: 46)
      state = build_state(char)

      result =
        MarketAgent.on_call(
          {:sell_if_affordable, 999_999, {9_999, 9_999, 9_999}},
          self(),
          state
        )

      assert {:reply, {:error, :character_unavailable}, returned_state} = result
      assert returned_state == state
    end

    # NOTE: the success path of `:sell_if_affordable` is exercised
    # only indirectly here — it would otherwise need a live
    # `Data.Querier` cache because `CharacterMarket.fill_empty_slots/1`
    # queries `Data.Game.Constant` to generate a replacement
    # character (lib/game/instance/character_market/character_market.ex:58),
    # and that cache is per-instance and only populated when a
    # real game instance boots. The take-primitive itself
    # (`CharacterMarket.sell_character/2`) is exercised below;
    # together with the four affordability-failure tests above,
    # the ghost-character regression is fully covered: failure paths
    # never mutate state, the take primitive correctly vacates the
    # slot when invoked, and the handler invokes the take primitive
    # only when affordability passes (read directly from the source
    # under `Instance.CharacterMarket.Agent.on_call({:sell_if_affordable, ...})`).
  end

  describe "CharacterMarket.sell_character/2 — the destructive take primitive" do
    test "removes the matching character from the slot and returns it" do
      char = build_character(id: 100, credit_cost: 1, technology_cost: 1, ideology_cost: 1)
      state = build_state(char)

      assert {:ok, new_data, ^char} = CharacterMarket.sell_character(state.data, 100)

      [%{data: [%{data: [slot]}]}] = new_data.slots
      assert slot.character == nil, "the slot must be vacated"
    end

    test "returns :character_unavailable when no slot holds the id" do
      char = build_character(id: 101)
      state = build_state(char)

      assert {:error, :character_unavailable} =
               CharacterMarket.sell_character(state.data, 999_999)
    end
  end

  ## Helpers

  defp build_character(opts) do
    fields =
      Keyword.merge(
        [
          id: 42,
          status: :for_hire,
          type: :admiral,
          specialization: :leader,
          second_specialization: nil,
          skills: [],
          age: 30,
          culture: :culture_a,
          name: "Test Character",
          gender: :female,
          illustration: "",
          level: 1,
          experience: %Core.DynamicValue{value: 0.0, change: 0.0, details: %{}},
          protection: 0,
          determination: 0,
          credit_cost: 100,
          technology_cost: 50,
          ideology_cost: 10,
          owner: nil,
          on_sold: false,
          system: nil,
          position: nil,
          actions: nil,
          action_status: nil,
          on_strike: false,
          army: nil,
          spy: nil,
          speaker: nil,
          bonuses: %{},
          instance_id: 1
        ],
        opts
      )

    # struct/2 bypasses @enforce_keys, letting tests build minimal
    # Character structs without dragging Data.Querier into the test.
    struct(Character, fields)
  end

  defp build_state(character) do
    %{
      type: :character_market,
      agent_id: :master,
      instance_id: 1,
      channel: "instance:global:1",
      # running?: false makes the @decorate tick()` decorator's
      # `next_tick(state)` call a no-op (see Core.TickServer.next_tick/1
      # head: `next_tick(%{tick: %{running?: false}} = state), do: state`).
      tick: %Core.Tick{time: 0, factor: 1, cumulated_pauses: nil, running?: false},
      data: %CharacterMarket{
        character_counter: 100,
        instance_id: 1,
        slots: [
          %{
            key: "test_type",
            data: [
              %{
                key: "test_rank",
                data: [%{nth: 1, cooldown: Core.CooldownValue.new(0), character: character}]
              }
            ]
          }
        ]
      }
    }
  end
end
