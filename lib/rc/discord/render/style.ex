defmodule RC.Discord.Render.Style do
  @moduledoc """
  Shared palette, typography and low-level SVG helpers for the Discord
  news-image renderers. Everything here mirrors the SPA's visual
  language: faction colors come from `Data.Game.Faction.Content` (the
  same source the game client renders from), the lighter/darker
  variants reproduce the map's tinycolor2 +/-20 lightness transform
  (front/src/game/map/three-utils.js), and the panel chrome mirrors the
  mini-panel styling (rgba white fills over a near-black base).

  All output is inline-attribute SVG: librsvg does not reliably resolve
  stylesheets, so no classes, no CSS.
  """

  @faction_colors Map.new(Data.Game.Faction.Content.data(), &{&1.key, &1.color})

  @faction_names %{
    ark: "A.R.K.",
    cardan: "Cardan",
    myrmezir: "Myrmezir",
    synelle: "Synelectic Federation",
    tetrarchy: "Tetrarchy"
  }

  # Tight layouts (VP star rows) where the full Synelectic name collides
  # with adjacent columns.
  @faction_short_names %{
    ark: "A.R.K.",
    cardan: "Cardan",
    myrmezir: "Myrmezir",
    synelle: "Synelectic",
    tetrarchy: "Tetrarchy"
  }

  # SPA dark theme (front/src/styles/shared/variables.scss)
  @card_bg "#0e1013"
  @map_bg "#0e1726"
  @white "#e6e6e6"
  @neutral "#bfbfbf"

  @font_body "Nunito, DejaVu Sans, sans-serif"
  @font_title "Montserrat, DejaVu Sans, sans-serif"

  def card_bg, do: @card_bg
  def map_bg, do: @map_bg
  def white, do: @white
  def neutral, do: @neutral
  def font_body, do: @font_body
  def font_title, do: @font_title

  def faction_color(key) when is_atom(key), do: Map.get(@faction_colors, key, @neutral)

  def faction_color(key) when is_binary(key) do
    case safe_faction_key(key) do
      nil -> @neutral
      atom -> faction_color(atom)
    end
  end

  def faction_color(_), do: @neutral

  def faction_name(key) when is_atom(key), do: Map.get(@faction_names, key, "Neutral")

  def faction_name(key) when is_binary(key) do
    case safe_faction_key(key) do
      nil -> "Neutral"
      atom -> faction_name(atom)
    end
  end

  def faction_name(_), do: "Neutral"

  def faction_short_name(key) do
    case safe_faction_key(key) do
      nil -> "Neutral"
      atom -> Map.get(@faction_short_names, atom)
    end
  end

  def safe_faction_key(key) when is_atom(key), do: if(Map.has_key?(@faction_colors, key), do: key)

  def safe_faction_key(key) when is_binary(key) do
    Enum.find(Map.keys(@faction_colors), &(Atom.to_string(&1) == key))
  end

  def safe_faction_key(_), do: nil

  @doc "tinycolor2-style lighten: +N points of HSL lightness, clamped."
  def lighten(hex, amount \\ 20), do: shift_lightness(hex, amount)

  @doc "tinycolor2-style darken: -N points of HSL lightness, clamped."
  def darken(hex, amount \\ 20), do: shift_lightness(hex, -amount)

  defp shift_lightness(hex, amount) do
    {h, s, l} = hex |> hex_to_rgb() |> rgb_to_hsl()
    l = min(1.0, max(0.0, l + amount / 100))
    {h, s, l} |> hsl_to_rgb() |> rgb_to_hex()
  end

  defp hex_to_rgb(<<"#", r::binary-size(2), g::binary-size(2), b::binary-size(2)>>) do
    {String.to_integer(r, 16), String.to_integer(g, 16), String.to_integer(b, 16)}
  end

  defp rgb_to_hex({r, g, b}) do
    "#" <> Enum.map_join([r, g, b], fn c -> c |> round() |> Integer.to_string(16) |> String.pad_leading(2, "0") end)
  end

  defp rgb_to_hsl({r, g, b}) do
    {r, g, b} = {r / 255, g / 255, b / 255}
    maxc = Enum.max([r, g, b])
    minc = Enum.min([r, g, b])
    l = (maxc + minc) / 2

    if maxc == minc do
      {0.0, 0.0, l}
    else
      d = maxc - minc
      s = if l > 0.5, do: d / (2 - maxc - minc), else: d / (maxc + minc)

      h =
        cond do
          maxc == r -> (g - b) / d + if(g < b, do: 6, else: 0)
          maxc == g -> (b - r) / d + 2
          true -> (r - g) / d + 4
        end

      {h / 6, s, l}
    end
  end

  defp hsl_to_rgb({h, s, l}) do
    if s == 0 do
      v = l * 255
      {v, v, v}
    else
      q = if l < 0.5, do: l * (1 + s), else: l + s - l * s
      p = 2 * l - q
      {hue_to_rgb(p, q, h + 1 / 3) * 255, hue_to_rgb(p, q, h) * 255, hue_to_rgb(p, q, h - 1 / 3) * 255}
    end
  end

  defp hue_to_rgb(p, q, t) do
    t =
      cond do
        t < 0 -> t + 1
        t > 1 -> t - 1
        true -> t
      end

    cond do
      t < 1 / 6 -> p + (q - p) * 6 * t
      t < 1 / 2 -> q
      t < 2 / 3 -> p + (q - p) * (2 / 3 - t) * 6
      true -> p
    end
  end

  # --- SVG helpers ---

  def escape(text) do
    text
    |> to_string()
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
  end

  def fnum(n) when is_integer(n), do: Integer.to_string(n)
  def fnum(n) when is_float(n), do: :erlang.float_to_binary(n, decimals: 2)
  def fnum(_), do: "0"

  @doc "Format an integer with thin thousands separators: 148200 -> 148,200"
  def int(n) when is_number(n) do
    n
    |> round()
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end

  @doc """
  Mini-panel chrome: rounded rect with the SPA's translucent-white
  surface and hairline border, plus an uppercase title.
  """
  def panel(x, y, w, h, title \\ nil) do
    box =
      ~s{<rect x="#{x}" y="#{y}" width="#{w}" height="#{h}" rx="6" fill="rgba(255,255,255,0.05)" stroke="rgba(255,255,255,0.12)" stroke-width="1"/>}

    header =
      if title do
        ~s{<text x="#{x + 18}" y="#{y + 34}" font-family="#{@font_title}" font-weight="700" font-size="17" letter-spacing="2" fill="rgba(255,255,255,0.92)">#{escape(String.upcase(title))}</text>} <>
          ~s{<line x1="#{x + 18}" y1="#{y + 48}" x2="#{x + w - 18}" y2="#{y + 48}" stroke="rgba(255,255,255,0.12)" stroke-width="1"/>}
      else
        ""
      end

    box <> header
  end

  @doc """
  A faction chip: colored disc with the faction mark inside, mirroring
  the VictoryMiniPanel's `.faction-item` (inset shadow ring + icon).
  `d` is the disc diameter in px.
  """
  def faction_chip(faction, cx, cy, d) do
    key = safe_faction_key(faction)
    color = faction_color(faction)
    icons = RC.Discord.Render.Assets.faction_small()

    icon =
      case key && Map.get(icons, key) do
        %{viewbox: vb, body: body} ->
          [_, _, vw, _vh] = String.split(vb, " ")
          vw = String.to_integer(vw)
          inner = d * 0.62
          scale = inner / vw
          tx = cx - inner / 2
          ty = cy - inner / 2

          ~s{<g transform="translate(#{fnum(tx)},#{fnum(ty)}) scale(#{fnum(scale)})" fill="#0e1013">#{body}</g>}

        _ ->
          ""
      end

    ~s{<circle cx="#{fnum(cx)}" cy="#{fnum(cy)}" r="#{fnum(d / 2)}" fill="#{color}" stroke="rgba(0,0,0,0.35)" stroke-width="#{fnum(d * 0.07)}"/>} <>
      icon
  end

  @doc "Five-point star polygon points centered on cx,cy with outer radius r."
  def star_points(cx, cy, r) do
    inner = r * 0.42

    0..9
    |> Enum.map(fn i ->
      angle = -:math.pi() / 2 + i * :math.pi() / 5
      radius = if rem(i, 2) == 0, do: r, else: inner
      "#{fnum(cx + radius * :math.cos(angle))},#{fnum(cy + radius * :math.sin(angle))}"
    end)
    |> Enum.join(" ")
  end

  @doc """
  Greedy word-wrap for SVG text. Width estimation only (no shaping):
  ~0.52em per char for mixed case, ~0.62em for uppercase.
  Returns a list of lines.
  """
  def wrap_text(text, font_size, max_width, opts \\ []) do
    factor = Keyword.get(opts, :factor, 0.52)
    max_chars = max(8, trunc(max_width / (font_size * factor)))

    text
    |> String.split(" ")
    |> Enum.reduce([], fn word, acc ->
      case acc do
        [] ->
          [word]

        [line | rest] ->
          if String.length(line) + 1 + String.length(word) <= max_chars,
            do: [line <> " " <> word | rest],
            else: [word, line | rest]
      end
    end)
    |> Enum.reverse()
  end
end
