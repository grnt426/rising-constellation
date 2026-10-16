defmodule Wave.Sortie do
  @moduledoc """
  What the Rebellion's fleets do once they stand ready: which fleet strikes
  how, what it may strike, where it goes and when the trip is over.

  Pure, like `Wave.Fleet`: `Wave.Warlord.Agent` reads the galaxy and gives the
  orders.

  ## Who strikes

  | role | action | rolls | against |
  |---|---|---|---|
  | `:raid` | `loot` (pillage) | the fleet's raid strength | the system's defense |
  | `:siege` | `raid` (bombardment) | the fleet's raid strength | the system's defense |
  | `:conquest` | `conquest` (invasion) | the fleet's invasion strength | the system's defense |

  A `:screen` fleet strikes nothing. It walks beside a siege or a conquest
  fleet and stands in the target with it: the engine pulls a fleet's present
  faction-mates into any battle fought there, so the screen's Fury meets
  whatever comes to break the siege. A `:defense` fleet never leaves its post.

  ## What may be struck

  Systems and dominions another faction holds. An invasion is only legal in a
  sector the Rebellion owns or one next to it, which is the engine's own rule
  (`Instance.Galaxy.Galaxy.check_system_takeability/3`), and only for a fleet
  that carries troops. One striking fleet works a system at a time: the engine
  refuses a second siege. And a fleet does not strike the system it last
  struck again until `fleet_sortie_rest_ut` has passed, so one standing in a
  system it has just pillaged moves on.

  The Rebellion does not invade a player's last system
  (`fleet_conquest_spare_last`): taking it would put that player out of the
  match. It may still be pillaged and bombarded, and a player's dominions and
  other systems may be taken.

  ## Where it goes

  The target is drawn by weight among the systems in reach (`weight/2`), after
  the ones the Rebellion has leaned on lately are thinned out
  (`Wave.Pressure`): bigger systems, nearer ones and the sectors nearest rebel
  space draw more. Then the fleet weighs the one it drew, the way a remover
  weighs a victim (`Wave.Intel.attempt_chance/2`): a defense it can read gives
  it its odds, one it cannot is a gamble, and a garrison it can see and cannot
  match sends it elsewhere.
  """

  alias Wave.{Draw, Fleet}

  @actions %{raid: "loot", siege: "raid", conquest: "conquest"}

  @doc "The action a fleet of `role` strikes with, or nil for a role that does not strike."
  def action(role), do: Map.get(@actions, role)

  @doc "True for the roles that strike a system."
  def striker?(role), do: Map.has_key?(@actions, role)

  @doc "True for the role that covers a striking fleet."
  def escort?(role), do: role == :screen

  @doc "True for the roles a screen walks with: sieges and invasions, which hold a system for a long time."
  defdelegate escorted?(role), to: Fleet

  @doc """
  The strength a fleet of `role` strikes with, read off its Navarch as the
  player's roster shows it: invasion for a conquest fleet, raid for the rest.
  """
  def attack(:conquest, navarch), do: strength(Map.get(navarch, :army_invasion))
  def attack(role, navarch) when is_map_key(@actions, role), do: strength(Map.get(navarch, :army_raid))
  def attack(_role, _navarch), do: 0.0

  defp strength(value) when is_number(value) and value > 0, do: value * 1.0
  defp strength(_value), do: 0.0

  @doc """
  True when a fleet is fit to set out: it holds ships, and has lost less than
  `refit_share` of its design. A fleet past that walks to a yard instead.
  """
  def fit?(slots, filled, refit_share) when is_integer(filled) and is_number(refit_share),
    do: filled > 0 and Fleet.missing_share(slots, filled) < refit_share

  def fit?(_slots, _filled, _refit_share), do: false

  @doc """
  True when a fleet of `role` with `attack` strength may strike a system.
  `takeable?` says whether the system lies in a sector the Rebellion owns or
  one next to it, which is where an invasion is legal.
  """
  def legal?(role, attack, takeable?) when is_number(attack) and is_boolean(takeable?),
    do: striker?(role) and attack > 0 and (role != :conquest or takeable?)

  def legal?(_role, _attack, _takeable?), do: false

  @doc """
  How many systems each player runs, by owner name, from the galaxy's systems.
  Dominions are not counted: a player with dominions and one system is still
  down to its last system.
  """
  def holdings(systems) do
    systems
    |> Enum.filter(&(&1.status == :inhabited_player and Map.get(&1, :owner) != nil))
    |> Enum.frequencies_by(& &1.owner)
  end

  @doc """
  True when a conquest fleet must leave `system` alone because it is the last
  one its owner runs. Every other role, and every dominion, is never spared.
  """
  def spared?(:conquest, %{status: :inhabited_player} = system, holdings) when is_map(holdings),
    do: Map.get(holdings, Map.get(system, :owner), 0) <= 1

  def spared?(_role, _system, _holdings), do: false

  @doc """
  True while a fleet should leave a system alone because it struck it less
  than `rest_ut` ago. `entry` is its roster entry, whose `struck` holds the
  last system it struck and when.
  """
  def struck?(%{struck: %{target: target, at: at}}, system_id, now, rest_ut)
      when is_number(at) and is_number(now) and is_number(rest_ut),
      do: target == system_id and now - at < rest_ut

  def struck?(_entry, _system_id, _now, _rest_ut), do: false

  @doc """
  The fleet's chance of carrying its action, or nil when the Rebellion cannot
  read the system's defense. The engine rolls strength against defense with
  the Navarch's level, as for every other action.
  """
  def chance(_attack, _level, nil), do: nil

  def chance(attack, level, defense) when is_number(attack) and is_number(defense),
    do: Wave.Intel.success_chance(attack, level || 1, max(defense, 0.0))

  @doc """
  True when the fleets the Rebellion can see standing in a system hold more
  ships than the fleet setting out, its screen included.
  """
  def outgunned?(own_ships, garrison_ships) when is_number(own_ships) and is_number(garrison_ships),
    do: garrison_ships > own_ships

  def outgunned?(_own_ships, _garrison_ships), do: false

  @doc """
  How strongly a target draws a fleet. `target` carries `:population` (nil
  when not legible), `:depth` (its sector's distance from rebel space) and
  `:travel`; `opts` gives `:nearest_depth`, `:rear_factor` and `:reach`.

  | factor | value |
  |---|---|
  | size | 1 to 2 with the population it can see (1.5 unseen) |
  | depth | `rear_factor` per sector further back than the nearest one in reach |
  | travel | 1 next door, 0.5 at the edge of `reach` |
  """
  def weight(target, opts) do
    Draw.size(Map.get(target, :population)) *
      Draw.rear(Map.get(target, :depth), Keyword.get(opts, :nearest_depth, 0), Keyword.get(opts, :rear_factor, 0.5)) *
      Draw.nearness(Map.get(target, :travel, 0.0), Keyword.get(opts, :reach, 1440.0))
  end

  @doc """
  Draw a target by weight. `roll` is uniform in [0, 1); `opts` takes
  `:rear_factor` and `:reach`. nil when there is nothing to draw from.
  """
  def pick(targets, roll, opts \\ [])

  def pick([], _roll, _opts), do: nil

  def pick(targets, roll, opts) when is_number(roll) do
    opts = Keyword.put(opts, :nearest_depth, Draw.nearest_depth(targets))

    targets
    |> Enum.sort_by(& &1.id)
    |> Enum.map(&{&1, weight(&1, opts)})
    |> Draw.pick(roll)
  end

  # --- the roster ---------------------------------------------------------------

  @doc "The systems a striking fleet is already on its way to, or working."
  def targets(fleets) do
    for {_id, %{stage: :sortie, sortie: %{target: target} = sortie}} <- fleets,
        Map.get(sortie, :escort_of) == nil,
        into: MapSet.new(),
        do: target
  end

  @doc "The fleets covering `striker_id` on its sortie, as ids."
  def escorts(fleets, striker_id) do
    for {id, %{stage: :sortie, sortie: %{escort_of: ^striker_id}}} <- fleets, do: id
  end

  @doc """
  True when an idle fleet's sortie is over. A striker standing idle has
  finished, or lost, or was turned away. A screen standing idle has only
  arrived: its sortie lasts as long as the fleet it covers is still on the
  one they set out on together.
  """
  def finished?(%{stage: :sortie, sortie: %{escort_of: striker_id, target: target}}, fleets)
      when not is_nil(striker_id) do
    case Map.get(fleets, striker_id) do
      %{stage: :sortie, sortie: %{target: ^target}} -> false
      _ -> true
    end
  end

  def finished?(%{stage: :sortie}, _fleets), do: true
  def finished?(_entry, _fleets), do: false
end
