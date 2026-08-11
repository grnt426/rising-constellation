# Renders sample Discord news cards from a live-instance fixture.
#
#   docker compose exec -T rc gosu rc mix run --no-start bin/render_discord_samples.exs
#
# Expects tmp/discord_samples/i87_game_data.json (instances.game_data)
# and tmp/discord_samples/i87_ownership.json (galaxy + victory snapshot,
# see the rpc in the same directory's README-worthy history). Writes
# .svg and .png pairs alongside.

alias RC.Discord.Render.Cards

dir = "tmp/discord_samples"

game_data = Jason.decode!(File.read!(Path.join(dir, "i87_game_data.json")))
own_raw = Jason.decode!(File.read!(Path.join(dir, "i87_ownership.json")))

ownership = %{
  systems:
    Map.new(own_raw["systems"], fn s -> {s["id"], %{faction: s["faction"], status: s["status"]}} end),
  sectors: Map.new(own_raw["sectors"], fn s -> {s["id"], s["owner"]} end)
}

name_index = Map.new(own_raw["systems"], fn s -> {s["name"], s["id"]} end)

sys = fn name ->
  case Map.get(name_index, name) do
    nil -> IO.puts("WARN: system #{name} not found"); nil
    id -> id
  end
end

hl = fn name, kind, opts ->
  case sys.(name) do
    nil -> nil
    id -> Map.merge(%{system_id: id, kind: kind, label: name}, Map.new(opts))
  end
end

render = fn name, svg ->
  svg_path = Path.join(dir, name <> ".svg")
  png_path = Path.join(dir, name <> ".png")
  File.write!(svg_path, svg)

  {out, code} =
    System.cmd(
      "rsvg-convert",
      ["--width=1600", "--keep-aspect-ratio", "--format=png", "--output=#{png_path}", svg_path],
      stderr_to_stdout: true
    )

  IO.puts("#{name}: exit=#{code} #{out}")
end

# --- A. daily bulletin -------------------------------------------------

bulletin_highlights =
  ([hl.("Boras", :bombard, []), hl.("Cone", :bombard, []), hl.("Quere", :bombard, [])] ++
     Enum.map(
       [{"Amorin", 3}, {"Vishama", 3}, {"Bagou", 2}, {"Fuiyan", 2}, {"Fukumata", 2}, {"Fukur", 2}, {"Ikann", 2}, {"Mombagat", 2}],
       fn {n, c} -> hl.(n, :pillage, count: c, label: nil) end
     ))
  |> Enum.reject(&is_nil/1)

render.("bulletin", Cards.bulletin(%{
  instance_name: "Ham'burger — Legacy #3",
  day: 38,
  date: "2026-08-10",
  battles: %{
    engagements: 8,
    factions: [
      %{faction: "synelle", wins: 6, losses: 2},
      %{faction: "ark", wins: 2, losses: 6}
    ],
    records: [
      %{name: "Kalid", faction: "synelle", wins: 2, losses: 0},
      %{name: "Tremes", faction: "synelle", wins: 2, losses: 0},
      %{name: "Granite", faction: "synelle", wins: 1, losses: 0},
      %{name: "Lushyy", faction: "ark", wins: 1, losses: 0},
      %{name: "Alrua", faction: "synelle", wins: 1, losses: 2},
      %{name: "Tianxia", faction: "ark", wins: 1, losses: 6}
    ]
  },
  spoils: %{
    conquests: [],
    bombards: %{systems: ["Boras", "Cone", "Quere"], buildings: 41, population: 9400},
    pillages: %{
      raids: 23,
      credits: 148_200,
      technology: 3_100,
      ideology: 2_250,
      systems: [
        %{name: "Amorin", count: 3},
        %{name: "Vishama", count: 3},
        %{name: "Bagou", count: 2},
        %{name: "Fuiyan", count: 2},
        %{name: "Fukumata", count: 2},
        %{name: "Fukur", count: 2},
        %{name: "Ikann", count: 2},
        %{name: "Mombagat", count: 2},
        %{name: "Boras", count: 1},
        %{name: "Cone", count: 1},
        %{name: "Quere", count: 1}
      ]
    }
  },
  game_data: game_data,
  ownership: ownership,
  highlights: bulletin_highlights
}))

# --- A2. daily bulletin stress test: 5 factions, 26 commanders ---------

# synthesize a five-faction galaxy from the real geometry: contiguous
# sector chunks get one faction each, owned systems follow their sector
faction_cycle = ["synelle", "ark", "cardan", "myrmezir", "tetrarchy"]
sector_ids = own_raw["sectors"] |> Enum.map(& &1["id"]) |> Enum.sort()
chunk_size = max(1, ceil(length(sector_ids) / 5))

sector_owner5 =
  sector_ids
  |> Enum.chunk_every(chunk_size)
  |> Enum.with_index()
  |> Enum.flat_map(fn {chunk, i} -> Enum.map(chunk, &{&1, Enum.at(faction_cycle, rem(i, 5))}) end)
  |> Map.new()

