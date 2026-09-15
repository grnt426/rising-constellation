defmodule Instance.Player.SystemUpdateBatchTest do
  use ExUnit.Case, async: true

  alias Instance.Player.SystemUpdateBatch, as: Batch
  alias Test.FleetScenario

  test "a later update of the same system replaces the earlier one" do
    pending =
      %{}
      |> Batch.add(:system, %{id: 1, rev: 1})
      |> Batch.add(:system, %{id: 2, rev: 1})
      |> Batch.add(:system, %{id: 1, rev: 2})

    assert map_size(pending) == 2
    assert pending[{:system, 1}].rev == 2
  end

  test "a system and a dominion with the same id stay separate" do
    pending =
      %{}
      |> Batch.add(:system, %{id: 7, rev: 1})
      |> Batch.add(:dominion, %{id: 7, rev: 2})

    {systems, dominions} = Batch.split(pending)
    assert Enum.map(systems, & &1.rev) == [1]
    assert Enum.map(dominions, & &1.rev) == [2]
  end

  test "only the wave bot faction batches, with the configured window" do
    wave = System.unique_integer([:positive])
    plain = System.unique_integer([:positive])

    FleetScenario.load_game_data(wave,
      speed: :slow,
      mode: :prod,
      wave: true,
      wave_config: %{"bot_faction" => "rebellion", "system_update_batch_ms" => 250}
    )

    FleetScenario.load_game_data(plain, speed: :slow, mode: :prod)

    assert Batch.batching?(wave, :rebellion)
    refute Batch.batching?(wave, :tetrarchy)
    refute Batch.batching?(plain, :rebellion)

    assert Batch.window_ms(wave) == 250
    assert Batch.window_ms(plain) == 500
  end
end
