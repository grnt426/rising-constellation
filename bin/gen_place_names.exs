# Regenerates priv/data/name/place.txt — the stellar-system name pool — from
# a character-level Markov chain so galaxies of up to 10,000 systems get
# unique names without falling back to Data.Picker's suffix scheme.
#
# Run inside the dev container (host Elixir is not supported on this project):
#
#     docker compose exec -T -u rc rc elixir bin/gen_place_names.exs
#
# Deterministic: fixed RNG seed, and the training base is the frozen original
# list (place.base.txt — snapshotted from place.txt on first run), so re-runs
# reproduce the same file instead of feeding generated names back into the
# model.
#
# Composition (see @quotas): the bulk is trained on the original hand-written
# list to preserve the game's overall feel; a minority share is trained on
# five per-culture corpora (in-game foundation lists + lore proper nouns +
# real-world names matching each faction's validated flavor — Greco-Roman /
# Byzantine for the Tetrarchy, French for Myrmezir, Arabic / Levantine /
# Mesopotamian with an Italian dash for Cardan, Nordic / British for A.R.K.,
# pan-Asian / African for the Synelectic Federation). Real-world seeds are
# training material only: every output name is rejected if it appears in any
# training corpus, so no real place name ever ships.
#
# Output hygiene: names are 4–9 chars, ASCII letters (+ one internal space at
# most), never end in a roman-numeral token (stellar bodies are named
# "<system> II"), pass a profanity blocklist (see also detect.js), avoid
# sector.txt collisions, and are capped per 3-letter prefix so typing a few
# letters in search narrows quickly (the original list peaks at 122 names for
# one prefix; additions are capped at @prefix_cap and skip prefixes that are
# already crowded).

