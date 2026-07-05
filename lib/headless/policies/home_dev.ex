defmodule Headless.Policies.HomeDev do
  @moduledoc """
  Economy-only policy: develops owned systems, never expands. The control
  arm for the colonization-race experiment, and the shared economy logic the
  Colonizer composes (`economy_actions/2`).

  Engine rules encoded here (verified against
  Instance.StellarSystem.order_building_production/2):

    * bodies are addressed by `uid`, and moons/asteroids are NESTED under
      planets (`body.bodies`) — orbital build slots live there;
    * on non-orbital bodies, tile 1 (the `:infrastructure` tile) must be
      built before any `:normal` tile — so `:infra_open`/`:infra_dome` are
      mandatory openers, not optional luxuries;
    * biome must match: habitable→:open, sterile→:dome, moon/asteroid→:orbital.

  Per decision: at most one patent purchase and one production order per
  idle system, in fixed priority (tech bootstrap first).
  """

  @behaviour Headless.Bot.Policy

  # {patent_key, technology_cost} in purchase order (citadel is the root).
  @patents [citadel: 50, infra_open_1: 400]

  # {building_key, biome, required_patent, uniqueness, tile_kind, credit_cost}
  # Credit income early (factory_orbital) or upkeep+wages outrun the
  # economy — a credit-blind opener drained myrmezir into permanent poverty.
  @builds [
    {:infra_open, :open, :infra_open_1, :unique_body, :infrastructure, 12_000},
    {:university_open, :open, nil, :unique_body, :normal, 3360},
    {:factory_orbital, :orbital, :infra_open_1, :none, :normal, 5040},
    {:ideo_open, :open, :citadel, :unique_body, :normal, 3360},
    {:infra_dome, :dome, :infra_open_1, :unique_body, :infrastructure, 15_000},
    {:mine_dome, :dome, :infra_open_1, :none, :normal, 3360},
    {:hab_open_poor, :open, nil, :none, :normal, 2900}
  ]

  # The §4 "governor" rule, learned the hard way — in BOTH directions. A
  # greedy Colonizer with no floor bankrupted itself (958 player_is_bankrupt
  # refusals; strikes are literally the bankruptcy flag propagated to
  # characters). But a HIGH floor (12k) also bankrupted players: it blocked
  # cheap INCOME buildings once credit fell near the floor, so upkeep+wages
  # slowly drained an economy that was forbidden from growing. A scalar
  # floor can't tell investment from splurge — that's what budget pools are
  # for (docs/game-ai.md §7); until then, keep the floor low.
  @credit_floor 6_000

  @impl true
  def init(_ctx), do: %{}

  @impl true
  def decide(view, mem) do
    {patent_actions(view.player, @patents) ++ economy_actions(view, @builds), mem}
  end

  # --- shared with Colonizer ---------------------------------------------

  @doc "First affordable unowned patent from `plan`, as a single-action list."
  def patent_actions(player, plan) do
    tech = player.technology.value

    plan
    |> Enum.reject(fn {key, _cost} -> key in player.patents end)
    |> Enum.filter(fn {_key, cost} -> tech >= cost end)
    |> case do
      [{key, _} | _] -> [{:purchase_patent, key}]
      [] -> []
    end
  end

  @doc """
  One production order per owned system whose queue is idle: the first plan
  entry with an owned patent and a legal free tile.
  """
  def economy_actions(view, plan, floor_bonus \\ 0) do
    player = view.player

    view.systems
    |> Enum.filter(fn {_id, system} -> queue_idle?(system) end)
    |> Enum.flat_map(fn {system_id, system} ->
      case pick_build(system, player, plan, floor_bonus) do
        {body_uid, tile_id, key} -> [{:order_building, system_id, body_uid, tile_id, key}]
        nil -> []
      end
    end)
  end

  def queue_idle?(system) do
    match?(%{queue: %{queue: %{q: {[], []}}}}, system) and not construction_in_progress?(system)
  end

  # The engine allows one production per system at a time; the queue empties
  # into the construction phase, so an empty queue alone is not "idle"
  # (:already_one_on_system refusals otherwise).
  defp construction_in_progress?(system) do
    system.bodies
    |> flatten_bodies()
    |> Enum.any?(fn body -> Enum.any?(body.tiles, &(&1.construction_status != :none)) end)
  end

  @doc "Planets plus their nested moons/asteroids, one flat list."
  def flatten_bodies(bodies) do
    Enum.flat_map(bodies, fn body -> [body | Map.get(body, :bodies, []) || []] end)
  end

  defp pick_build(system, player, plan, floor_bonus) do
    bodies = flatten_bodies(system.bodies)
    credit = player.credit.value

    Enum.find_value(plan, fn {key, biome, patent, limit, tile_kind, cost} ->
      with true <- patent == nil or patent in player.patents,
           true <- credit >= cost + @credit_floor + floor_bonus,
           false <- limit == :unique_system and system_has?(bodies, key),
           {body, tile} when body != nil <- find_slot(bodies, biome, key, limit, tile_kind) do
        {body.uid, tile.id, key}
      else
        _ -> nil
      end
    end)
  end

  defp system_has?(bodies, key), do: Enum.any?(bodies, &has_building?(&1, key))

  @doc """
  A legal `{body, tile}` for `key`, or `{nil, nil}`. Public: the opener
  book (Headless.Bot.Opener) places its forced-opening buildings through
  the exact same slot rules the economy stages use.
  """
  def find_slot(bodies, biome, key, limit, tile_kind) do
    bodies
    |> Enum.filter(fn body -> biome(body.type) == biome end)
    |> Enum.reject(fn body -> limit == :unique_body and has_building?(body, key) end)
    |> Enum.find_value({nil, nil}, fn body ->
      case eligible_tile(body, biome, tile_kind) do
        nil -> nil
        tile -> {body, tile}
      end
    end)
  end

  # Infrastructure builds target the :infrastructure tile; normal builds
  # need a free :normal tile AND (on non-orbital bodies) a built tile 1.
  defp eligible_tile(body, biome, :infrastructure) do
    Enum.find(body.tiles, fn t -> t.type == :infrastructure and free?(t) end)
  end

  defp eligible_tile(body, biome, :normal) do
    infra_ready? = biome == :orbital or not free_infra_tile?(body)

    if infra_ready? do
      Enum.find(body.tiles, fn t -> t.type == :normal and free?(t) end)
    end
  end

  defp free_infra_tile?(body) do
    case Enum.find(body.tiles, &(&1.id == 1)) do
      %{building_status: :empty} -> true
      _ -> false
    end
  end

  defp free?(tile), do: tile.building_status == :empty and tile.construction_status == :none

  @doc "Built, ordered, or under construction — the 'present' predicate."
  def has_building?(body, key),
    do: Enum.any?(body.tiles, &(&1.building_key == key or match?(%{construction_key: ^key}, &1)))

  # Body-type → biome, per Game.SystemAI.Helper.body_type_to_biome_key/1.
  def biome(:habitable_planet), do: :open
  def biome(:sterile_planet), do: :dome
  def biome(:moon), do: :orbital
  def biome(:asteroid), do: :orbital
  def biome(_), do: :unknown
end
