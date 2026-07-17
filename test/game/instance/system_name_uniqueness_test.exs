defmodule Game.Instance.SystemNameUniquenessTest do
  @moduledoc """
  System names must be galaxy-unique. Names are dealt from a single seeded
  shuffle of priv/data/name/place.txt (Data.Picker.unique/3) made *before*
  the concurrent generation fan-out, so for a given scenario seed they are
  also deterministic — even without `:rc, :deterministic_generation`.

  Tagged `:gen_determinism` (excluded from the default suite — it creates two
  full instances). Run explicitly:

      MIX_ENV=test mix test --only gen_determinism test/game/instance/system_name_uniqueness_test.exs
  """
  use RC.DataCase, async: false

  alias Instance.Manager

  @moduletag :gen_determinism
  @moduletag timeout: 300_000

  test "system names are unique and seed-deterministic under concurrent generation" do
    names1 = create_and_collect_names()
    names2 = create_and_collect_names()

    assert length(names1) > 0, "no systems generated"
    assert length(Enum.uniq(names1)) == length(names1), "duplicate system names generated"
    assert names1 == names2, "same seed produced different system names"

    IO.puts("\n[system names] #{length(names1)} systems, all unique, identical across two creations ✓")
  end

  defp create_and_collect_names do
    %{instance: instance} = RC.ScenarioFixtures.valid_instance_fixture()
    instance = RC.Instances.get_instance_with_registration(instance.id)
    iid = instance.id

    {:ok, :instantiated} = Manager.create_from_model(instance, nil)

    galaxy =
      case Game.call(iid, :galaxy, :master, :get_state) do
        {:ok, g} -> g
        g -> g
      end

    names =
      galaxy.stellar_systems
      |> Enum.sort_by(& &1.id)
      |> Enum.map(& &1.name)

    # Tear down before returning so the next creation starts clean.
    try do
      Manager.destroy(iid)
    rescue
      _ -> :ok
    catch
      _, _ -> :ok
    end

    names
  end
end
