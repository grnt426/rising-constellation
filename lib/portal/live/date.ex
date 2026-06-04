defmodule Portal.Date do
  @months %{
    "en" => %{
      1 => "Jan",
      2 => "Feb",
      3 => "Mar",
      4 => "Apr",
      5 => "May",
      6 => "Jun",
      7 => "Jul",
      8 => "Aug",
      9 => "Sep",
      10 => "Oct",
      11 => "Nov",
      12 => "Dec"
    },
    "fr" => %{
      1 => "jan.",
      2 => "fév.",
      3 => "mars",
      4 => "avril",
      5 => "mai",
      6 => "juin",
      7 => "juil.",
      8 => "août",
      9 => "sept.",
      10 => "oct.",
      11 => "nov.",
      12 => "déc."
    }
  }

  def format(date, mode) do
    locale = Gettext.get_locale(Portal.Gettext)
    months = Map.get(@months, locale, @months["en"])
    month = Map.fetch!(months, date.month)

    case {mode, locale} do
      {:date, "en"} ->
        "#{month} #{date.day}, #{date.year}"

      {:date, _} ->
        "#{date.day} #{month} #{date.year}"

      {:datetime, locale} ->
        hour = date.hour |> Integer.to_string() |> String.pad_leading(2, "0")
        minute = date.minute |> Integer.to_string() |> String.pad_leading(2, "0")

        base =
          case locale do
            "en" -> "#{month} #{date.day}, #{date.year}"
            _ -> "#{date.day} #{month} #{date.year}"
          end

        "#{base}, #{hour}:#{minute}"
    end
  end
end
