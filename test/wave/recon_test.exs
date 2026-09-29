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
end
