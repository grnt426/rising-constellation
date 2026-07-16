defmodule Game.Instance.GenerationDeterminismTest do
  @moduledoc """
  Proves `:rc, :deterministic_generation` makes galaxy generation reproducible.

  Galaxy generation draws from a single shared seeded `:rand` agent, but
  `Instance.Manager` builds systems via `Task.async_stream` — so the concurrent
  draw order makes the generated galaxy non-deterministic across runs even on a
  fixed seed. With the flag on (max_concurrency: 1), two instances created from
  the same scenario (same seed) must produce a byte-identical galaxy — including
  which systems roll `:inhabited_neutral`. That reproducibility is what lets us
  run a baseline-vs-modified differential on an identical generated galaxy.

  Tagged `:gen_determinism` (excluded from the default suite — it creates two
  full instances). Run explicitly:

      MIX_ENV=test mix test --only gen_determinism test/game/instance/generation_determinism_test.exs
  """
  use RC.DataCase, async: false

  alias Instance.Manager

  @moduletag :gen_determinism
  @moduletag timeout: 300_000

  setup do
    prev_gen = Application.get_env(:rc, :deterministic_generation, false)
    prev_mode = Application.get_env(:rc, :data_memory_mode, :legacy)
    Application.put_env(:rc, :deterministic_generation, true)

    on_exit(fn ->
      Application.put_env(:rc, :deterministic_generation, prev_gen)
      Application.put_env(:rc, :data_memory_mode, prev_mode)
    end)

    :ok
  end

  test "same seed reproduces an identical galaxy across two same-mode creations" do
    {fp1, neutral1, total1} = create_and_fingerprint(:legacy)
    {fp2, _n2, _t2} = create_and_fingerprint(:legacy)

    assert total1 > 0, "no systems generated"
    assert neutral1 > 0, "expected some inhabited_neutral systems to compare"
    assert fp1 == fp2

    IO.puts("\n[gen determinism] #{total1} systems, #{neutral1} neutral — identical across two creations ✓")
  end

  test "baseline (:legacy) vs modified (:shared) generate a byte-identical galaxy on the same seed" do
    {fp_legacy, neutral, total} = create_and_fingerprint(:legacy)
    {fp_shared, neutral_s, _total_s} = create_and_fingerprint(:shared)

    assert total > 0 and neutral > 0
    assert neutral == neutral_s
    # The point: switching the content-memory model does not perturb generation
    # — the same systems are neutral/uninhabited/etc., at the same positions.
    assert fp_legacy == fp_shared

    IO.puts("\n[gen :legacy vs :shared] #{total} systems, #{neutral} neutral — identical galaxy ✓")
  end

  defp create_and_fingerprint(mode) do
    Data.Data.set_memory_mode(mode)
    %{instance: instance} = RC.ScenarioFixtures.valid_instance_fixture()
    instance = RC.Instances.get_instance_with_registration(instance.id)
    iid = instance.id

    {:ok, :instantiated} = Manager.create_from_model(instance, nil)

    galaxy =
      case Game.call(iid, :galaxy, :master, :get_state) do
        {:ok, g} -> g
        g -> g
      end

    systems = galaxy.stellar_systems

    fp =
      systems
      |> Enum.sort_by(& &1.id)
      |> Enum.map(fn s -> {s.id, s.type, s.status, s.sector_id, s.position.x, s.position.y} end)

    neutral = Enum.count(systems, fn s -> s.status == :inhabited_neutral end)

    # Tear down before returning so the next creation starts clean.
    try do
      Manager.destroy(iid)
    rescue
      _ -> :ok
    catch
      _, _ -> :ok
    end

    {fp, neutral, length(systems)}
  end
end
