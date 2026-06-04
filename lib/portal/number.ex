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

    Number.Delimit.number_to_delimited(value,
      delimiter: delimiter,
      separator: separator,
      precision: Keyword.fetch!(opts, :precision)
    )
  end
end
