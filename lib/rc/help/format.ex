defmodule RC.Help.Format do
  @moduledoc """
  Number, bonus and header formatting shared by the token expander and the
  table generators. All user-visible names come from the locale maps in the
  compile context (`ctx.locale`, falling back to `ctx.en`); the handful of
  table headers the manual needs itself live in `@strings`.
  """

  @strings %{
    "en" => %{
      building: "Building",
      built_on: "Built on",
      effect: "Effect",
      source: "Source",
      type: "Type",
      lex: "Lex",
      tradition: "Tradition",
      skill: "Agent skill",
      constant: "Constant",
      value: "Value",
      level: "Level",
      credit: "Credit",
      production: "Production",
      patent: "Patent",
      bonuses: "Bonuses",
      none: "None",
      per: "per",
      missing_table: "missing table"
    },
    "fr" => %{
      building: "Bâtiment",
      built_on: "Construit sur",
      effect: "Effet",
      source: "Source",
      type: "Type",
      lex: "Lex",
      tradition: "Tradition",
      skill: "Compétence d'agent",
      constant: "Constante",
      value: "Valeur",
      level: "Niveau",
      credit: "Crédit",
      production: "Production",
      patent: "Brevet",
      bonuses: "Bonus",
      none: "Aucun",
      per: "par",
      missing_table: "table manquante"
    }
  }

  def t(ctx, key) do
    get_in(@strings, [ctx.lang, key]) || get_in(@strings, ["en", key]) || Atom.to_string(key)
  end

  @doc "Compact number: integers as-is, floats with up to two decimals."
  def num(n) when is_integer(n), do: Integer.to_string(n)

  def num(n) when is_float(n) do
    if n == trunc(n) do
      Integer.to_string(trunc(n))
    else
      n |> Float.round(2) |> :erlang.float_to_binary(decimals: 2) |> String.trim_trailing("0")
    end
  end

  def num(other), do: to_string(other)

  def signed(n) when is_number(n) and n >= 0, do: "+" <> num(n)
  def signed(n) when is_number(n), do: "-" <> num(abs(n))

  def pct(v) when is_number(v), do: signed(round_pct(v)) <> " %"

  defp round_pct(v) do
    p = v * 100
    if p == trunc(p), do: trunc(p), else: Float.round(p * 1.0, 1)
  end

  @doc """
  Localized name from `data.json` (`path` is a list under the `"data"`
  object). Falls back to English, then to the last path segment.
  """
  def data_name(ctx, path) do
    get_in(ctx.locale.data, path) || get_in(ctx.en.data, path) || List.last(path)
  end

  def has_data_key?(ctx, path), do: not is_nil(get_in(ctx.en.data, path))

  @doc "Localized UI string from `game.json` (dotted path)."
  def ui(ctx, dotted) do
    path = String.split(dotted, ".")
    get_in(ctx.locale.game, path) || get_in(ctx.en.game, path)
  end

  @doc "`\"Navarch | Navarchs\"` → `\"Navarch\"`."
  def singular(name) when is_binary(name), do: name |> String.split("|") |> hd() |> String.trim()
  def singular(other), do: other

  def pipeline_in_name(ctx, key), do: data_name(ctx, ["bonus_pipeline_in", to_string(key), "name"])
  def pipeline_out_name(ctx, key), do: data_name(ctx, ["bonus_pipeline_out", to_string(key), "name"])

  @doc """
  One bonus as text. `last` is the same bonus at the building's top level,
  when there is one, which turns `+1.6 Mobility` into `+1.6 → +8 Mobility`.

  - `from: :direct`          → `+10 Housing`
  - `from == to` (multiplier) → `+25 % Defense`
  - otherwise                 → `+2.8 Production per Industrial Potential`
  """
  def bonus(ctx, %Core.Bonus{} = b, last \\ nil) do
    to_name = pipeline_out_name(ctx, b.to)

    cond do
      b.from == :direct ->
        "#{range(b.value, last && last.value, &signed/1)} #{to_name}"

      b.from == b.to and b.type == :mul ->
        "#{range(b.value, last && last.value, &pct/1)} #{to_name}"

      true ->
        "#{range(b.value, last && last.value, &signed/1)} #{to_name} #{t(ctx, :per)} #{pipeline_in_name(ctx, b.from)}"
    end
  end

  defp range(v, nil, fmt), do: fmt.(v)
  defp range(v, v2, fmt) when v == v2, do: fmt.(v)
  defp range(v, v2, fmt), do: "#{fmt.(v)} → #{fmt.(v2)}"

  @doc "Escape a value for a markdown table cell."
  def cell(text), do: text |> to_string() |> String.replace("|", "\\|") |> String.replace("\n", " ")

  @doc "Render a markdown table from header cells and row lists."
  def table(_headers, []), do: nil

  def table(headers, rows) do
    line = fn cells -> "| " <> Enum.map_join(cells, " | ", &cell/1) <> " |" end
    sep = "|" <> String.duplicate(" --- |", length(headers))
    Enum.join([line.(headers), sep | Enum.map(rows, line)], "\n")
  end
end
