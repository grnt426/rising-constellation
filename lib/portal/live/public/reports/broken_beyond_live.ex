defmodule Portal.Reports.BrokenBeyondLive do
  @moduledoc """
  Player-facing recap of Rebel Defense match 185, "Broken Beyond": how
  Myrmezir's players did against the Rebellion bot. Logged-in players
  only (the `/reports` scope in the router).

  The numbers were computed from production data after the match and
  re-derived independently before publishing. The table and chart data
  live in `priv/reports/broken_beyond.json` and are read at compile time;
  the headline numbers are written into the template.
  """

  use Portal, :live_view

  @data_path Path.expand("../../../../../priv/reports/broken_beyond.json", __DIR__)
  @external_resource @data_path
  @data @data_path |> File.read!() |> Jason.decode!()

  # Match day the Rebellion stopped acting, and the day the match ended.
  @freeze_day 16.9
  @end_day 22.34

  # Sector strip geometry (SVG user units; the SVG scales to its box). The
  # timeline sits between the labels and a separate "End" column, which
  # shows each sector's final owner: a sector taken on the last tick (Dor-
  # Valon) is otherwise a sliver too thin to see.
  @strip_width 1000
  @strip_label 240
  @strip_end_gap 18
  @strip_end_width 64
  @strip_row 20
  @strip_gap 5

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       page_title: "Broken Beyond",
       strip: strip(@data["sectors"]),
       sprite: Routes.static_path(socket, "/img/help-icons.svg")
     )
     |> show("freeze")}
  end

  @impl true
  def handle_event("show", %{"at" => at}, socket) when at in ["freeze", "end"],
    do: {:noreply, show(socket, at)}

  def handle_event("show", _params, socket), do: {:noreply, socket}

  # The player table at one of the two readings: "freeze" (day 16.6) or "end".
  defp show(socket, at) do
    rows = @data["players"][at]

    assign(socket,
      at: at,
      bot: Enum.find(rows, & &1["bot"]),
      humans: Enum.reject(rows, & &1["bot"])
    )
  end

  @doc "One labelled bar of a comparison: `side` picks the colour, `value / max` the length."
  attr(:who, :string, required: true)
  attr(:side, :string, required: true)
  attr(:value, :integer, required: true)
  attr(:max, :integer, required: true)
  attr(:label, :string, required: true)

  def bar(assigns) do
    # The longest bar stops at 85% so its value label still fits.
    assigns = assign(assigns, :width, Float.round(assigns.value / assigns.max * 85, 1))

    ~H"""
    <div class="report-bar">
      <span class="report-bar-who"><%= @who %></span>
      <span class="report-bar-track">
        <span class={"report-bar-fill report-bar-fill--#{@side}"} style={"width: #{@width}%"}></span>
        <span class="report-bar-value" style={"left: #{@width}%"}><%= @label %></span>
      </span>
    </div>
    """
  end

  @doc "Superscript link from a table heading to note `n` under the table."
  attr(:n, :integer, required: true)

  def note_ref(assigns) do
    ~H"""
    <sup class="report-ref"><a href={"#report-note-#{@n}"} aria-label={"note #{@n}"}><%= @n %></a></sup>
    """
  end

  @doc "Thousands separators for whole numbers: 40945 -> \"40,945\"."
  def num(nil), do: "–"

  def num(value) when is_number(value) do
    value
    |> round()
    |> Integer.to_string()
    |> String.replace(~r/\B(?=(\d{3})+(?!\d))/, ",")
  end

  def level(nil), do: "–"
  def level(value), do: :erlang.float_to_binary(value / 1, decimals: 1)

  @doc "How many times the bot's credit income a player's income is, as \"2.3×\"."
  def multiple(_bot, player) when player in [nil, 0], do: "–"

  def multiple(bot, player) do
    ratio = bot / player
    if ratio > 50, do: ">50×", else: :erlang.float_to_binary(ratio, decimals: 1) <> "×"
  end

  # Rows of {label, y, [segment]} for the sector-ownership SVG, built from
  # the claim and flip events. Sector 0 starts Myrmezir, 10 the Rebellion.
  defp strip(%{"order" => order, "names" => names, "events" => events, "homes" => homes}) do
    inner = @strip_width - @strip_label - @strip_end_gap - @strip_end_width
    end_x = @strip_label + inner + @strip_end_gap
    x = fn day -> @strip_label + day / @end_day * inner end

    rows =
      order
      |> Enum.with_index()
      |> Enum.map(fn {sector, index} ->
        start = Map.get(homes, Integer.to_string(sector))
        changes = for [day, ^sector, owner] <- events, do: {day, owner}
        timeline = [{0.0, start} | changes]

        segments =
          timeline
          |> Enum.zip(Enum.drop(timeline, 1) ++ [{@end_day, nil}])
          |> Enum.filter(fn {{_day, owner}, _} -> owner end)
          |> Enum.map(fn {{from, owner}, {to, _}} ->
            %{
              x: Float.round(x.(from), 1),
              width: Float.round(max(x.(to) - x.(from) - 1, 1.0), 1),
              owner: owner,
              title:
                "#{names[Integer.to_string(sector)]}: #{owner_name(owner)}, day #{day_text(from)} to #{day_text(to)}"
            }
          end)

        name = names[Integer.to_string(sector)]
        {_day, final} = List.last(timeline)

        %{
          label: name,
          y: index * (@strip_row + @strip_gap),
          segments: segments,
          final: final,
          final_title: "#{name}: #{owner_name(final)} at the end"
        }
      end)

    ticks = for day <- 0..22//2, do: %{x: Float.round(x.(day), 1), label: if(day == 0, do: "day 0", else: "#{day}")}

    %{
      rows: rows,
      ticks: ticks,
      width: @strip_width,
      label: @strip_label,
      row: @strip_row,
      height: length(rows) * (@strip_row + @strip_gap) + 22,
      freeze_x: Float.round(x.(@freeze_day), 1),
      freeze_width: Float.round(x.(@end_day) - x.(@freeze_day), 1),
      inner: inner,
      end_x: end_x,
      end_width: @strip_end_width
    }
  end

  defp owner_name("myrmezir"), do: "Myrmezir"
  defp owner_name("rebellion"), do: "Rebellion"
  defp owner_name(nil), do: "nobody"

  defp day_text(day), do: :erlang.float_to_binary(day / 1, decimals: 1)
end
