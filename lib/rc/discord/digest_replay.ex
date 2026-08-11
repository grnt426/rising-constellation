defmodule RC.Discord.DigestReplay do
  @moduledoc """
  Best-effort rebuild of `RC.Discord.NewsRelay`'s 6-hour digest
  accumulator after a restart mid-window.

  The digest accumulator is in-memory; a deploy near a 00/06/12/18 UTC
  boundary used to lose the whole window (first observed in prod
  2026-08-11: restart at 17:59:04, boundary at 18:00:00, silent
  digest). On relay boot this module re-reads the window's events from
  `player_events` — the global news log `Game.News.Server.publish/3`
  writes — and hands back windows in the relay's
  `%{instance_id => %{events: [{bulletin_key, payload}], count: n}}`
  shape.

  ## Fidelity limits

  `player_events` is not a perfect mirror of the relay's feed:

    * Colonizations and dominion flips post to Discord for EVERY
      event (`discord.colonized` / `discord.dominion` casts straight
      from `Game.News.Server.route/3`), but only the galaxy FIRST is
      published to `player_events` (`news.colonize.first` /
      `news.dominion.first`). A replayed window recovers those firsts
      and nothing else of that kind.
    * `vp.changed` is Discord-only — it never lands in
      `player_events`. A replayed window has no VP events, and
      `RC.Discord.DigestData.vp_rows/2` degrades to current standings
      with no gained/lost deltas.
    * Liberations, abandonments, and sector-control changes are
      published globally per event, so they replay at full fidelity.

  A partial digest beats a silent one; every miss above is an
  under-report, never an invention.

  Replay is best-effort by contract: any failure logs a warning and
  returns an empty accumulator — it must never block relay boot.
  """

  import Ecto.Query, only: [from: 2]

  require Logger

  alias RC.Discord.DigestData
  alias RC.Instances.PlayerEvent

  # player_events key => relay bulletin key. The firsts map back to
  # the every-event Discord kinds because their payloads are the same
  # enriched shape; the rest publish under the key the relay already
  # accumulates.
  @replay_keys %{
    "news.colonize.first" => "discord.colonized",
    "news.dominion.first" => "discord.dominion",
    "news.dominion.liberated" => "news.dominion.liberated",
    "news.system.abandoned" => "news.system.abandoned",
    "news.sector.claimed" => "news.sector.claimed",
    "news.sector.lost" => "news.sector.lost",
    "news.sector.flipped" => "news.sector.flipped"
  }

  # The digest folds (`DigestData`, `News.community_digest/2`) read
  # atom keys; rows store JSON. Only these fields come back — an
  # unexpected field in a row can never become an atom.
  @payload_fields %{
    "faction" => :faction,
    "prev_faction" => :prev_faction,
    "player_name" => :player_name,
    "system_name" => :system_name,
    "system_id" => :system_id,
    "sector_id" => :sector_id,
    "sector_name" => :sector_name
  }

  # Mirrors the relay's @digest_max_events runaway guard.
  @default_max_events 400

  @doc """
  Rebuild the current window's digest accumulator from `player_events`.

  Options: `:now` (window anchor, defaults to `DateTime.utc_now/0`)
  and `:max_events` (per-instance cap, defaults to #{@default_max_events}).

  Returns `%{instance_id => %{events: [...], count: n}}` — empty on
  any failure.
  """
  def rebuild(opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    max_events = Keyword.get(opts, :max_events, @default_max_events)
    since = DigestData.window_start(now)

    from(e in PlayerEvent,
      join: i in assoc(e, :instance),
      where: i.discord_ready == true,
      where: i.state not in ["ended", "maintenance"],
      where: e.type == "global",
      where: e.key in ^Map.keys(@replay_keys),
      where: e.inserted_at >= ^since,
      order_by: [asc: e.id],
      select: {e.instance_id, e.key, e.data}
    )
    |> RC.Repo.all()
    |> Enum.reduce(%{}, fn {instance_id, key, data}, acc ->
      case replay_event(key, data) do
        {:ok, event} -> add_event(acc, instance_id, event, max_events)
        :skip -> acc
      end
    end)
  rescue
    e ->
      Logger.warning("[RC.Discord.DigestReplay] window replay failed, starting empty: #{inspect(e)}")
      %{}
  catch
    :exit, reason ->
      Logger.warning("[RC.Discord.DigestReplay] window replay exited, starting empty: #{inspect(reason)}")
      %{}
  end

  @doc """
  Map one `player_events` row back to the relay's
  `{bulletin_key, payload}` event shape. Pure. Returns `:skip` for
  keys outside the digest feed or undecodable data.
  """
  def replay_event(key, data) do
    with {:ok, bulletin_key} <- Map.fetch(@replay_keys, key),
         {:ok, raw} when is_map(raw) <- Jason.decode(data) do
      {:ok, {bulletin_key, atomize_payload(raw)}}
    else
      _ -> :skip
    end
  end

  defp atomize_payload(raw) do
    Enum.reduce(@payload_fields, %{}, fn {string_key, atom_key}, acc ->
      case Map.fetch(raw, string_key) do
        {:ok, value} -> Map.put(acc, atom_key, value)
        :error -> acc
      end
    end)
  end

  defp add_event(acc, instance_id, event, max_events) do
    window = Map.get(acc, instance_id, %{events: [], count: 0})

    if window.count < max_events do
      Map.put(acc, instance_id, %{events: window.events ++ [event], count: window.count + 1})
    else
      acc
    end
  end
end