defmodule PlaceNameGen do
  @moduledoc false

  @root Path.expand("..", __DIR__)
  @place Path.join(@root, "priv/data/name/place.txt")
  @base Path.join(@root, "priv/data/name/place.base.txt")
  @sector Path.join(@root, "priv/data/name/sector.txt")
  @foundation_dir Path.join(@root, "priv/data/name/foundation")

  @rng_seed {20_260_717, 424_242, 7}

  # ~11k total = 10k-system galaxies never suffix, with headroom.
  @quotas [
    generic: 5_782,
    tetrarchic: 550,
    myrmeziriannic: 550,
    cardanic: 550,
    stelloliberalism: 550,
    syn: 550
  ]

  @order 2
  @min_len 4
  @max_len 9
  # Max NEW names per 3-letter prefix, and base-list crowding beyond which a
  # prefix gets no additions at all.
  @prefix_cap 15
  @prefix_skip 40
  @max_attempts_factor 400

  # Substrings (>= 4 chars) and exact words that must not appear in output.
  # Mirrors the intent of detect.js; EN + FR since the game is bilingual.
  @bad_substrings ~w(fuck shit cunt nigg bitch penis vagin whore slut rape
                     porn putain salope merde encul batard connar foutre)
  @bad_words ~w(ass tit sex con cul kkk gay hoe fag pute bite anus arse cock
                dick piss crap damn hell nazi)

  @roman_tokens ~w(i ii iii iv v vi vii viii ix x)

  # French particles that read oddly as a system name's first word. "Al"-style
  # Arabic articles are fine — the original list already uses them.
  @bad_first_words ~w(de du le la les des d l)

  # ---------------------------------------------------------------------------
  # Per-culture training corpora.
  #
  # Foundation lists (priv/data/name/foundation/*.txt) are loaded at runtime
  # and merged in. The lists below add lore proper nouns (FAQ / tutorial) and
  # real-world names matching each culture's flavor. Seeds never ship: output
  # is deduped against every corpus.
  # ---------------------------------------------------------------------------

  @tetrarchic_seeds ~w(
    Akhena Agma Chatur Quartos Tetran Quadrinople Arledge Heliotor
    Nicaea Pergamon Ephesos Smyrna Byzantion Corinthos Thebae Argos Sparta
    Mycenae Knossos Delphi Olympia Larissa Thessaly Epirus Illyria Dalmatia
    Pannonia Moesia Thracia Anatolia Cappadocia Galatia Lydia Caria Phrygia
    Pontus Bithynia Ionia Aeolia Doris Achaea Arcadia Laconia Messenia Elis
    Boeotia Phocis Locris Aetolia Acarnania Thessalonica Heraclea Nikopolis
    Adrianopolis Chalcedon Nicomedia Ancyra Tarsus Antiochia Seleucia Apamea
    Ravenna Capua Tarentum Syracusa Neapolis Pompeii Ostia Praeneste Tibur
    Aquileia Mediolanum Verona Patavium Ariminum Pisae Genua Florentia
    Aurelia Valeria Octavia Livia Flavia Traiana Hadriana Antonina Severa
    Maxima Constantia Theodora Justinia Heracliana Palmyra Emesa Edessa
    Amida Melitene Sebastea Trapezus Sinope Amasea Iconium Attalia Perge
    Miletus Halicarn Cnidus Rhodos Lindos Salamis Paphos Kition Amathus
  )

  @myrmeziriannic_seeds ~w(
    Berceau Ariance Jasselan Edembor
    Vezelay Chambord Chinon Amboise Loches Saumur Angers Nevers Auxerre
    Bourges Poitiers Limoges Perigueux Sarlat Cahors Albi Castres Beziers
    Narbonne Carcassonne Perpignan Auch Tarbes Bayonne Biarritz Royan Cognac
    Angouleme Niort Vendee Cholet Vannes Lorient Quimper Morlaix Dinan
    Fougeres Laval Alencon Falaise Bayeux Honfleur Etretat Dieppe Amiens
    Arras Cambrai Valenciennes Charleville Verdun Nancy Epinal Vesoul
    Besancon Pontarlier Annecy Chambery Grenoble Valence Avignon Arles
    Aubagne Menton Antibes Grasse Draguignan Manosque Digne Barcelonnette
    Loire Garonne Dordogne Charente Vienne Creuse Allier Cher Indre Sarthe
    Mayenne Oise Marne Aube Yonne Saone Doubs Isere Drome Ardeche Aveyron
    Tarn Gers Adour Somme Escaut Meuse Moselle Vosges Jura Morvan Cevennes
    Vercors Queyras Aubrac Cantal Correze Lozere Berry Anjou Poitou Quercy
    Rouergue Gascogne Bigorre Comminges Armagnac Vivarais Forez Bresse
  )

  @cardanic_seeds ~w(
    Alkarun Baharith Taleh Alkamant Asylamba Carda
    Uruk Nippur Lagash Eridu Assur Nineveh Babil Mari Ebla Ugarit Byblos
    Sidon Tyros Bosra Petra Palmyra Halab Homs Damas Basra Kufa Samarra
    Mosul Raqqa Tikrit Najaf Karbala Aqaba Tabuk Taif Jizan Najran Sanaa
    Aden Zabid Shibam Tarim Muscat Nizwa Salalah Sohar Sharjah Ajman
    Fes Meknes Tetouan Agadir Essaouira Ouarzazate Tlemcen Oran Bejaia
    Setif Biskra Ghardaia Kairouan Sousse Sfax Gabes Tozeur Matmata
    Aldebaran Achernar Alnilam Alnitak Mintaka Saiph Rigel Betelgeuse
    Altair Vega Deneb Fomalhaut Alphard Algol Mizar Alcor Thuban Rastaban
    Eltanin Kochab Alkaid Mizram Adhara Wezen Aludra Furud Muliphein
    Cardano Ferrara Rimini Urbino Perugia Siena Lucca Pistoia Cremona
    Mantova Bergamo Brescia Vicenza Padova Treviso Modena Parma Piacenza
    Pavia Novara Asti Savona Imperia Ancona Ascoli Teramo Pescara Foggia
  )

  @stelloliberalism_seeds ~w(
    Azkos Ravecroft Kovaka
    Kiruna Lulea Umea Sundsvall Gavle Falun Karlstad Skovde Boras Halmstad
    Kalmar Vaxjo Ystad Visby Uppsala Orebro Malmo Lund Sigtuna Vadstena
    Bergen Stavanger Trondheim Tromso Narvik Bodo Alesund Molde Drammen
    Skien Arendal Hamar Roros Voss Odense Aalborg Esbjerg Ribe Viborg
    Randers Horsens Kolding Roskilde Helsingor Akureyri Husavik Selfoss
    Keflavik Hofn Grindavik Borgarnes Stykkis Isafjord Seydis Djupivogur
    Harrogate Whitby Grimsby Kendal Carlisle Durham Alnwick Hexham Morpeth
    Berwick Falkirk Stirling Perth Dundee Aviemore Inverness Oban Dumfries
    Galloway Penrith Keswick Buxton Matlock Ludlow Hereford Monmouth Tenby
    Crowhaven Nesthaven Ashhaven Wolfholm Ravenholm Stagholm Elkstad
    Bearvik Falconby Hartfell Thornby Wickford Norwick Eastvik Suderholm
  )

  @syn_seeds ~w(
    Shendo Baikin Mikali Nando Horo Koshak Arkoshak Nikar Djarreh Synel
    Sendai Akita Aomori Morioka Yamagata Niigata Toyama Kanazawa Fukui
    Nagano Matsumoto Gifu Hamamatsu Okayama Kurashiki Tottori Matsue
    Tokushima Matsuyama Kochi Saga Kumamoto Miyazaki Kagoshima Naha Beppu
    Datong Baotou Yulin Ankang Fuzhou Quanzhou Shantou Zhuhai Nanning
    Liuzhou Zunyi Guiyang Kunming Guilin Lanzhou Xining Yinchuan Harbin
    Dalian Qingdao Jinan Luoyang Kaifeng Chengdu Mandalay Bagan Sittwe
    Pakse Hue Danang Dalat Cantho Medan Padang Palembang Makassar Manado
    Kupang Ambon Ternate Cebu Davao Iloilo Bohol Luang Vigan Legazpi
    Mombasa Kisumu Arusha Dodoma Mwanza Kigoma Tabora Mbeya Ndola Kitwe
    Kasama Mongu Maun Ghanzi Kumasi Tamale Bouake Segou Mopti Kayes
    Zinder Maradi Agadez Katsina Sokoto Ilorin Ibadan Enugu Calabar
  )

  # ---------------------------------------------------------------------------

  def run do
    :rand.seed(:exsss, @rng_seed)

    base = load_base()
    sectors = read_names(@sector)

    corpora = %{
      generic: base,
      tetrarchic: culture_corpus("tetrarchic.txt", @tetrarchic_seeds),
      myrmeziriannic: culture_corpus("myrmeziriannic.txt", @myrmeziriannic_seeds),
      cardanic: culture_corpus("cardanic.txt", @cardanic_seeds),
      stelloliberalism: culture_corpus("stelloliberalism.txt", @stelloliberalism_seeds),
      syn: culture_corpus("syn.txt", @syn_seeds)
    }

    # Never ship a name equal to: an original name, any training seed, or a
    # sector name.
    forbidden =
      (base ++ sectors ++ Enum.flat_map(Map.values(corpora), & &1))
      |> Enum.map(&String.downcase/1)
      |> MapSet.new()

    base_prefixes = Enum.frequencies(Enum.map(base, &prefix3/1))

    {generated, prefix_counts} =
      Enum.reduce(@quotas, {[], %{}}, fn {culture, quota}, {acc, prefixes} ->
        model = train(corpora[culture])

        {names, prefixes} =
          generate(model, quota, forbidden_plus(forbidden, acc), base_prefixes, prefixes)

        if length(names) < quota do
          IO.puts(
            "WARNING: #{culture} quota #{quota} not met (#{length(names)}) — raise @max_attempts_factor or @prefix_cap"
          )
        end

        IO.puts("#{culture}: #{length(names)} names (sample: #{Enum.join(Enum.take(names, 8), ", ")})")
        {acc ++ Enum.map(names, fn n -> {n, culture} end), prefixes}
      end)

    all = base ++ Enum.map(generated, &elem(&1, 0))
    write_output(all)
    report(base, generated, prefix_counts, base_prefixes)
  end

  # -- corpus loading ----------------------------------------------------------

  # The frozen training base. Snapshot place.txt on first run so re-running
  # the generator never trains on (or dedupes against only) its own output.
  defp load_base do
    unless File.exists?(@base) do
      File.copy!(@place, @base)
      IO.puts("Snapshotted #{Path.relative_to(@place, @root)} -> #{Path.relative_to(@base, @root)}")
    end

    read_names(@base)
  end

  defp culture_corpus(foundation_file, seeds) do
    foundation = read_names(Path.join(@foundation_dir, foundation_file))
    Enum.uniq(foundation ++ seeds)
  end

  defp read_names(path) do
    path
    |> File.stream!()
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  # -- markov model ------------------------------------------------------------

  # Character-level chain, @order chars of context. Training strings are
  # lowercased with ^ / $ as start / stop sentinels.
  defp train(corpus) do
    corpus
    |> Enum.map(&String.downcase/1)
    |> Enum.reduce(%{}, fn name, model ->
      chars = String.graphemes(String.duplicate("^", @order) <> name <> "$")

      chars
      |> Enum.chunk_every(@order + 1, 1, :discard)
      |> Enum.reduce(model, fn chunk, model ->
        {ctx, [next]} = Enum.split(chunk, @order)
        Map.update(model, Enum.join(ctx), [next], &[next | &1])
      end)
    end)
  end

  defp generate(model, quota, forbidden, base_prefixes, prefix_counts) do
    max_attempts = quota * @max_attempts_factor

    Enum.reduce_while(1..max_attempts, {[], prefix_counts, MapSet.new()}, fn _, {names, prefixes, seen} ->
      cond do
        length(names) >= quota ->
          {:halt, {names, prefixes, seen}}

        true ->
          case emit(model) |> validate(forbidden, seen) do
            :reject ->
              {:cont, {names, prefixes, seen}}

            {:ok, name} ->
              p = prefix3(name)
              base_n = Map.get(base_prefixes, p, 0)
              new_n = Map.get(prefixes, p, 0)

              if base_n >= @prefix_skip or new_n >= @prefix_cap do
                {:cont, {names, prefixes, seen}}
              else
                {:cont, {[name | names], Map.put(prefixes, p, new_n + 1), MapSet.put(seen, String.downcase(name))}}
              end
          end
      end
    end)
    |> then(fn {names, prefixes, _seen} -> {Enum.reverse(names), prefixes} end)
  end

  defp emit(model) do
    emit(model, String.duplicate("^", @order), [])
  end

  defp emit(_model, _ctx, acc) when length(acc) > @max_len + 3, do: Enum.reverse(acc)

  defp emit(model, ctx, acc) do
    case Map.get(model, ctx) do
      nil ->
        Enum.reverse(acc)

      nexts ->
        case Enum.at(nexts, :rand.uniform(length(nexts)) - 1) do
          "$" -> Enum.reverse(acc)
          char -> emit(model, String.slice(ctx <> char, -@order, @order), [char | acc])
        end
    end
  end

  # -- filters -----------------------------------------------------------------

  defp validate(chars, forbidden, seen) do
    name = Enum.join(chars)

    with true <- String.length(name) in @min_len..@max_len,
         true <- name =~ ~r/^[a-z]+( [a-z]+)?$/,
         words = String.split(name, " "),
         true <- Enum.all?(words, &(String.length(&1) >= 2)),
         false <- hd(words) in @bad_first_words,
         false <- List.last(words) in @roman_tokens,
         false <- Enum.any?(@bad_substrings, &String.contains?(name, &1)),
         false <- Enum.any?(@bad_words, fn w -> w in words end),
         false <- MapSet.member?(forbidden, name),
         false <- MapSet.member?(seen, name) do
      {:ok, title_case(name)}
    else
      _ -> :reject
    end
  end

  defp title_case(name) do
    name
    |> String.split(" ")
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp prefix3(name), do: name |> String.downcase() |> String.slice(0, 3)

  defp forbidden_plus(forbidden, generated) do
    Enum.reduce(generated, forbidden, fn {n, _}, set ->
      MapSet.put(set, String.downcase(n))
    end)
  end

  # -- output ------------------------------------------------------------------

  defp write_output(names) do
    sorted = Enum.sort_by(names, &String.downcase/1)
    File.write!(@place, Enum.join(sorted, "\n") <> "\n")
    IO.puts("\nWrote #{length(sorted)} names to #{Path.relative_to(@place, @root)}")
  end

  defp report(base, generated, prefix_counts, base_prefixes) do
    total = Enum.frequencies_by(base, &prefix3/1)

    total =
      Enum.reduce(prefix_counts, total, fn {p, n}, acc ->
        Map.update(acc, p, n, &(&1 + n))
      end)

    worst =
      total
      |> Enum.sort_by(fn {_, n} -> -n end)
      |> Enum.take(5)
      |> Enum.map_join(", ", fn {p, n} -> "#{p}: #{n}" end)

    worst_base =
      base_prefixes
      |> Enum.sort_by(fn {_, n} -> -n end)
      |> Enum.take(5)
      |> Enum.map_join(", ", fn {p, n} -> "#{p}: #{n}" end)

    IO.puts("base: #{length(base)}, generated: #{length(generated)}, total: #{length(base) + length(generated)}")
    IO.puts("worst 3-letter prefixes before: #{worst_base}")
    IO.puts("worst 3-letter prefixes after:  #{worst}")
  end
end

PlaceNameGen.run()
