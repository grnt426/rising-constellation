defmodule Game.Instance.SystemNameUniquenessTest do
  @moduledoc """
  System names must be galaxy-unique. Names are dealt from a single seeded
  shuffle of priv/data/name/place.txt (Data.Picker) made *before* the
  concurrent generation fan-out, so for a given scenario seed they are also
  deterministic — even without `:rc, :deterministic_generation`. Sectors the
  scenario assigns to a faction pull ~80% of their names from that faction's
  culture list (priv/data/name/place/<culture>.txt); the fixture's two
  sectors are assigned to myrmezir and tetrarchy.

  Tagged `:gen_determinism` (excluded from the default suite — it creates two
  full instances). Run explicitly:

      MIX_ENV=test mix test --only gen_determinism test/game/instance/system_name_uniqueness_test.exs
  """
  use RC.DataCase, async: false

  alias Instance.Manager

  @moduletag :gen_determinism
  @moduletag timeout: 300_000

  # Fixture scenario: sector key 0 -> myrmezir, sector key 1 -> tetrarchy.
  @sector_culture %{0 => "myrmeziriannic", 1 => "tetrarchic"}

  test "system names are unique, seed-deterministic, and faction-sector flavored" do
    systems1 = create_and_collect()
    systems2 = create_and_collect()

    names1 = Enum.map(systems1, &elem(&1, 1))

    assert length(names1) > 0, "no systems generated"
    assert length(Enum.uniq(names1)) == length(names1), "duplicate system names generated"
    assert systems1 == systems2, "same seed produced different system names"

    for {sector_id, culture} <- @sector_culture do
      culture_names = MapSet.new(Data.Picker.all("place-#{culture}"))
      sector_names = for {sid, name} <- systems1, sid == sector_id, do: name
      flavored = Enum.count(sector_names, &MapSet.member?(culture_names, &1))
      share = flavored / length(sector_names)

      # Exactly round(0.8k) are dealt from the culture pool; the generic
      # remainder can coincidentally be culture names via the global pool
      # (they are a ~5% slice of it), hence the loose upper bound.
      assert share >= 0.75 and share <= 0.95,
             "sector #{sector_id} #{culture} flavor share #{Float.round(share, 2)} outside 0.75..0.95"

      IO.puts("[flavor] sector #{sector_id} (#{culture}): #{flavored}/#{length(sector_names)}")
    end

    IO.puts("[system names] #{length(names1)} systems, all unique, identical across two creations ✓")
  end

  defp create_and_collect do
    %{instance: instance} = RC.ScenarioFixtures.valid_instance_fixture()
    instance = RC.Instances.get_instance_with_registration(instance.id)
    iid = instance.id

    {:ok, :instantiated} = Manager.create_from_model(instance, nil)

    galaxy =
      case Game.call(iid, :galaxy, :master, :get_state) do
        {:ok, g} -> g
        g -> g
      end

    systems =
      galaxy.stellar_systems
      |> Enum.sort_by(& &1.id)
      |> Enum.map(fn s -> {s.sector_id, s.name} end)

    # Tear down before returning so the next creation starts clean.
    try do
      Manager.destroy(iid)
    rescue
      _ -> :ok
    catch
      _, _ -> :ok
    end

    systems
  end
end
