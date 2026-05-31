defmodule Util.RomanNumerals do
  @moduledoc """
  Converts a positive integer as its parameter to a string containing
  the Roman Numeral representation of that integer.
  """

  def convert(number) do
    convert(number, [[10, ~c"X"], [9, ~c"IX"], [5, ~c"V"], [4, ~c"IV"], [1, ~c"I"]])
  end

  defp convert(0, _) do
    ~c""
  end

  defp convert(number, [[arabic, roman] | _] = l) when number >= arabic do
    roman ++ convert(number - arabic, l)
  end

  defp convert(number, [_ | t]) do
    convert(number, t)
  end
end
