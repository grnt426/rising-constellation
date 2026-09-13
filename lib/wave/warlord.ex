defmodule Wave.Warlord do
  @moduledoc """
  The Rebellion's brain: pure state and pure decisions.

  All I/O lives in `Wave.Warlord.Agent`; everything here is a function of the
  struct plus a galaxy/player snapshot, so it is unit-testable without booting
  an instance.

  ## MVP behaviour

  On a game-time cadence the Warlord runs one loop:

    1. keep the bot player solvent (top resources back up to their floors);
    2. every `hire_interval_ut`, buy a one-star Navarch from the character
       market, deploy it on-board at the capital, and drop a `transport_1`
       colony ship straight into its fleet — no production, no patents;
    3. give every idle coloniser a colonisation itinerary (lane hops plus the
       colonisation order) toward the nearest takeable uninhabited system;
    4. when a coloniser has spent its ship, recall it and dismiss it.

  Fields are read with `Map.get/3` and written with `Map.put/3` wherever they
  are new, per the snapshot-tolerance convention — a snapshot taken before a
  field existed must restore without it.
  """

  use TypedStruct

  alias Wave.Nav

  def jason(), do: [except: [:instance_id]]

  typedstruct enforce: true do
    field(:instance_id, integer())
    field(:bot_faction, atom())
    # Resolved lazily on the first tick: the profile id of the bot player.
    field(:player_id, integer() | nil)
    # ut accumulated toward the next hire.
    field(:hire_accum, float())
    # %{character_id => %{stage: :idle | :dispatched, target: system_id | nil,
    #                     since: float()}}
    field(:colonisers, map())
    field(:connected, boolean())
    field(:elapsed, float())
    field(:stats, map())
  end

  def new(instance_id, bot_faction) do
    %__MODULE__{
      instance_id: instance_id,
      bot_faction: bot_faction,
      player_id: nil,
      # Start the clock ready to fire, so the first Navarch launches on the
      # first tick instead of six real hours into the match.
      hire_accum: 0.0,
      colonisers: %{},
      connected: false,
      elapsed: 0.0,
      stats: %{hired: 0, deployed: 0, dispatched: 0, colonised: 0, dismissed: 0, refused: %{}}
    }
  end

  @doc """
  Wake often enough to serve whichever comes first: the standing management
  cadence or the next hire. Floored so a mis-set knob can never produce a
  zero-interval spin.
  """
  def compute_next_tick_interval(%__MODULE__{} = state) do
    cadence = positive(Wave.Config.knob(state.instance_id, "tick_interval_ut", 1.0), 1.0)
    until_hire = max(hire_interval(state) - state.hire_accum, 0.0)

    [cadence, until_hire]
    |> Enum.min()
    |> max(0.05)
  end

  def compute_next_tick_interval(_), do: 1.0

  @doc "Configured hire cadence in ut."
  def hire_interval(%__MODULE__{instance_id: instance_id}) do
    positive(Wave.Config.knob(instance_id, "hire_interval_ut", 120.0), 120.0)
  end

  @doc "True when enough game time has accumulated to buy the next Navarch."
  def hire_due?(%__MODULE__{} = state), do: state.hire_accum >= hire_interval(state)

  @doc "Reset the hire clock, keeping any overshoot so the cadence doesn't drift."
  def consume_hire(%__MODULE__{} = state) do
    %{state | hire_accum: max(state.hire_accum - hire_interval(state), 0.0)}
  end

  @doc "Advance the internal clocks by one tick's worth of game time."
  def advance(%__MODULE__{} = state, elapsed_time) when is_number(elapsed_time) do
    %{state | hire_accum: state.hire_accum + elapsed_time, elapsed: state.elapsed + elapsed_time}
  end

  def advance(state, _), do: state

  @doc "Count a successful action for the harness/status readout."
  def count(%__MODULE__{} = state, key) do
    %{state | stats: Map.update(state.stats, key, 1, &(&1 + 1))}
  end

  @doc "Count a refusal, keyed by `{what, reason}`, so failures are visible."
  def refuse(%__MODULE__{} = state, what, reason) do
    refused =
      state.stats
      |> Map.get(:refused, %{})
      |> Map.update({what, reason}, 1, &(&1 + 1))

    %{state | stats: Map.put(state.stats, :refused, refused)}
  end

  # --- coloniser bookkeeping -------------------------------------------------

  def track(%__MODULE__{} = state, character_id) do
    %{state | colonisers: Map.put(state.colonisers, character_id, %{stage: :idle, target: nil, since: state.elapsed})}
  end

  def forget(%__MODULE__{} = state, character_id) do
    %{state | colonisers: Map.delete(state.colonisers, character_id)}
  end

  def dispatched(%__MODULE__{} = state, character_id, target) do
    entry = %{stage: :dispatched, target: target, since: state.elapsed}
    %{state | colonisers: Map.put(state.colonisers, character_id, entry)}
  end

  def released(%__MODULE__{} = state, character_id) do
    case Map.get(state.colonisers, character_id) do
      nil -> state
      entry -> %{state | colonisers: Map.put(state.colonisers, character_id, %{entry | stage: :idle, target: nil})}
    end
  end

  @doc "System ids already claimed by a coloniser this run — never double-target."
  def reserved_targets(%__MODULE__{} = state) do
    state.colonisers
    |> Map.values()
    |> Enum.map(& &1.target)
    |> Enum.reject(&is_nil/1)
    |> MapSet.new()
  end

  def active_coloniser_count(%__MODULE__{} = state), do: map_size(state.colonisers)

  # --- pure targeting --------------------------------------------------------

  @doc """
  Sector ids the Rebellion may expand into. Mirrors
  `Instance.Galaxy.Galaxy.check_system_takeability/3`: a sector it already owns,
  or one adjacent to a sector it owns. Computed locally from one galaxy read
  rather than a `Game.call` per candidate system.
  """
  def takeable_sector_ids(galaxy, faction_key) do
    owned =
      galaxy.sectors
      |> Enum.filter(&(&1.owner == faction_key))
      |> MapSet.new(& &1.id)

    galaxy.sectors
    |> Enum.filter(fn sector ->
      MapSet.member?(owned, sector.id) or Enum.any?(sector.adjacent, &MapSet.member?(owned, &1))
    end)
    |> MapSet.new(& &1.id)
  end

  @doc """
  The nearest uninhabited, takeable, unreserved system reachable by star lane
  from `from_system_id`. Returns the galaxy system summary, or nil.
  """
  def colonisation_target(galaxy, faction_key, from_system_id, reserved)

  def colonisation_target(_galaxy, _faction_key, nil, _reserved), do: nil

  def colonisation_target(galaxy, faction_key, from_system_id, reserved) do
    takeable = takeable_sector_ids(galaxy, faction_key)
    distances = galaxy |> Nav.adjacency() |> Nav.hop_distances(from_system_id)

    galaxy.stellar_systems
    |> Enum.filter(fn system ->
      system.status == :uninhabited and
        MapSet.member?(takeable, system.sector_id) and
        not MapSet.member?(reserved, system.id) and
        Map.has_key?(distances, system.id)
    end)
    |> Enum.min_by(fn system -> {Map.fetch!(distances, system.id), system.id} end, fn -> nil end)
  end

  @doc "Itinerary for a colonisation: one jump action per lane, then the order."
  def colonisation_actions(hops, target_id) do
    jumps =
      Enum.map(hops, fn {from, to} ->
        %{"type" => "jump", "data" => %{"source" => from, "target" => to}}
      end)

    jumps ++ [%{"type" => "colonization", "data" => %{"target" => target_id}}]
  end

  @doc "JSON-able snapshot for the harness status endpoint and the mix task."
  def summary(%__MODULE__{} = state) do
    %{
      bot_faction: state.bot_faction,
      player_id: state.player_id,
      elapsed_ut: Float.round(state.elapsed / 1, 1),
      next_hire_in_ut: Float.round(max(hire_interval(state) - state.hire_accum, 0.0) / 1, 1),
      colonisers:
        Map.new(state.colonisers, fn {id, entry} -> {id, %{stage: entry.stage, target: entry.target}} end),
      stats: Map.update(state.stats, :refused, %{}, fn refused ->
        Map.new(refused, fn {{what, reason}, n} -> {"#{what}:#{inspect(reason)}", n} end)
      end)
    }
  end

  defp positive(value, _fallback) when is_number(value) and value > 0, do: value * 1.0
  defp positive(_value, fallback), do: fallback
end
