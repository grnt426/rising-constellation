defmodule Wave.ReconTest do
  use ExUnit.Case, async: true

  alias Wave.Recon

  describe "seen?" do
    test "a system is seen once any contact was filed on it, or when it is our own" do
      view = %Recon{seen: MapSet.new([299]), stored: %{282 => 5, 300 => 0}}

      # An explorer or informer contact, even when it resolves to nothing now.
      assert Recon.seen?(view, 299)
      # Our own ground.
      assert Recon.seen?(view, 282)
      # Never visited.
      refute Recon.seen?(view, 300)
      refute Recon.seen?(view, 999)
    end
  end

  describe "enrich" do
    defp hostile(system_id) do
      %{
        id: 7,
        system: system_id,
        faction: :myrmezir,
        protection: nil,
        counter_intelligence: nil,
        determination: nil,
        in_own_system?: false,
        home_happiness: nil,
        besieging_ours?: false,
        visibility: 0,
        transient?: false
      }
    end

    defp system(faction) do
      %{
        characters: [%{id: 7, protection: 30, determination: 12}],
        governor: nil,
        owner: %{faction: faction},
        counter_intelligence: %{value: 18},
        happiness: %{value: 40},
        siege: nil
      }
    end

    test "a hostile beyond the scan cap stays unread instead of raising" do
      # i185, 2026-10-15: human agents stood in 77 systems, the scan reads 60,
      # and every Warlord pass died here for four days.
      enriched = Recon.enrich(hostile(500), %{}, %{500 => 6}, %{500 => 6}, :rebellion)

      assert enriched.visibility == 6
      assert enriched.protection == nil
      assert enriched.determination == nil
      assert enriched.counter_intelligence == 0
      refute enriched.in_own_system?
      assert enriched.home_happiness == nil
      refute enriched.besieging_ours?
    end

    test "a scanned system in the hostile's own faction gives what the visibility allows" do
      systems = %{500 => system(:myrmezir)}

      full = Recon.enrich(hostile(500), systems, %{500 => 6}, %{500 => 6}, :rebellion)
      assert full.protection == 30
      assert full.determination == 12
      assert full.counter_intelligence == 18
      assert full.in_own_system?
      assert full.home_happiness == 40

      dim = Recon.enrich(hostile(500), systems, %{500 => 3}, %{500 => 0}, :rebellion)
      assert dim.protection == nil
      assert dim.counter_intelligence == 0
      assert dim.home_happiness == 40
      assert dim.transient?
    end
  end
end
