defmodule Portal.Number do
  @moduledoc """
  Locale-aware number formatting for admin templates.

  Picks the thousands delimiter and decimal separator from
  `Portal.Gettext`'s current process locale:

      en → "1,234.5"
      fr → "1 234,5"
  """

  @separators %{
    "en" => %{delimiter: ",", separator: "."},
    "fr" => %{delimiter: " ", separator: ","}
  }

  def format(value, opts \\ [])

  def format(nil, _opts), do: ""

  def format(value, opts) when is_integer(value) do
    do_format(value, Keyword.put_new(opts, :precision, 0))
  end

  def format(value, opts) when is_float(value) do
    do_format(value, Keyword.put_new(opts, :precision, 2))
  end

  def format(value, opts) when is_binary(value) do
    case Float.parse(value) do
      {f, ""} -> format(f, opts)
      _ -> value
    end
  end

  defp do_format(value, opts) do
    locale = Gettext.get_locale(Portal.Gettext)
    %{delimiter: delimiter, separator: separator} = Map.get(@separators, locale, @separators["en"])

    delimit(value, delimiter, separator, Keyword.fetch!(opts, :precision))
  end

  # What the `number` package's Number.Delimit.number_to_delimited/2 did
  # for these options. It is written out here because `number` was the
  # last package holding decimal at 2.x (and with it ecto_sql at 3.13),
  # both with security fixes only in later majors.
  @doc false
  def delimit(value, delimiter, separator, precision) do
    rounded = Decimal.round(to_decimal(value), precision, :half_up)
    [int, frac] = rounded |> Decimal.abs() |> Decimal.to_string(:normal) |> split_fraction()

    sign = if Decimal.negative?(rounded), do: "-", else: ""
    frac = String.pad_trailing(frac, precision, "0")

    grouped =
      int
      |> String.reverse()
      |> String.graphemes()
      |> Enum.chunk_every(3)
      |> Enum.map_join(delimiter, &Enum.join/1)
      |> String.reverse()

    if precision > 0, do: sign <> grouped <> separator <> frac, else: sign <> grouped
  end

  defp to_decimal(value) when is_integer(value), do: Decimal.new(value)
  defp to_decimal(value) when is_float(value), do: Decimal.from_float(value)

  defp split_fraction(digits) do
    case String.split(digits, ".") do
      [int, frac] -> [int, frac]
      [int] -> [int, ""]
    end
  end
end
