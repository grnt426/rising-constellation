defmodule RC.Archive.Xlsx do
  @moduledoc """
  Minimal .xlsx (Office Open XML SpreadsheetML) writer — just enough for
  tabular exports: one worksheet per `{name, rows}`, inline strings, numbers
  and booleans, a bold frozen header row and rough column widths.

  Written by hand (a zip of a few XML parts via `:zip`) rather than pulling
  in a dependency. Cells are never formulas, so text such as `=cmd()` in a
  player name is inert.

      RC.Archive.Xlsx.build([{"Sheet", [["name", "score"], ["Avok", 14_900]]}])
  """

  @main "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
  @rel "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
  @pkg_rel "http://schemas.openxmlformats.org/package/2006/relationships"
  @xml_head ~s(<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n)

  @doc "Rows are lists of cell values (string, number, boolean or nil); the first row is the header."
  def build(sheets) when is_list(sheets) do
    sheets =
      sheets
      |> Enum.with_index(1)
      |> Enum.map_reduce(MapSet.new(), fn {{name, rows}, i}, used ->
        name = unique_sheet_name(name, used)
        {{i, name, rows}, MapSet.put(used, name)}
      end)
      |> elem(0)

    parts =
      [
        {"[Content_Types].xml", content_types(sheets)},
        {"_rels/.rels", root_rels()},
        {"xl/workbook.xml", workbook(sheets)},
        {"xl/_rels/workbook.xml.rels", workbook_rels(sheets)},
        {"xl/styles.xml", styles()}
      ] ++ Enum.map(sheets, fn {i, _, rows} -> {"xl/worksheets/sheet#{i}.xml", worksheet(rows)} end)

    files = Enum.map(parts, fn {path, iodata} -> {String.to_charlist(path), IO.iodata_to_binary(iodata)} end)
    {:ok, {_, binary}} = :zip.create(~c"export.xlsx", files, [:memory])
    binary
  end

  # --- package parts -------------------------------------------------------

  defp content_types(sheets) do
    [
      @xml_head,
      ~s(<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">),
      ~s(<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>),
      ~s(<Default Extension="xml" ContentType="application/xml"/>),
      ~s(<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>),
      ~s(<Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>),
      Enum.map(sheets, fn {i, _, _} ->
        ~s(<Override PartName="/xl/worksheets/sheet#{i}.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>)
      end),
      "</Types>"
    ]
  end

  defp root_rels do
    [
      @xml_head,
      ~s(<Relationships xmlns="#{@pkg_rel}">),
      ~s(<Relationship Id="rId1" Type="#{@rel}/officeDocument" Target="xl/workbook.xml"/>),
      "</Relationships>"
    ]
  end

  defp workbook(sheets) do
    [
      @xml_head,
      ~s(<workbook xmlns="#{@main}" xmlns:r="#{@rel}"><sheets>),
      Enum.map(sheets, fn {i, name, _} -> ~s(<sheet name="#{escape(name)}" sheetId="#{i}" r:id="rId#{i}"/>) end),
      "</sheets></workbook>"
    ]
  end

  defp workbook_rels(sheets) do
    styles_id = length(sheets) + 1

    [
      @xml_head,
      ~s(<Relationships xmlns="#{@pkg_rel}">),
      Enum.map(sheets, fn {i, _, _} ->
        ~s(<Relationship Id="rId#{i}" Type="#{@rel}/worksheet" Target="worksheets/sheet#{i}.xml"/>)
      end),
      ~s(<Relationship Id="rId#{styles_id}" Type="#{@rel}/styles" Target="styles.xml"/>),
      "</Relationships>"
    ]
  end

  # Style 0 = default, style 1 = bold (header row).
  defp styles do
    [
      @xml_head,
      ~s(<styleSheet xmlns="#{@main}">),
      ~s(<fonts count="2"><font><sz val="11"/><name val="Calibri"/></font><font><b/><sz val="11"/><name val="Calibri"/></font></fonts>),
      ~s(<fills count="2"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill></fills>),
      ~s(<borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>),
      ~s(<cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>),
      ~s(<cellXfs count="2"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>),
      ~s(<xf numFmtId="0" fontId="1" fillId="0" borderId="0" xfId="0" applyFont="1"/></cellXfs>),
      ~s(<cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles>),
      "</styleSheet>"
    ]
  end

  defp worksheet(rows) do
    [
      @xml_head,
      ~s(<worksheet xmlns="#{@main}" xmlns:r="#{@rel}">),
      ~s(<sheetViews><sheetView workbookViewId="0">),
      ~s(<pane ySplit="1" topLeftCell="A2" activePane="bottomLeft" state="frozen"/>),
      "</sheetView></sheetViews>",
      cols(rows),
      "<sheetData>",
      rows |> Enum.with_index(1) |> Enum.map(fn {cells, r} -> row(cells, r) end),
      "</sheetData></worksheet>"
    ]
  end

  defp cols(rows) do
    widths =
      rows
      |> Enum.take(200)
      |> Enum.reduce(%{}, fn cells, acc ->
        cells
        |> Enum.with_index(1)
        |> Enum.reduce(acc, fn {v, c}, acc -> Map.update(acc, c, width(v), &max(&1, width(v))) end)
      end)

    if widths == %{} do
      []
    else
      [
        "<cols>",
        widths
        |> Enum.sort()
        |> Enum.map(fn {c, w} -> ~s(<col min="#{c}" max="#{c}" width="#{w}" customWidth="1"/>) end),
        "</cols>"
      ]
    end
  end

  defp width(v), do: v |> display_length() |> Kernel.+(2) |> max(8) |> min(50)

  defp display_length(nil), do: 0
  defp display_length(v) when is_binary(v), do: String.length(v)
  defp display_length(v), do: v |> to_string() |> String.length()

  defp row(cells, r) do
    style = if r == 1, do: ~s( s="1"), else: ""

    [
      ~s(<row r="#{r}">),
      cells
      |> Enum.with_index(1)
      |> Enum.map(fn {v, c} -> cell(v, "#{column(c)}#{r}", style) end),
      "</row>"
    ]
  end

  defp cell(nil, _ref, _style), do: []
  defp cell(true, ref, style), do: ~s(<c r="#{ref}" t="b"#{style}><v>1</v></c>)
  defp cell(false, ref, style), do: ~s(<c r="#{ref}" t="b"#{style}><v>0</v></c>)
  defp cell(v, ref, style) when is_integer(v), do: ~s(<c r="#{ref}"#{style}><v>#{v}</v></c>)

  defp cell(v, ref, style) when is_float(v),
    do: ~s(<c r="#{ref}"#{style}><v>#{:erlang.float_to_binary(v, [:short])}</v></c>)

  defp cell(v, ref, style) when is_binary(v),
    do: ~s(<c r="#{ref}" t="inlineStr"#{style}><is><t xml:space="preserve">#{escape(v)}</t></is></c>)

  defp cell(v, ref, style), do: cell(to_string(v), ref, style)

  @doc false
  def column(n) when n <= 26, do: <<?A + n - 1>>
  def column(n), do: column(div(n - 1, 26)) <> column(rem(n - 1, 26) + 1)

  # --- helpers -------------------------------------------------------------

  # Excel sheet names: max 31 chars, none of []:*?/\ and unique (case-insensitive).
  defp unique_sheet_name(name, used) do
    base = name |> String.replace(~r{[\[\]:*?/\\]}, " ") |> String.slice(0, 31)
    taken = MapSet.new(used, &String.downcase/1)

    Stream.iterate(1, &(&1 + 1))
    |> Stream.map(fn
      1 -> base
      n -> String.slice(base, 0, 31 - String.length(" (#{n})")) <> " (#{n})"
    end)
    |> Enum.find(&(not MapSet.member?(taken, String.downcase(&1))))
  end

  defp escape(s) do
    s
    |> String.replace(~r/[\x00-\x08\x0B\x0C\x0E-\x1F]/u, "")
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
  end
end
