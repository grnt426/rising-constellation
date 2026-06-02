defmodule RcBot.NameGenerator do
  @moduledoc """
  Generates human-shaped profile names for bot accounts so they don't
  stand out as "Bot_47" in faction rosters. Faction-appropriate naming
  is a TODO — for now any plausible name is fine.

  Kept deliberately tiny; can grow into per-faction pools later.
  """

  @firsts ~w(
    Lyra Caius Mira Tael Orin Vex Sera Jaro Nyx Arden Roen Iva Cassia
    Mael Sol Tova Eden Quill Riven Ash Eira Pell Drew Sable Yara
  )

  @lasts ~w(
    Vance Korr Tarn Velis Arden Krell Mott Tsade Borek Eshe Falke Ipek
    Niven Orlich Rist Sandell Tarvos Ulin Vetra Wensel Yorath Zlatk
  )

  def random_name do
    "#{Enum.random(@firsts)} #{Enum.random(@lasts)}"
  end
end
