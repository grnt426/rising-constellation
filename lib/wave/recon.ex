defmodule Wave.Recon do
  @moduledoc """
  One reading of the enemy, shared by every Erased decision in a pass.

  The Warlord's other roles work off the galaxy projection alone; the Erased
  hunt people and fleets, which the galaxy does not carry. This module gathers
  that in the cheapest honest order:

    1. the Rebellion's own faction state, once — its stored contacts are what
       `Wave.Intel.visibility/2` turns into a per-system visibility;
    2. each human player's state, once each — the player payload already
       carries every agent's system, level and `army_size.filled`, so the
       hostile roster costs one call per human rather than one per system;
    3. the systems those agents are actually standing in, capped at
       `scan_cap` and closest-to-home first — these give protection,
       counter-intelligence and sieges;
    4. a last, small round of character reads for the fleets whose ship keys
       decide a colony-ship exemption, capped at `probe_cap`.

  Nothing beyond step 1 happens when the Rebellion has no Erased waiting for
  orders, and the agent holds a built view for `erased_recon_interval_ut` of
  game time before building another.

  ## Reading only what can be seen

  The engine hands a server-side caller the unobfuscated structs, so the
  filtering the client would get for free has to be applied here on purpose.
  Every field an Erased weighs is gated on the Rebellion's resolved visibility
  of the system it was read from, through `Wave.Intel.visible?/2` and the same
  tiers the engine's own obfuscators use: a defence the Rebellion cannot see
  arrives as `nil` and the removal gate treats it as the gamble it is.

  Filled tile counts are deliberately *not* gated: `Instance.Character.Tile`
  hides a filled tile's ship but never the fact that it is filled, so a fleet's
  size is public at any visibility. Its ship keys are not, which is why the
  colony-ship exemption needs visibility 4.
  """

  require Logger

  alias Wave.{Geometry, Intel}

  defstruct visibility: %{},
            stored: %{},
            seen: MapSet.new(),
            hostiles: [],
            systems: %{},
            scanned: [],
            built_at: 0.0,
            humans: 0,
            gauges: %{}

  @type t :: %__MODULE__{}

  @doc """
  Build the view. `opts`:

    * `:instance_id`, `:faction` — the Rebellion's key
    * `:faction_id` — the Rebellion's faction row id (for the faction read)
    * `:geo` — this pass's `Wave.Geometry`
    * `:player` — the bot player's state (for own-agent positions)
    * `:human_ids` — the player ids to read
    * `:elapsed` — game time, stamped on the view
    * `:scan_cap`, `:probe_cap`, `:field_depth`, `:probe_tiles`

  Never raises: a failed call degrades that reading to "unknown", which the
  gates already handle.
  """
  def build(opts) do
    instance_id = Keyword.fetch!(opts, :instance_id)
    geo = Keyword.fetch!(opts, :geo)
    faction = Keyword.fetch!(opts, :faction)
    field_depth = Keyword.get(opts, :field_depth, 2)

    faction_state = call(instance_id, :faction, Keyword.get(opts, :faction_id), :get_state)
    contacts = (faction_state && Map.get(faction_state, :contacts)) || %{}
    stances = (faction_state && Map.get(faction_state, :diplomacy)) || %{}

    own_agent_systems =
      case Keyword.get(opts, :player) do
        %{characters: characters} -> MapSet.new(characters, & &1.system) |> MapSet.delete(nil)
        _ -> MapSet.new()
      end

    humans = Enum.map(Keyword.get(opts, :human_ids, []), &call(instance_id, :player, &1, :get_state))
    humans = Enum.reject(humans, &is_nil/1)
    faction_ids = Map.new(humans, &{&1.faction, &1.faction_id})

    # Two readings per system: what the Rebellion sees now, and what it would
    # still see with none of its own agents standing there. The gap between
    # them is borrowed sight — real, but it leaves with the agent.
    resolved =
      Map.new(geo.systems, fn system ->
        own_system? = system.faction == faction

        stance =
          if own_system? or system.faction == nil,
            do: nil,
            else: Map.get(stances, Map.get(faction_ids, system.faction))

        contact = contacts |> Map.get(system.id) |> contact_value()
        opts = [own_system?: own_system?, stance: stance]

        {system.id,
         {Intel.visibility(contact, [{:own_agent?, MapSet.member?(own_agent_systems, system.id)} | opts]),
          Intel.visibility(contact, opts)}}
      end)

    visibility = Map.new(resolved, fn {id, {value, _stored}} -> {id, value} end)
    stored = Map.new(resolved, fn {id, {_value, value}} -> {id, value} end)

    # Every system an agent of ours has ever jumped into carries an explorer
    # contact for good, so a contact of any kind means the Rebellion has seen
    # the system at least once.
    seen = for {id, contact} <- contacts, seen_contact?(contact), into: MapSet.new(), do: id

    system_index = Map.new(geo.systems, &{&1.id, &1})
    hostiles = Enum.flat_map(humans, &roster(&1, system_index, geo, field_depth))

    {systems, scanned} =
      scan(instance_id, hostiles, system_index, geo, visibility, Keyword.get(opts, :scan_cap, 60))

    hostiles = Enum.map(hostiles, &enrich(&1, systems, visibility, stored, faction))

    hostiles =
      probe_ships(
        instance_id,
        hostiles,
        visibility,
        Keyword.get(opts, :probe_cap, 12),
        Keyword.get(opts, :probe_tiles, 6)
      )

    %__MODULE__{
      visibility: visibility,
      stored: stored,
      seen: seen,
      hostiles: hostiles,
      systems: systems,
      scanned: scanned,
      humans: length(humans),
      built_at: Keyword.get(opts, :elapsed, 0.0),
      gauges: gauges(hostiles, scanned)
    }
  end

  @doc """
  The Warlord gauges a view reports, keyed by their final gauge names.

  The names are written out as literals on purpose. Gauges live in the
  Warlord's state, which is snapshotted, and a snapshot is decoded with
  `binary_to_term(:safe)` on a FRESH VM at deploy, which only knows atoms
  that appear in compiled code. They used to be prefixed at runtime
  (`:"hostile_\#{key}"`), and the whole instance was refused as unsafe:
  Rebel Defense game 185 stayed in maintenance after the 2026-09-28 deploys.
  """
  def gauges(hostiles, scanned) do
    %{
      hostile_hostiles: length(hostiles),
      hostile_scanned: length(scanned),
      hostile_fleets: Enum.count(hostiles, &(&1.type == :admiral)),
      hostile_sieges: Enum.count(hostiles, & &1.besieging_ours?),
      hostile_borrowed_sight: Enum.count(hostiles, & &1.transient?)
    }
  end

  @doc "Resolved visibility of a system, or 0 when the view never saw it."
  def visibility(%__MODULE__{} = view, system_id), do: Map.get(view.visibility, system_id, 0)

  @doc """
  What the Rebellion would still see of a system with none of its own agents
  standing in it — informers and ownership only. This is the sight that keeps,
  and it is what a long journey has to be justified by.
  """
  def stored_visibility(%__MODULE__{} = view, system_id), do: Map.get(Map.get(view, :stored, %{}), system_id, 0)

  @doc "True when the Rebellion has ever seen the system: any contact at all, or its own."
  def seen?(%__MODULE__{} = view, system_id),
    do: MapSet.member?(view.seen, system_id) or stored_visibility(view, system_id) > 0

  @doc "True while a view is still fresh enough to reuse."
  def fresh?(%__MODULE__{} = view, elapsed, interval) when is_number(interval),
    do: elapsed - view.built_at < interval

  def fresh?(_view, _elapsed, _interval), do: false

  # --- roster -----------------------------------------------------------------

  # One human player's on-board agents, as hostiles. Everything here comes off
  # the player payload — no per-character calls.
  defp roster(player, system_index, geo, field_depth) do
    for character <- player.characters,
        character.status == :on_board,
        is_integer(character.system),
        system = Map.get(system_index, character.system),
        not is_nil(system) do
      %{
        id: character.id,
        type: character.type,
        name: character.name,
        level: character.level || 1,
        system: character.system,
        sector_id: system.sector_id,
        owner_id: player.id,
        faction: player.faction,
        theatre: Geometry.theatre_of(geo, system, field_depth),
        action_status: character.action_status,
        # A filled tile is never hidden by the engine's obfuscator, so fleet
        # size is public information at any visibility.
        tiles: character.army_size && Map.get(character.army_size, :filled, 0),
        # Set by probe_ships/5 where visibility allows it.
        colony_ship?: nil,
        # An undercover Erased cannot be targeted at all — the Rebellion has
        # no way to know it is there.
        discovered?: character.is_discovered,
        protection: nil,
        counter_intelligence: nil,
        besieging_ours?: false,
        visibility: 0,
        # Set by enrich/5: visible only because one of our agents is there.
        transient?: false
      }
    end
  end

  # --- system scan --------------------------------------------------------------

  # Only the systems hostiles actually stand in, closest to home first so a cap
  # bites on the far end of the map rather than on our own doorstep.
  defp scan(instance_id, hostiles, system_index, geo, visibility, cap) do
    ids =
      hostiles
      |> Enum.map(& &1.system)
      |> Enum.uniq()
      |> Enum.sort_by(fn id ->
        system = Map.get(system_index, id)
        {(system && Geometry.depth_of(geo, system)) || 99, -Map.get(visibility, id, 0), id}
      end)
      |> Enum.take(max(cap, 0))

    systems =
      ids
      |> Enum.map(&{&1, call(instance_id, :stellar_system, &1, :get_state)})
      |> Enum.reject(fn {_id, system} -> is_nil(system) end)
      |> Map.new()

    {systems, Map.keys(systems)}
  end

  # Fill in everything that needed the system read, each field gated on what
  # the Rebellion can actually see there.
  defp enrich(hostile, systems, visibility, stored, faction) do
    vis = Map.get(visibility, hostile.system, 0)
    system = Map.get(systems, hostile.system)

    seen = system && Enum.find(system.characters, &(&1.id == hostile.id))

    protection =
      if seen && Intel.visible?(:protection, vis), do: Map.get(seen, :protection)

    # Counter-intelligence only joins the defence when the target's own faction
    # holds the system — the same rule the attack actions apply.
    counter_intelligence =
      if system && Intel.visible?(:counter_intelligence, vis) and
           system.owner != nil and system.owner.faction == hostile.faction,
         do: system.counter_intelligence.value,
         else: 0

    %{
      hostile
      | visibility: vis,
        transient?: vis >= 2 and Map.get(stored, hostile.system, 0) < 2,
        protection: protection,
        counter_intelligence: counter_intelligence,
        besieging_ours?: besieging?(system, hostile, faction)
    }
  end

  # A siege names its besieger, so this is exact rather than inferred — and it
  # only counts when the system under it is the Rebellion's.
  defp besieging?(%{siege: %{besieger_id: besieger_id}} = system, hostile, faction),
    do: besieger_id == hostile.id and system.owner != nil and system.owner.faction == faction

  defp besieging?(_system, _hostile, _faction), do: false

  # --- ship keys -----------------------------------------------------------------

  # The colony-ship exemption is the only thing that needs a fleet's contents,
  # and only for fleets too small to be worth sabotaging on size alone. Ship
  # keys are visibility-4 information, so nothing else is asked.
  defp probe_ships(instance_id, hostiles, visibility, cap, probe_tiles) do
    probes =
      hostiles
      |> Enum.filter(fn h ->
        h.type == :admiral and (h.tiles || 0) > 0 and (h.tiles || 0) < probe_tiles and
          Intel.visible?(:ship_keys, Map.get(visibility, h.system, 0))
      end)
      |> Enum.sort_by(& &1.id)
      |> Enum.take(max(cap, 0))
      |> Map.new(fn h -> {h.id, colony_ship?(instance_id, h.id)} end)

    Enum.map(hostiles, fn h ->
      case Map.fetch(probes, h.id) do
        {:ok, value} -> %{h | colony_ship?: value}
        :error -> h
      end
    end)
  end

  defp colony_ship?(instance_id, character_id) do
    case call(instance_id, :character, character_id, :get_state) do
      %{army: army} when not is_nil(army) -> Instance.Character.Army.has_colonization_ship?(army)
      _ -> nil
    end
  end

  # --- helpers --------------------------------------------------------------------

  defp contact_value(%{value: value}) when is_number(value), do: trunc(value)
  defp contact_value(_contact), do: 0

  defp seen_contact?(%{details: details} = contact) when is_map(details),
    do: map_size(details) > 0 or contact_value(contact) > 0

  defp seen_contact?(contact), do: contact_value(contact) > 0

  defp call(_instance_id, _type, nil, _message), do: nil

  defp call(instance_id, type, id, message) do
    case Game.call_no_log(instance_id, type, id, message, 1, 5_000) do
      {:ok, value} -> value
      _ -> nil
    end
  end
end
