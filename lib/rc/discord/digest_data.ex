defmodule RC.Discord.DigestData do
  @moduledoc """
  Assembles the data maps for the 6-hour digest cards
  (`RC.Discord.Render.Cards.digest/1` and `digest_territory/1`) from a
  window's accumulated relay events plus the instance's live state.

  Windows are fixed to 00/06/12/18 UTC. The event-folding functions
  are pure (unit-tested without a running instance); `assemble/3` is
  the impure entry point that additionally fetches the galaxy and
  victory agent state.

  Event shape is the relay's `{bulletin_key, payload}` with atom-keyed
  payloads, the same feed `RC.Discord.News.community_digest/2` folds.
  """

  alias RC.Discord.News

  @window_hours 6

  ## Window boundary math ------------------------------------------------

  @doc "Milliseconds from `now` until the next 00/06/12/18 UTC boundary."
  def ms_until_next_close(now \\ DateTime.utc_now()) do
    seconds_today = now.hour * 3600 + now.minute * 60 + now.second
    window_s = @window_hours * 3600
    remainder = rem(seconds_today, window_s)
    ms_into_window = remainder * 1000 + div(elem(now.microsecond, 0), 1000)
    window_s * 1000 - ms_into_window
  end

  @doc """
  Label for the window that closes at (or just before) `now`, e.g.
  `"06:00–12:00 UTC"`. Tolerant of the timer firing a moment early or
  late: snaps to the nearest boundary.
  """
  def window_label(now \\ DateTime.utc_now()) do
    window_s = @window_hours * 3600
    seconds_today = now.hour * 3600 + now.minute * 60 + now.second
    close_h = rem(round(seconds_today / window_s) * @window_hours, 24)
    open_h = Integer.mod(close_h - @window_hours, 24)
    "#{pad(open_h)}:00–#{pad(close_h)}:00 UTC"
  end

  defp pad(h), do: String.pad_leading(Integer.to_string(h), 2, "0")

  ## Pure event folding --------------------------------------------------

  @doc """
  Per-faction territory-change groups for the card, in order of first
  movement: `[%{faction: "ark", entries: [%{sign: :+, text: "..."}]}]`.
  """
  def territory_groups(events) do
    events
    |> Enum.flat_map(&group_entries/1)
    |> Enum.reduce([], fn {faction, entry}, acc ->
      case List.keyfind(acc, faction, 0) do
        nil -> acc ++ [{faction, [entry]}]
        {^faction, entries} -> List.keyreplace(acc, faction, 0, {faction, entries ++ [entry]})
      end
    end)
    |> Enum.map(fn {faction, entries} -> %{faction: faction, entries: entries} end)
  end

  defp group_entries({"discord.colonized", p}),
    do: [{p[:faction], %{sign: :+, text: "#{p[:system_name]} — system colonized"}}]

  defp group_entries({"discord.dominion", p}) do
    gain = {p[:faction], %{sign: :+, text: "#{p[:system_name]} — dominion established"}}

    case p[:prev_faction] do
      nil -> [gain]
      prev -> [gain, {prev, %{sign: :-, text: "#{p[:system_name]} — dominion lost"}}]
    end
  end

  defp group_entries({"news.conquest", p}) do
    gain = {p[:faction], %{sign: :+, text: "#{p[:system_name]} — system conquered"}}

    case p[:prev_faction] do
      nil -> [gain]
      prev -> [gain, {prev, %{sign: :-, text: "#{p[:system_name]} — lost to conquest"}}]
    end
  end

  defp group_entries({"news.dominion.liberated", p}),
    do: [{p[:faction], %{sign: :-, text: "#{p[:system_name]} — dominion liberated"}}]

  defp group_entries({"news.system.abandoned", p}),
    do: [{p[:faction], %{sign: :-, text: "#{p[:system_name]} — system abandoned"}}]

  defp group_entries({"news.sector.claimed", p}),
    do: [{p[:faction], %{sign: :+, text: "sector #{p[:sector_name]} — control taken"}}]

  defp group_entries({"news.sector.lost", p}),
    do: [{p[:prev_faction], %{sign: :-, text: "sector #{p[:sector_name]} — control lost"}}]

  defp group_entries({"news.sector.flipped", p}),
    do: [
      {p[:faction], %{sign: :+, text: "sector #{p[:sector_name]} — control taken"}},
      {p[:prev_faction], %{sign: :-, text: "sector #{p[:sector_name]} — control lost"}}
    ]

  defp group_entries(_), do: []

  @doc """
  Map highlight markers for the window's ownership events, deduped by
  system (the last event for a system wins — a system colonized then
  flipped in one window shows its final state).
  """
  def highlights(events) do
    events
    |> Enum.flat_map(&highlight_entry/1)
    |> Enum.reduce([], fn h, acc -> List.keystore(acc, h.system_id, 0, {h.system_id, h}) end)
    |> Enum.map(fn {_id, h} -> h end)
  end

  defp highlight_entry({"discord.colonized", %{system_id: id} = p}) when not is_nil(id),
    do: [%{system_id: id, kind: :gained, label: p[:system_name], faction: p[:faction]}]

  defp highlight_entry({"discord.dominion", %{system_id: id} = p}) when not is_nil(id) do
    kind = if p[:prev_faction], do: :flipped, else: :gained
    [%{system_id: id, kind: kind, label: p[:system_name], faction: p[:faction]}]
  end

  # conquests get their own star marker — the loudest territory change
  defp highlight_entry({"news.conquest", %{system_id: id} = p}) when not is_nil(id),
    do: [%{system_id: id, kind: :conquest, label: p[:system_name], faction: p[:faction]}]

  defp highlight_entry({key, %{system_id: id} = p})
       when key in ["news.dominion.liberated", "news.system.abandoned"] and not is_nil(id),
       do: [%{system_id: id, kind: :lost, label: p[:system_name]}]

  defp highlight_entry(_), do: []

  @doc """
  VP rows for the strip: current standings from the victory factions,
  gained/lost star indices from the window's vp events (first
  `prev_vp` seen per faction = the window's starting score).
  """
  def vp_rows(vp_events, victory_factions) do
    start_vp =
      Enum.reduce(vp_events, %{}, fn {_key, p}, acc ->
        Map.put_new(acc, to_string(p[:faction]), p[:prev_vp] || 0)
      end)

    Enum.map(victory_factions, fn f ->
      faction = to_string(f.key)
      vp = f.victory_points
      start = Map.get(start_vp, faction, vp)

      {gained, lost} =
        cond do
          vp > start -> {Enum.to_list((start + 1)..vp), []}
          vp < start -> {[], Enum.to_list((vp + 1)..start)}
          true -> {[], []}
        end

      %{faction: faction, vp: vp, gained: gained, lost: lost}
    end)
  end

  @doc "Which map-legend entries the highlight kinds actually use."
  def legend_for(highlights) do
    kinds = highlights |> Enum.map(& &1.kind) |> MapSet.new()

    [{:conquest, "Conquered"}, {:gained, "Gained"}, {:lost, "Lost"}, {:flipped, "Changed hands"}]
    |> Enum.filter(fn {kind, _} -> MapSet.member?(kinds, kind) end)
  end

  ## Impure assembly -----------------------------------------------------

  @doc """
  Builds `%{community: data, legacy: data}` card inputs for one
  instance's closed window. Fetches the galaxy and victory agent
  state; returns `{:error, reason}` if the instance is no longer
  reachable (ended mid-window) so the caller can fall back to text.
  """
  def assemble(instance, instance_name, events, window_label) do
    {vp_events, map_events} = Enum.split_with(events, fn {key, _} -> News.vp_key?(key) end)

    with {:ok, galaxy} <- Game.call(instance.id, :galaxy, :master, :get_state),
         {:ok, victory} <- Game.call(instance.id, :victory, :master, :get_state) do
      ownership = %{
        systems:
          Map.new(galaxy.stellar_systems, fn s ->
            {s.id, %{faction: s.faction && to_string(s.faction), status: to_string(s.status)}}
          end),
        sectors: Map.new(galaxy.sectors, fn s -> {s.id, s.owner && to_string(s.owner)} end)
      }

      marks = highlights(map_events)
      groups = territory_groups(map_events)
      win_target = Map.get(victory, :win_points_target) || 14

      totals =
        Enum.map(victory.factions, fn f ->
          %{faction: to_string(f.key), systems: f.system_count, dominions: f.dominion_count}
        end)

      base = %{
        instance_name: instance_name,
        window_label: "6-HOUR DIGEST · #{window_label}",
        game_data: instance.game_data,
        ownership: ownership,
        highlights: marks,
        legend: legend_for(marks),
        territory: groups,
        totals: totals
      }

      {:ok,
       %{
         community: Map.put(base, :vp, %{win_target: win_target, rows: vp_rows(vp_events, victory.factions)}),
         legacy: base
       }}
    else
      other -> {:error, other}
    end
  rescue
    e -> {:error, e}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end
end
