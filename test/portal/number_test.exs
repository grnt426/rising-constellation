defmodule Portal.NumberTest do
  # Portal.Number.delimit/4 replaced the `number` package's
  # Number.Delimit.number_to_delimited/2; these outputs were checked
  # against that function (92 cases, no differences) before it was removed.
  use ExUnit.Case, async: true

  alias Portal.Number

  test "groups thousands and keeps the sign" do
    assert Number.delimit(0, ",", ".", 0) == "0"
    assert Number.delimit(999, ",", ".", 0) == "999"
    assert Number.delimit(1000, ",", ".", 0) == "1,000"
    assert Number.delimit(-1_234_567, ",", ".", 0) == "-1,234,567"
    assert Number.delimit(1_000_000_000, " ", ",", 0) == "1 000 000 000"
  end

  test "pads integers to the requested precision" do
    assert Number.delimit(1234, ",", ".", 2) == "1,234.00"
    assert Number.delimit(-7, " ", ",", 2) == "-7,00"
  end

  test "rounds floats half up at the requested precision" do
    assert Number.delimit(1234.5, ",", ".", 2) == "1,234.50"
    assert Number.delimit(-1234.567, " ", ",", 2) == "-1 234,57"
    assert Number.delimit(999.995, ",", ".", 2) == "1,000.00"
    assert Number.delimit(12_345.6789, ",", ".", 0) == "12,346"
    assert Number.delimit(0.005, ",", ".", 2) == "0.01"
    assert Number.delimit(-0.5, ",", ".", 0) == "-1"
  end

  test "format/2 picks precision by type and passes strings through" do
    assert Number.format(nil) == ""
    assert Number.format(1234) == "1,234"
    assert Number.format(1234.5) == "1,234.50"
    assert Number.format("1234.5") == "1,234.50"
    assert Number.format("n/a") == "n/a"
  end
end
