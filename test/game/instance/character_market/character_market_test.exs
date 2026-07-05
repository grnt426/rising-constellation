defmodule Instance.CharacterMarket.CharacterMarketTest do
  # The instance metadata cache is a shared (Horde-registry-backed) resource
  # keyed by instance id — keep these sequential.
  use ExUnit.Case, async: false

  alias Instance.CharacterMarket.CharacterMarket

  # Regression: the boot-race crash observed under many concurrent headless
  # games. The market fills its slots at instance CREATION by generating
  # characters, whose name/stat rolls call the per-instance rand agent via
  # Game.call. When that agent isn't registered yet (registry lag under
  # simultaneous instance boots) or is mid-restart, Game.call returns
  # :process_not_found / {:error, :callee_crashed} — which used to flow into
  # Enum/`.key`/arithmetic and crash the market. The supervisor restart then
  # re-ran new/1 → same crash: a poison-pill loop that zeroed the market for
  # the whole game.
  #
  # This test builds a market for an instance whose data cache exists but
  # whose AGENTS don't — exactly the race window. It must not raise, and the
  # fallbacks must still produce a fully-stocked market.
  test "market creation survives an unreachable rand agent (boot race)" do
    instance_id = 900_000_000 + System.unique_integer([:positive])

    # Metadata/content cache present (what init_from_model writes before
    # spawning agents) — but NO rand agent, market agent, or anything else.
    Data.Data.insert(instance_id, speed: :fast, mode: :prod)

    try do
      market = CharacterMarket.new(instance_id)

      characters =
        market.slots
        |> Enum.flat_map(& &1.data)
        |> Enum.flat_map(& &1.data)
        |> Enum.map(& &1.character)

      assert characters != []
      assert Enum.all?(characters, &match?(%Instance.Character.Character{}, &1))
      assert market.character_counter == length(characters) + 1

      # Names came from the Picker fallback — still real strings.
      assert Enum.all?(characters, fn c -> is_binary(c.name) and c.name != "" end)
    after
      Data.Data.clear(instance_id)
    end
  end

  # Defense-in-depth: even when character generation fails for a reason the
  # inner fallbacks don't cover, the market must skip the slot (leaving it
  # empty on a short retry cooldown) rather than crash. A bogus character
  # type key forces generation to raise.
  test "fill_empty_slots skips slots whose character generation fails" do
    instance_id = 900_000_000 + System.unique_integer([:positive])
    Data.Data.insert(instance_id, speed: :fast, mode: :prod)

    try do
      market = %CharacterMarket{
        character_counter: 1,
        instance_id: instance_id,
        slots: [
          %{
            key: :no_such_character_type,
            data: [%{key: :common, data: [%{nth: 0, cooldown: Core.CooldownValue.new(0), character: nil}]}]
          }
        ]
      }

      filled = CharacterMarket.fill_empty_slots(market)

      [slot] = filled.slots |> Enum.flat_map(& &1.data) |> Enum.flat_map(& &1.data)
      assert slot.character == nil
      # Counter untouched — no id was consumed by the failed slot.
      assert filled.character_counter == 1
    after
      Data.Data.clear(instance_id)
    end
  end
end
