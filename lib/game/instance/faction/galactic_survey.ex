defmodule Instance.Faction.GalacticSurvey do
  @moduledoc """
  Aggregates faction-visible system summaries for the Galactic Survey panel.

  Each row is projected from a `Faction.StellarSystem.obfuscate/4` result so the
  field-by-field visibility gates can't diverge from the system-detail view —
  any field below its required visibility level is returned as `nil` and the
  client renders it as `?`.

  Per-faction TTL cache (30s nominal, +/- 5s jitter) is stored on the faction's
  GenServer state. Jitter staggers refresh across factions so synchronized
  fetches don't all expire on the same tick.

  A request that finds the cache aged is still answered from it: the rebuild
  (one call per visible system) runs in a task of its own and lands back on
  the agent (`lookup/1`, `mark_refreshing/1`, `store/1`). Only a cache that
  was never built, or one left untouched for minutes, is rebuilt while the
  caller waits.

  ## Visibility gates (mirrors lib/game/instance/faction/{stellar_system,
  stellar_system/tile}.ex):

  - vis 0: row is excluded entirely (the panel is for systems the faction
    has actually scouted; vis-0 systems would be name+position-only clutter).
    Note: this misses the edge case of an agent sitting on a never-scouted
    neutral system (would be vis 2 after `resolve_system_visibility`); accepted
    as a v1 limitation per design.
  - vis >= 1: body counts by type, sum of per-body industrial / technological /
    activity factors, has_eden.
  - vis >= 2: count of built tiles (key still hidden); the agents standing in
    the system (obfuscate/4 has already dropped other factions' undercover
    Erased, so the list follows the same intel rules as the system view).
  - vis >= 4: which buildings are built (megastructure detection), system-level
    production / technology / ideology / credit income, counter-intelligence,
    and the upkeep of the fleets standing there (what `get_character` shows
    of an army at that level).
  - vis 5 (own): everything; queue contents are own-only and are not surfaced
    in this aggregate.
  """

  use TypedStruct

  alias Instance.Faction.Faction
  alias Instance.Faction.StellarSystem, as: FactionStellarSystem

  require Logger

  @ttl_ms 30_000
  @jitter_ms 5_000
  # How long past its expiry a cache may still be served while it is rebuilt
  # behind the request. Older than that (nobody asked for minutes), the
  # caller waits for fresh rows rather than be shown a stale table.
  @max_stale_ms 120_000
  # A background rebuild that has not reported back by then is given up on:
  # the next aged request starts another.
  @refresh_timeout_ms 60_000
  @megastructure_keys [:monument_dome, :high_factory_dome]

  # Maximum value an `industrial_factor` / `technological_factor` /
  # `activity_factor` can take on a stellar body. Not defined as a constant
  # anywhere in the game data, but confirmed by the design team. A
  # habitable_planet that hits this on all three categories is what the
  # player base calls an "Eden world".
  @body_stat_max 5

  def jason(), do: []

  typedstruct enforce: false do
    field(:expires_at, integer(), default: 0)
    field(:rows, list(), default: [])
    # until when a background rebuild is considered under way (0: none).
    # Postdates the first snapshots: Map.get only.
    field(:refreshing_until, integer(), default: 0)
  end

  def new(), do: %__MODULE__{expires_at: 0, rows: []}

  @doc """
  Returns `{updated_cache, rows}`. If the cache is fresh, returns it
  unchanged; otherwise rebuilds and returns a refreshed cache.
  """
  def get_or_build(cache, faction_state, instance_id) do
    cache = cache || new()
    now = monotonic_now()

    if now < cache.expires_at do
      {cache, cache.rows}
    else
      rows = build_rows(faction_state, instance_id)
      refreshed = %__MODULE__{rows: rows, expires_at: now + jittered_ttl()}
      {refreshed, rows}
    end
  end

  @doc """
  What the cache holds and what the caller should do about it:

    * `{:fresh, rows}` — serve them
    * `{:stale, rows}` — serve them and start a rebuild (`mark_refreshing/1`,
      then `build/2` away from the agent and `store/1` with its result)
    * `{:refreshing, rows}` — serve them, a rebuild is already under way
    * `:build` — nothing worth serving: rebuild now (`get_or_build/3`)
  """
  def lookup(cache) do
    cache = cache || new()
    now = monotonic_now()

    cond do
      now < cache.expires_at -> {:fresh, cache.rows}
      now - cache.expires_at > @max_stale_ms -> :build
      now < (Map.get(cache, :refreshing_until) || 0) -> {:refreshing, cache.rows}
      true -> {:stale, cache.rows}
    end
  end

  def mark_refreshing(cache),
    do: Map.put(cache || new(), :refreshing_until, monotonic_now() + @refresh_timeout_ms)

  @doc "The cache holding freshly built `rows`."
  def store(rows) when is_list(rows),
    do: %__MODULE__{rows: rows, expires_at: monotonic_now() + jittered_ttl(), refreshing_until: 0}

  @doc """
  The part of the faction's state a build reads, small enough to hand to
  another process (the full state carries the chat, the icons, the
  government).
  """
  def view(faction_state),
    do: %{
      id: faction_state.id,
      key: faction_state.key,
      contacts: faction_state.contacts,
      diplomacy: Map.get(faction_state, :diplomacy) || %{}
    }

  @doc "Builds the rows for a `view/1`. Slow: one call per visible system."
  def build(view, instance_id), do: build_rows(view, instance_id)

  # --- internals --------------------------------------------------------

  # Use system_time (wall clock, always positive epoch ms) rather than
  # monotonic_time — monotonic_time can be NEGATIVE shortly after BEAM
  # boot, and an empty cache's `expires_at: 0` then satisfies `now < 0`,
  # making the empty cache appear permanently fresh and starving
  # `build_rows/2` from ever running. For a 30s TTL the small risk of
  # a wall-clock NTP correction causing one extra rebuild is fine.
  defp monotonic_now(), do: System.system_time(:millisecond)

  defp jittered_ttl() do
    @ttl_ms + :rand.uniform(2 * @jitter_ms + 1) - @jitter_ms - 1
  end

  defp build_rows(faction_state, instance_id) do
    case Game.call(instance_id, :galaxy, :master, :get_state) do
      {:ok, galaxy} ->
        galaxy.stellar_systems
        |> Enum.filter(&coarse_visible?(&1, faction_state))
        |> Enum.map(&build_row(&1, faction_state, instance_id))
        |> Enum.reject(&is_nil/1)

      error ->
        Logger.error("[GalacticSurvey] galaxy fetch failed: #{inspect(error)}")
        []
    end
  end

  # Cheap pre-filter: skip systems that obviously won't yield vis > 0, so we
  # don't fan out a `Game.call` per system in the galaxy. Misses the
  # agent-on-unscouted-neutral edge case; documented above as a v1 limit.
  defp coarse_visible?(snapshot, faction_state) do
    contact = Map.get(faction_state.contacts, snapshot.id)
    contact_value = if contact, do: contact.value, else: 0
    own? = snapshot.faction == faction_state.key
    own? or contact_value > 0
  end

  defp build_row(snapshot, faction_state, instance_id) do
    case Game.call(instance_id, :stellar_system, snapshot.id, :get_state) do
      {:ok, system} ->
        contact = Faction.resolve_system_visibility(faction_state, system)
        vis = contact.value

        if vis > 0 do
          obfuscated =
            system
            |> FactionStellarSystem.obfuscate(contact, faction_state.id, instance_id)
            |> reveal_own_fleets(system, faction_state.key)

          project(obfuscated, snapshot, vis)
        else
          nil
        end

      _ ->
        nil
    end
  end

  # A faction knows the upkeep of its own fleets wherever they stand. The
  # system's contact level only decides what it sees of the others: in a
  # foreign system held at contact 2, obfuscate/4 has blanked the upkeep of
  # every Navarch, the faction's own included.
  @doc false
  def reveal_own_fleets(obfuscated, system, faction_key) do
    own =
      for c <- Map.get(system, :characters) || [],
          is_map(c.owner) and Map.get(c.owner, :faction) == faction_key,
          into: %{},
          do: {c.id, Map.get(c, :maintenance)}

    case Map.get(obfuscated, :characters) do
      characters when is_list(characters) and map_size(own) > 0 ->
        characters =
          Enum.map(characters, fn c ->
            case Map.fetch(own, c.id) do
              {:ok, maintenance} -> Map.put(c, :maintenance, maintenance)
              :error -> c
            end
          end)

        Map.put(obfuscated, :characters, characters)

      _ ->
        obfuscated
    end
  end

  @doc false
  # Public for tests: projects one obfuscated system into a survey row.
  def project(obf, snap, vis) do
    bodies = obf.bodies || []
    # The stellar-body tree is nested — planets carry moons under :bodies,
    # asteroid belts carry asteroids, etc. The galaxy snapshot's
    # `score = length(system.bodies)` only counts top-level orbitals. For
    # this panel the user expects "everything in the system" semantics
    # (moons and asteroids contribute to per-body factors and tile counts),
    # so we flatten the tree once and aggregate over the full list.
    flat = flatten_bodies(bodies)

    %{
      id: snap.id,
      name: snap.name,
      sector_id: snap.sector_id,
      position: snap.position,
      type: snap.type,
      status: snap.status,
      visibility: vis,
      faction: snap.faction,
      owner_name: snap.owner,
      orbitals: length(flat),
      bodies_by_type: bodies_by_type(flat),
      sum_prod: sum_factor(flat, :industrial_factor),
      sum_sci: sum_factor(flat, :technological_factor),
      sum_appeal: sum_factor(flat, :activity_factor),
      has_eden: has_eden?(flat),
      built_tile_count: built_tile_count(flat, vis),
      total_tile_count: total_tile_count(flat, vis),
      megastructures_built: megastructures_built(flat, vis),
      current_prod: value_or_nil(Map.get(obf, :production)),
      current_sci: value_or_nil(Map.get(obf, :technology)),
      current_appeal: value_or_nil(Map.get(obf, :ideology)),
      current_credit: value_or_nil(Map.get(obf, :credit)),
      defense: value_or_nil(Map.get(obf, :defense)),
      stability: value_or_nil(Map.get(obf, :happiness)),
      counter_intelligence: value_or_nil(Map.get(obf, :counter_intelligence)),
      siege: Map.get(obf, :siege) != nil,
      agents: agents(Map.get(obf, :characters))
    }
  end

  # obfuscate/4 only fills :characters at vis >= 2, so nil means "can't
  # see" (rendered as ?) and [] means "seen, nobody there".
  defp agents(characters) when is_list(characters) do
    Enum.map(characters, fn c ->
      owner = Map.get(c, :owner) || %{}

      %{
        id: c.id,
        type: c.type,
        name: c.name,
        level: c.level,
        faction: Map.get(owner, :faction),
        owner_name: Map.get(owner, :name),
        # a fleet's upkeep: nil for anything but a Navarch, and for a
        # Navarch whose army this faction cannot read
        upkeep: Map.get(c, :maintenance)
      }
    end)
  end

  defp agents(_), do: nil

  # --- per-body aggregations --------------------------------------------

  defp flatten_bodies(bodies) do
    Enum.flat_map(bodies, fn body ->
      [body | flatten_bodies(body.bodies || [])]
    end)
  end

  defp bodies_by_type(flat_bodies) do
    Enum.reduce(flat_bodies, %{}, fn body, acc ->
      Map.update(acc, body.type, 1, &(&1 + 1))
    end)
  end

  defp sum_factor(flat_bodies, field) do
    Enum.reduce(flat_bodies, 0, fn body, acc ->
      case Map.get(body, field) do
        n when is_integer(n) -> acc + n
        _ -> acc
      end
    end)
  end

  defp has_eden?(flat_bodies) do
    Enum.any?(flat_bodies, fn body ->
      body.type == :habitable_planet and
        body.industrial_factor == @body_stat_max and
        body.technological_factor == @body_stat_max and
        body.activity_factor == @body_stat_max
    end)
  end

  # Tiles are obfuscated to set building_status: :hidden below vis 2, so a
  # nil/:hidden check on building_status is the gate for any tile counts.
  defp built_tile_count(flat_bodies, vis) when vis >= 2 do
    flat_bodies
    |> all_tiles()
    |> Enum.count(fn t -> t.building_status == :built end)
  end

  defp built_tile_count(_flat_bodies, _vis), do: nil

  defp total_tile_count(flat_bodies, vis) when vis >= 2 do
    flat_bodies
    |> all_tiles()
    |> Enum.count(fn t -> t.building_status != :hidden end)
  end

  defp total_tile_count(_flat_bodies, _vis), do: nil

  # building_key is only revealed at vis >= 4. Below that we cannot tell
  # which buildings exist, only how many tiles are filled.
  defp megastructures_built(flat_bodies, vis) when vis >= 4 do
    flat_bodies
    |> all_tiles()
    |> Enum.filter(fn t ->
      t.building_status == :built and t.building_key in @megastructure_keys
    end)
    |> Enum.map(& &1.building_key)
  end

  defp megastructures_built(_flat_bodies, _vis), do: nil

  defp all_tiles(flat_bodies) do
    Enum.flat_map(flat_bodies, fn body -> body.tiles || [] end)
  end

  # Faction.StellarSystem starts as a struct with nil fields and obfuscate
  # only populates the ones the visibility level permits. Production /
  # technology / ideology live behind vis >= 4, so below that they remain
  # nil; treat that as "unknown" rather than zero.
  defp value_or_nil(%Core.Value{value: v}), do: v
  defp value_or_nil(%Core.DynamicValue{value: v}), do: v
  defp value_or_nil(_), do: nil
end
