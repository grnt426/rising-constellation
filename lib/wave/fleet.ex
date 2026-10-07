defmodule Wave.Fleet do
  @moduledoc """
  The rules the Rebellion's fleets are raised by: how many Navarchs serve each
  role, which systems are shipyards, what a shipyard can lay down, and where a
  finished fleet stands.

  Pure: functions of plain inputs. `Wave.Warlord.Agent` does the reading and
  the ordering; `Wave.Blueprints` supplies the designs.

  ## Roles

  A fleet Navarch is hired for one role and keeps it: `:defense` (stands in a
  Rebellion system), `:raid` (pillage), `:siege` (bombardment), `:conquest`
  (invasion, with Carriers) and `:screen` (kills the fleets that come to break
  a siege). The roster is split by weights that change with the stage of the
  match (`quotas/2`), and the next hire takes the role furthest below its
  share (`role_order/2`).

  ## Shipyards

  Fleets are built in the Rebellion's military systems, the type that rolls
  the shipyards (`yard_profile?/2`), and a yard lays down only the hulls whose
  shipyard stands there (`can_build?/3`). A ship leaves the yard with the experience
  the system gives that class, as a player's does (`initial_xp/2`).
  """

  alias Instance.StellarSystem.StellarSystem

  @roles Wave.Blueprints.roles()

  @class_levels %{fighter: :fighter_lvl, corvette: :corvette_lvl, frigate: :frigate_lvl, capital: :capital_lvl}

  @stages [:early, :mid, :late]

  @doc "The fleet roles, in the order ties are broken."
  def roles, do: @roles

  # --- roster ------------------------------------------------------------------

  @doc """
  The role weights for `stage` out of the `fleet_role_weights` knob
  (`%{"mid" => %{"defense" => 30, ...}}`), as `%{role => weight}` over every
  role. A stage the knob lacks falls back to the nearest earlier one.
  """
  def role_weights(knob, stage) when is_map(knob) and stage in @stages do
    raw =
      @stages
      |> Enum.take_while(&(&1 != stage))
      |> Kernel.++([stage])
      |> Enum.reverse()
      |> Enum.find_value(%{}, fn s ->
        case Map.get(knob, Atom.to_string(s)) do
          map when is_map(map) and map_size(map) > 0 -> map
          _ -> nil
        end
      end)

    Map.new(@roles, fn role ->
      case Map.get(raw, Atom.to_string(role)) do
        weight when is_number(weight) and weight > 0 -> {role, weight * 1.0}
        _ -> {role, 0.0}
      end
    end)
  end

  def role_weights(_knob, _stage), do: Map.new(@roles, &{&1, 0.0})

  @doc """
  `ceiling` fleets split by `weights`, in whole fleets: each role's exact share
  rounded down, the leftover places going to the largest remainders (ties in
  `roles/0` order).
  """
  def quotas(ceiling, weights) when is_integer(ceiling) and ceiling > 0 and is_map(weights) do
    total = weights |> Map.values() |> Enum.sum()

    if total <= 0 do
      Map.new(@roles, &{&1, 0})
    else
      exact = Map.new(@roles, fn role -> {role, ceiling * Map.get(weights, role, 0.0) / total} end)
      floors = Map.new(exact, fn {role, share} -> {role, trunc(share)} end)
      left = ceiling - (floors |> Map.values() |> Enum.sum())

      @roles
      |> Enum.with_index()
      |> Enum.sort_by(fn {role, index} -> {-(exact[role] - floors[role]), index} end)
      |> Enum.take(left)
      |> Enum.reduce(floors, fn {role, _index}, acc -> Map.update!(acc, role, &(&1 + 1)) end)
    end
  end

  def quotas(_ceiling, _weights), do: Map.new(@roles, &{&1, 0})

  @doc """
  The roles with places still open, the one furthest below its quota first
  (`roles/0` order among equals). The next hire takes the first of them it has
  a design for.
  """
  def role_order(quotas, counts) when is_map(quotas) and is_map(counts) do
    @roles
    |> Enum.with_index()
    |> Enum.map(fn {role, index} -> {role, Map.get(quotas, role, 0) - Map.get(counts, role, 0), index} end)
    |> Enum.filter(fn {_role, open, _index} -> open > 0 end)
    |> Enum.sort_by(fn {_role, open, index} -> {-open, index} end)
    |> Enum.map(&elem(&1, 0))
  end

  # --- shipyards ---------------------------------------------------------------

  @doc """
  True when a system of type `profile` is one of the Rebellion's shipyards.
  `profiles` is the `fleet_yard_profiles` knob: type names, by default only
  `"defense"`, the military type that rolls the shipyards.
  """
  def yard_profile?(profile, profiles) when is_atom(profile) and not is_nil(profile) and is_list(profiles),
    do: Atom.to_string(profile) in profiles

  def yard_profile?(_profile, _profiles), do: false

  @doc """
  What the Warlord keeps about a shipyard system: where it is, which shipyards
  stand there and the experience it gives each ship class.
  """
  def yard(%StellarSystem{} = system) do
    %{
      id: system.id,
      sector_id: system.sector_id,
      production: level_value(Map.get(system, :production)),
      shipyards: system |> standing_buildings() |> Enum.filter(&shipyard?/1) |> Enum.uniq() |> Enum.sort(),
      levels: Map.new(@class_levels, fn {class, field} -> {class, level_value(Map.get(system, field))} end)
    }
  end

  defp standing_buildings(system) do
    for body <- all_bodies(system.bodies),
        tile <- body.tiles,
        tile.building_status == :built,
        tile.building_key != nil,
        do: tile.building_key
  end

  defp shipyard?(building_key), do: building_key |> Atom.to_string() |> String.starts_with?("shipyard")

  defp all_bodies(bodies), do: Enum.flat_map(bodies || [], fn body -> [body | all_bodies(Map.get(body, :bodies))] end)

  defp level_value(%{value: value}) when is_number(value), do: value * 1.0
  defp level_value(_value), do: 0.0

  @doc """
  Can `yard` lay down `ship`? With `needs_shipyard?` the hull's own shipyard
  has to stand in the system; hulls that need none (the Carrier) build
  anywhere. Without it every yard builds everything.
  """
  def can_build?(_yard, _ship, false), do: true
  def can_build?(_yard, %{shipyard: nil}, true), do: true
  def can_build?(%{shipyards: shipyards}, %{shipyard: shipyard}, true), do: shipyard in shipyards

  @doc "Can `yard` build every ship of `slots` (`[{tile, ship_key}]`)?"
  def builds?(yard, slots, ships, needs_shipyard?) do
    Enum.all?(slots, fn {_tile, key} ->
      case Map.get(ships, key) do
        nil -> false
        ship -> can_build?(yard, ship, needs_shipyard?)
      end
    end)
  end

  @doc "The experience a ship of `ship`'s class leaves `yard` with."
  def initial_xp(%{levels: levels}, %{class: class}), do: Map.get(levels, class, 0.0)
  def initial_xp(_yard, _ship), do: 0.0

  @doc """
  The yard a new fleet is laid down in: among the yards that can build the
  whole design, the one with the fewest fleets already building there, then
  the one that gives its ships the most experience, then the lowest id.
  `busy` is `%{yard_id => fleets building}`. nil when no yard can.
  """
  def pick_yard(yards, slots, ships, busy, needs_shipyard?) do
    yards
    |> Enum.filter(&builds?(&1, slots, ships, needs_shipyard?))
    |> Enum.min_by(&{Map.get(busy, &1.id, 0), -experience(&1, slots, ships), &1.id}, fn -> nil end)
  end

  defp experience(yard, slots, ships) do
    slots |> Enum.map(fn {_tile, key} -> initial_xp(yard, Map.get(ships, key)) end) |> Enum.sum()
  end

  # --- construction ------------------------------------------------------------

  @doc """
  The next ship to lay down: the first slot of the design, in tile order, whose
  tile is still empty in `army`. A tile holding any ship is left alone, so a
  fleet that lost ships refits only its gaps. nil when nothing is missing.
  """
  def next_ship(slots, %{tiles: tiles}) do
    empty = for tile <- tiles, tile.ship_status == :empty, into: MapSet.new(), do: tile.id

    slots
    |> Enum.sort()
    |> Enum.find(fn {tile, _key} -> MapSet.member?(empty, tile) end)
  end

  def next_ship(_slots, _army), do: nil

  @doc "Ships of the design the army does not hold yet (empty tiles)."
  def missing(slots, %{tiles: tiles}) do
    empty = for tile <- tiles, tile.ship_status == :empty, into: MapSet.new(), do: tile.id
    Enum.count(slots, fn {tile, _key} -> MapSet.member?(empty, tile) end)
  end

  def missing(slots, _army), do: length(slots)

  @doc """
  Game time `yard` takes over `ship`. The standing rule is one ship per
  `interval`, whatever the ship. With a `pace` above zero the yard also has to
  pay for the hull out of its own production, as a player's system would,
  `pace` times as fast: a scout swarm still takes one interval, a Cruiser takes
  hours. The interval stays the floor.
  """
  def ship_ut(yard, ship, interval, pace) when is_number(interval) and is_number(pace) do
    production = Map.get(yard, :production, 0.0)

    if pace > 0 and production > 0,
      do: max(interval * 1.0, ship.production / (production * pace)),
      else: interval * 1.0
  end

  @doc """
  The interval a ship of `ship`'s class takes: its class's entry in
  `by_class` (the `fleet_class_interval_ut` knob, `%{"capital" => 20}`), else
  `default`.
  """
  def class_interval(%{class: class}, default, by_class) when is_map(by_class) do
    case Map.get(by_class, Atom.to_string(class)) do
      ut when is_number(ut) and ut > 0 -> ut * 1.0
      _ -> default * 1.0
    end
  end

  def class_interval(_ship, default, _by_class), do: default * 1.0

  @doc "Game time `yard` takes over every ship of `slots`, one after the other."
  def build_ut(yard, slots, ships, interval, pace) do
    slots |> Enum.map(fn {_tile, key} -> ship_ut(yard, Map.fetch!(ships, key), interval, pace) end) |> Enum.sum()
  end

  # --- posts -------------------------------------------------------------------

  @doc """
  Where the next defense fleet stands. `border` and `core` are the ids of the
  Rebellion's systems in its border and inner sectors, best post first;
  `posted` lists the posts of the defenders already out. `border_share` of the
  defenders belong on the border and the rest inside, and within a list the
  post with the fewest defenders wins, the better post among equals, so every
  post has one fleet before any has two. An empty list falls back to the other.
  """
  def defense_post(posted, border, core, border_share)
      when is_list(posted) and is_list(border) and is_list(core) and is_number(border_share) do
    on_border = Enum.count(posted, &(&1 in border))
    to_border? = on_border < (length(posted) + 1) * border_share - 1.0e-9

    cond do
      border == [] and core == [] -> nil
      core == [] -> emptiest(border, posted)
      border == [] -> emptiest(core, posted)
      to_border? -> emptiest(border, posted)
      true -> emptiest(core, posted)
    end
  end

  defp emptiest(posts, posted) do
    garrison = Enum.frequencies(posted)

    posts
    |> Enum.with_index()
    |> Enum.min_by(fn {post, index} -> {Map.get(garrison, post, 0), index} end)
    |> elem(0)
  end

  @doc """
  The Rebellion's systems ranked as posts, as ids: shipyards first (they are
  what a raid comes for, and where a mauled garrison refits), then the most
  productive. `systems` are the player's system summaries.
  """
  def rank_posts(systems, yard_ids) do
    systems
    |> Enum.sort_by(fn system ->
      {if(MapSet.member?(yard_ids, system.id), do: 0, else: 1), -(Map.get(system, :production) || 0.0), system.id}
    end)
    |> Enum.map(& &1.id)
  end

  @doc """
  The share of its design a fleet is missing, from the ships it holds.
  """
  def missing_share(slots, filled) when is_list(slots) and slots != [] and is_integer(filled),
    do: max(length(slots) - filled, 0) / length(slots)

  def missing_share(_slots, _filled), do: 0.0
end
