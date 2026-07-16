defmodule Data.DataPersistentTermTest do
  @moduledoc """
  Behavior-preservation proof for the switchable content-memory model.

  `Data.Data` serves the game content map either by copying it from the
  per-instance registry meta (`:legacy`) or zero-copy from `:persistent_term`
  (`:shared`). Both modes must return byte-identical content to a fresh
  `Data.Querier.fetch_all/1` build — the game reads content exclusively through
  this path, so identical content => identical simulation by construction.

  (The simulation itself can't be diffed naively across runs because galaxy
  generation consumes a shared seeded RNG from `Task.async_stream` — i.e. it is
  non-deterministic across runs even on a fixed seed. The deterministic
  simulation-level differential uses a faked RNG and runs a real battle under
  both modes; see Game.Fight.BattleDeterminismTest.)
  """
  use ExUnit.Case, async: false

  @modes [:legacy, :shared]

  test "get(:data) is byte-identical to a fresh fetch_all, in BOTH modes, for every speed/mode" do
    for mode <- @modes, metadata <- Data.Querier.metadatas() do
      iid = System.unique_integer([:positive])
      Data.Data.insert(iid, metadata, mode)

      assert Data.Data.get(iid, :data) == Data.Querier.fetch_all(metadata),
             "content map mismatch (#{mode}) for #{inspect(metadata)}"

      for mod <- [Data.Game.Ship, Data.Game.Building, Data.Game.Patent, Data.Game.Doctrine, Data.Game.Constant] do
        assert Data.Querier.all(mod, iid) == Data.Querier.fetch_all(mod, metadata),
               "#{inspect(mod)} mismatch (#{mode}) for #{inspect(metadata)}"
      end

      Data.Data.clear(iid)
    end
  end

  test "switch_memory_mode/2 preserves the served content (legacy <-> shared, live)" do
    metadata = [speed: :fast, mode: :prod]
    canonical = Data.Querier.fetch_all(metadata)

    iid = System.unique_integer([:positive])
    Data.Data.insert(iid, metadata, :legacy)
    assert Data.Data.get(iid, :data) == canonical

    :ok = Data.Data.switch_memory_mode(iid, :shared)
    assert Data.Data.get(iid, :metadata) == metadata
    assert Data.Data.get(iid, :data) == canonical

    :ok = Data.Data.switch_memory_mode(iid, :legacy)
    assert Data.Data.get(iid, :data) == canonical

    Data.Data.clear(iid)
  end

  test "export keeps its [metadata:, data:] shape in both modes" do
    metadata = [speed: :medium, mode: :prod]

    for mode <- @modes do
      iid = System.unique_integer([:positive])
      Data.Data.insert(iid, metadata, mode)

      exported = Data.Data.export(iid)
      assert Keyword.fetch!(exported, :metadata) == metadata
      assert Keyword.fetch!(exported, :data) == Data.Querier.fetch_all(metadata)

      Data.Data.clear(iid)
    end
  end

  test "global default mode is honoured by insert/2 and is :legacy unless flipped" do
    assert Data.Data.memory_mode() == :legacy

    iid = System.unique_integer([:positive])
    Data.Data.set_memory_mode(:shared)

    try do
      assert Data.Data.memory_mode() == :shared
      Data.Data.insert(iid, speed: :fast, mode: :prod)
      # :shared meta omits the :data copy; get(:data) still returns content.
      assert Data.Data.get(iid, :data) == Data.Querier.fetch_all(speed: :fast, mode: :prod)
    after
      Data.Data.set_memory_mode(:legacy)
      Data.Data.clear(iid)
    end
  end

  test "shared mode self-heals when local content is missing (Horde failover safety)" do
    # :persistent_term is node-local; on a Horde handoff the new node inherits
    # the replicated meta (mode: :shared, metadata) but NOT the content, and
    # Data.Data.insert does not run on the failover path. Simulate that node by
    # erasing the local content after insert: get(:data) must rebuild from the
    # metadata, not raise.
    metadata = [speed: :slow, mode: :dev]
    iid = System.unique_integer([:positive])
    Data.Data.insert(iid, metadata, :shared)

    :persistent_term.erase({Data.Data, :content, :slow, :dev})

    assert Data.Data.get(iid, :data) == Data.Querier.fetch_all(metadata)
    # subsequent reads hit the rebuilt cache
    assert Data.Data.get(iid, :data) == Data.Querier.fetch_all(metadata)

    Data.Data.clear(iid)
  end
end
