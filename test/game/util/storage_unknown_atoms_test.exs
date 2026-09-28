defmodule Util.StorageUnknownAtomsTest do
  @moduledoc """
  A refused snapshot names the atoms the VM has never seen — the whole
  diagnosis of a stuck restore (Rebel Defense game 185, 2026-09-28: gauge
  names built at runtime by the Warlord).
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  # the name only ever exists as bytes here: building the binary by hand
  # (not with term_to_binary) keeps the atom out of this VM
  @never_seen "zz_rc_never_interned_gauge_7f1c"

  defp snapshot_with_unknown_atom do
    known = :erlang.term_to_binary(%{gauges: %{hostile_fleets: 1}})
    <<131, rest::binary>> = known
    # a 2-tuple of {known map, unknown atom}
    <<131, 104, 2, rest::binary, 119, byte_size(@never_seen), @never_seen::binary>>
  end

  test "a refused snapshot logs the unknown atom names" do
    binary = snapshot_with_unknown_atom()

    log =
      capture_log(fn ->
        assert {:error, :unsafe_snapshot} = Util.Storage.decode_binary(binary)
      end)

    assert log =~ "unknown atoms"
    assert log =~ @never_seen
  end

  test "unknown_atoms/1 lists only atoms this VM lacks, without creating them" do
    assert Util.Storage.unknown_atoms(snapshot_with_unknown_atom()) == [@never_seen]
    assert_raise ArgumentError, fn -> String.to_existing_atom(@never_seen) end
  end
end