ownership5 = %{
  systems:
    Map.new(own_raw["systems"], fn s ->
      faction = if s["faction"], do: Map.get(sector_owner5, s["sector_id"]), else: nil
      {s["id"], %{faction: faction, status: s["status"]}}
    end),
  sectors: sector_owner5
}

stress_records =
  [
    {"Kalid", "synelle", 7, 2}, {"Tremes", "synelle", 5, 1}, {"Granite", "synelle", 3, 2},
    {"Alrua", "synelle", 2, 4}, {"Vex", "synelle", 1, 3}, {"Lushyy", "ark", 6, 3},
    {"Tianxia", "ark", 4, 6}, {"Corvin", "ark", 3, 1}, {"Nadir", "ark", 2, 2},
    {"Okku", "ark", 1, 1}, {"Sellis", "cardan", 5, 4}, {"Vantari", "cardan", 3, 3},
    {"Merode", "cardan", 2, 1}, {"Quillon", "cardan", 2, 5}, {"Ashvale", "cardan", 1, 2},
    {"Bruma", "myrmezir", 6, 2}, {"Tessik", "myrmezir", 4, 3}, {"Ophane", "myrmezir", 2, 2},
    {"Drell", "myrmezir", 1, 4}, {"Ixara", "myrmezir", 1, 1}, {"Halcyon", "tetrarchy", 5, 5},
    {"Petraeus", "tetrarchy", 3, 4}, {"Winnow", "tetrarchy", 2, 3}, {"Sarland", "tetrarchy", 2, 2},
    {"Jassa", "tetrarchy", 1, 5}, {"Mordune", "tetrarchy", 1, 2}
  ]
  |> Enum.map(fn {n, f, w, l} -> %{name: n, faction: f, wins: w, losses: l} end)

stress_highlights =
  ([hl.("Boras", :bombard, []), hl.("Cone", :bombard, []), hl.("Quere", :bombard, []),
    hl.("Dumfri", :conquest, faction: "cardan"), hl.("Rimsby", :conquest, faction: "myrmezir")] ++
     Enum.map(
       [{"Amorin", 3}, {"Vishama", 3}, {"Bagou", 2}, {"Fuiyan", 2}, {"Fukumata", 2}, {"Fukur", 2}, {"Ikann", 2}, {"Mombagat", 2}],
       fn {n, c} -> hl.(n, :pillage, count: c, label: nil) end
     ))
  |> Enum.reject(&is_nil/1)

render.("bulletin5", Cards.bulletin(%{
  instance_name: "Pentarchy War — mock 5-faction match",
  day: 52,
  date: "2026-08-10",
  battles: %{
    engagements: 23,
    factions: [
      %{faction: "synelle", wins: 7, losses: 5},
      %{faction: "ark", wins: 5, losses: 6},
      %{faction: "cardan", wins: 4, losses: 4},
      %{faction: "myrmezir", wins: 4, losses: 3},
      %{faction: "tetrarchy", wins: 3, losses: 5}
    ],
    records: stress_records
  },
  spoils: %{
    conquests: [%{name: "Dumfri"}, %{name: "Rimsby"}],
    bombards: %{
      systems: ["Boras", "Cone", "Quere", "Amorin", "Vishama", "Bagou", "Fuiyan", "Fukumata", "Ikann", "Mombagat"],
      buildings: 87,
      population: 21_300
    },
    pillages: %{
      raids: 41,
      credits: 302_400,
      technology: 8_150,
      ideology: 5_600,
      systems: [
        %{name: "Amorin", count: 3}, %{name: "Vishama", count: 3}, %{name: "Bagou", count: 2},
        %{name: "Fuiyan", count: 2}, %{name: "Fukumata", count: 2}, %{name: "Fukur", count: 2},
        %{name: "Ikann", count: 2}, %{name: "Mombagat", count: 2}, %{name: "Boras", count: 1},
        %{name: "Cone", count: 1}, %{name: "Quere", count: 1}, %{name: "Mardir", count: 1}
      ]
    }
  },
  game_data: game_data,
  ownership: ownership5,
  highlights: stress_highlights
}))

# --- B. rolling 6-hour digest -----------------------------------------

digest_highlights =
  [
    hl.("Mardir", :gained, faction: "synelle"),
    hl.("Zaproron", :flipped, faction: "ark")
  ]
  |> Enum.reject(&is_nil/1)

victory = own_raw["victory"]
by_key = Map.new(victory["factions"], &{&1["key"], &1})

render.("digest", Cards.digest(%{
  instance_name: "Ham'burger — Legacy #3",
  window_label: "6-HOUR DIGEST · 06:00–12:00 UTC · DAY 38",
  day: 38,
  game_data: game_data,
  ownership: ownership,
  highlights: digest_highlights,
  legend: [{:gained, "Gained"}, {:lost, "Lost"}, {:flipped, "Changed hands"}],
  territory: [
    %{faction: "ark", entries: [%{sign: :+, text: "Zaproron — dominion established"}]},
    %{
      faction: "synelle",
      entries: [
        %{sign: :+, text: "Mardir — system colonized"},
        %{sign: :-, text: "Zaproron — dominion lost"}
      ]
    }
  ],
  vp: %{
    win_target: 14,
    rows: [
      %{faction: "ark", vp: by_key["ark"]["victory_points"], gained: [by_key["ark"]["victory_points"]], lost: []},
      %{faction: "synelle", vp: by_key["synelle"]["victory_points"], gained: [], lost: [by_key["synelle"]["victory_points"] + 1]}
    ]
  },
  totals: [
    %{faction: "ark", systems: by_key["ark"]["system_count"], dominions: by_key["ark"]["dominion_count"]},
    %{faction: "synelle", systems: by_key["synelle"]["system_count"], dominions: by_key["synelle"]["dominion_count"]}
  ]
}))

# --- B2. digest stress test: 5 factions --------------------------------

digest5_highlights =
  [
    hl.("Mardir", :gained, faction: "synelle"),
    hl.("Zaproron", :flipped, faction: "ark"),
    hl.("Dumfri", :gained, faction: "cardan"),
    hl.("Uppsanord", :gained, faction: "myrmezir"),
    hl.("Falkstvik", :lost, [])
  ]
  |> Enum.reject(&is_nil/1)

render.("digest5", Cards.digest(%{
  instance_name: "Pentarchy War — mock 5-faction match",
  window_label: "6-HOUR DIGEST · 06:00–12:00 UTC · DAY 52",
  day: 52,
  game_data: game_data,
  ownership: ownership5,
  highlights: digest5_highlights,
  legend: [{:gained, "Gained"}, {:lost, "Lost"}, {:flipped, "Changed hands"}],
  territory: [
    %{faction: "ark", entries: [%{sign: :+, text: "Zaproron — dominion established"}]},
    %{
      faction: "synelle",
      entries: [
        %{sign: :+, text: "Mardir — system colonized"},
        %{sign: :-, text: "Zaproron — dominion lost"}
      ]
    },
    %{faction: "cardan", entries: [%{sign: :+, text: "Dumfri — system colonized"}]},
    %{faction: "myrmezir", entries: [%{sign: :+, text: "Uppsanord — dominion established"}]},
    %{faction: "tetrarchy", entries: [%{sign: :-, text: "Falkstvik — system abandoned"}]}
  ],
  vp: %{
    win_target: 14,
    rows: [
      %{faction: "ark", vp: 9, gained: [9], lost: []},
      %{faction: "synelle", vp: 6, gained: [], lost: [7]},
      %{faction: "cardan", vp: 5, gained: [], lost: []},
      %{faction: "myrmezir", vp: 4, gained: [3, 4], lost: []},
      %{faction: "tetrarchy", vp: 2, gained: [], lost: []}
    ]
  },
  totals: [
    %{faction: "ark", systems: 24, dominions: 31},
    %{faction: "synelle", systems: 22, dominions: 25},
    %{faction: "cardan", systems: 19, dominions: 22},
    %{faction: "myrmezir", systems: 17, dominions: 26},
    %{faction: "tetrarchy", systems: 12, dominions: 14}
  ]
}))

# --- C. daily challenge blast -----------------------------------------

render.("daily", Cards.daily(%{
  date: "2026-08-08",
  challenge_name: "Charter of Prosperity",
  winners: [
    %{rank: 1, name: "Tremes", score: "290s to spare"},
    %{rank: 2, name: "Kalid", score: "201s to spare"},
    %{rank: 3, name: "Lushyy", score: "84s to spare"}
  ],
  next: %{
    name: "The Destroyer's Blueprint",
    description:
      "A race: research the Destroyer patent (the first capital ship). Score is the time left when it completes; ties break on patents researched, then banked technology.",
    mutators: [
      %{polarity: :positive, name: "Joyful Industry"},
      %{polarity: :positive, name: "Open Frontier"},
      %{polarity: :negative, name: "Luddite Backlash"}
    ]
  }
}))

# --- D. victory announcement ------------------------------------------

render.("victory", Cards.victory(%{
  instance_name: "Ham'burger — Legacy #3",
  winner: "ark",
  day: 41,
  victory_type_label: "Victory track complete",
  vp: %{
    win_target: 14,
    rows: [
      %{faction: "ark", vp: 14, gained: [14], lost: []},
      %{faction: "synelle", vp: 6, gained: [], lost: []}
    ]
  },
  totals: [
    %{faction: "ark", systems: 41, dominions: 49, players: 8},
    %{faction: "synelle", systems: 46, dominions: 39, players: 9}
  ]
}))

IO.puts("done")
