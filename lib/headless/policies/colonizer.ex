defmodule Headless.Policies.Colonizer do
  @moduledoc """
  The colonization-race policy: the full loop the design doc calls the
  "complete" validation target (docs/game-ai.md). Composes HomeDev's economy
  with the expansion pipeline:

    tech (university) → :citadel → :shipyard_1 + :transport_1 patents
    ideology (ideo_open) → :agent doctrine → deploy admiral
                         → :system_1 doctrine (+policy slot) → free slot
    shipyard building → order :transport_1 into the admiral's army
    pick nearest uninhabited system → queue jump + colonization

  Every stage is expressed as "what's missing right now" against the fresh
  view, so refusals and the engine's silent action-queue swallows self-heal:
  a stage simply fires again next decision until its postcondition holds.
  `mem.dispatched` remembers the current mission target to avoid re-queueing
  while the admiral is en route.
  """

  @behaviour Headless.Bot.Policy

  alias Headless.Policies.HomeDev

  # Economy patents always; the transport patent only once a Navarch is
  # secured — it's useless without one, and buying it early starves the
  # technology needed to HIRE one (market Navarchs carry a tech cost).
  # NOTE (verified in ship-fast.ex): the colony ship needs NO shipyard —
  # it's the only ship class ungated by shipyard buildings.
  @economy_patents [citadel: 50, infra_open_1: 400]
  @military_patents [transport_1: 600]

  # Target scoring: strength (Σ body prod/sci/appeal factors) minus a
  # distance penalty. A Phase-2 genome knob — 0 = "nearest", large = "best
  # anywhere". NOTE: candidate scoring currently reads unscouted systems'
  # states (omniscient, like most shipped 4X AI); real scouting is the
  # fair-play version, later.
  @distance_weight 0.5

  # Economy priority with the shipyard inserted (same tuple shape as
  # HomeDev.@builds: {key, biome, patent, uniqueness, tile_kind, cost}).
  @builds [
    {:infra_open, :open, :infra_open_1, :unique_body, :infrastructure, 12_000},
    {:university_open, :open, nil, :unique_body, :normal, 3360},
    {:factory_orbital, :orbital, :infra_open_1, :none, :normal, 5040},
    {:ideo_open, :open, :citadel, :unique_body, :normal, 3360},
    {:infra_dome, :dome, :infra_open_1, :unique_body, :infrastructure, 15_000},
    {:mine_dome, :dome, :infra_open_1, :none, :normal, 3360},
    {:hab_open_poor, :open, nil, :none, :normal, 2900}
  ]

  @impl true
  def init(_ctx), do: %{dispatched: nil, target_scores: nil, blocks: %{}, market_sample: nil}

  @impl true
  def decide(view, mem) do
    {mission, mem} = mission_actions(view, mem)
    {admiral, mem} = admiral_actions(view, mem)

    actions =
      HomeDev.patent_actions(view.player, patent_plan(view)) ++
        doctrine_actions(view) ++
        admiral ++
        ship_actions(view) ++
        economy_actions(view) ++
        mission

    {actions, mem}
  end

  # Priority inversion guard: continuous building spends credit down to the
  # floor (6k), which sits just BELOW what a market hire needs (floor +
  # ~1.4k Navarch cost) — so the hire loses the race forever. While a
  # Navarch is pending, raise the construction floor by a hire reservation
  # so credit accumulates past the hire threshold; the economy keeps
  # growing (a full freeze starves income and deadlocks the other way —
  # base upkeep drains an idle home below the hire price).
  defp economy_actions(view) do
    floor_bonus =
      if view.player.max_admirals.value > 0 and not navarch_secured?(view),
        do: 2_500,
        else: 0

    HomeDev.economy_actions(view, @builds, floor_bonus)
  end

  # Diagnostic: tally why a pipeline stage declined, so a single game's
  # stats explain a stall (read back via bot policy_mem).
  defp block(mem, reason), do: %{mem | blocks: Map.update(mem.blocks, reason, 1, &(&1 + 1))}

  defp patent_plan(view) do
    if navarch_secured?(view),
      do: @economy_patents ++ @military_patents,
      else: @economy_patents
  end

  defp navarch_secured?(view) do
    admiral_on_board?(view) or deck_admiral(view.player) != nil
  end

  # --- doctrines / lex ------------------------------------------------------

  # :agent (+1 admiral, 50 ideo) then :system_1 (+1 system, 1200 ideo), each
  # purchased then ACTIVATED into a policy slot (bonuses only apply when
  # active). When both are purchased but slots are short, buy a slot.
  # Sequencing matters: after :agent is active, HOLD ideology until the
  # Navarch is actually secured — market hires carry an ideology cost, and
  # buying :system_1 first pins ideology at zero, silently filtering every
  # market candidate (the myrmezir stall, round two). The expansion lex is
  # useless without a Navarch to carry the colony ship anyway.
  defp doctrine_actions(view) do
    player = view.player
    ideo = player.ideology.value
    owned = player.doctrines
    active = player.policies

    cond do
      :agent not in owned and ideo >= 50 ->
        [{:purchase_doctrine, :agent}]

      :agent in owned and :agent not in active and length(active) < player.max_policies ->
        [{:update_policies, Enum.uniq(active ++ [:agent])}]

      not navarch_secured?(view) ->
        []

      :system_1 not in owned and :agent in active and ideo >= 1200 ->
        [{:purchase_doctrine, :system_1}]

      :system_1 in owned and :system_1 not in active and length(active) < player.max_policies ->
        [{:update_policies, Enum.uniq(active ++ [:system_1])}]

      :system_1 in owned and :system_1 not in active ->
        [{:purchase_policy_slot}]

      true ->
        []
    end
  end

  # --- admiral ---------------------------------------------------------------

  # Deploy an admiral: from the deck if we have one (tetrarchy's starting
  # character is an admiral), otherwise hire the cheapest one off the market
  # (other factions start with different character types).
  defp admiral_actions(view, mem) do
    player = view.player

    cond do
      player.max_admirals.value < 1 ->
        {[], block(mem, :hire_no_admiral_slot)}

      admiral_on_board?(view) ->
        {[], mem}

      admiral = deck_admiral(player) ->
        [%{id: home_id} | _] = player.stellar_systems
        {[{:activate_character, admiral.character.id, :on_board, home_id}], mem}

      admiral = market_admiral(view) ->
        # Keep a small wage buffer after the hire (a briefly-unpaid Navarch
        # strikes but recovers; a never-hired one loses the game). Credit-poor
        # starts (myrmezir) hover just below the full 6k floor forever, so the
        # hire uses a laxer reserve than construction. Phase-2 genome knob.
        if view.player.credit.value - Map.get(admiral, :credit_cost, 0) >= 3_000,
          do: {[{:hire_character, admiral.id}], mem},
          else: {[], block(mem, :hire_wage_buffer)}

      true ->
        {[], mem |> block(:hire_no_candidate) |> capture_market_sample(view)}
    end
  end

  # One-shot diagnostic: when no market candidate qualifies, remember what
  # the market actually offered so the filter can be checked against reality.
  defp capture_market_sample(%{market_sample: nil} = mem, view) do
    sample =
      case view.market do
        %{slots: slots} ->
          slots
          |> Enum.flat_map(& &1.data)
          |> Enum.flat_map(& &1.data)
          |> Enum.map(& &1.character)
          |> Enum.reject(&is_nil/1)
          |> Enum.take(3)
          |> Enum.map(&Map.take(Map.from_struct(&1), [:id, :type, :credit_cost, :technology_cost, :ideology_cost]))

        _ ->
          :no_market
      end

    %{mem | market_sample: sample}
  end

  defp capture_market_sample(mem, _view), do: mem

  defp market_admiral(%{market: nil}), do: nil

  defp market_admiral(view) do
    player = view.player

    view.market.slots
    |> Enum.flat_map(& &1.data)
    |> Enum.flat_map(& &1.data)
    |> Enum.map(& &1.character)
    |> Enum.reject(&is_nil/1)
    |> Enum.filter(fn c ->
      c.type == :admiral and
        Map.get(c, :credit_cost, 0) <= player.credit.value and
        Map.get(c, :technology_cost, 0) <= player.technology.value and
        Map.get(c, :ideology_cost, 0) <= player.ideology.value
    end)
    |> Enum.min_by(&Map.get(&1, :credit_cost, 0), fn -> nil end)
  end

  defp deck_admiral(player) do
    Enum.find(player.character_deck, fn
      %{character: %{type: :admiral}, cooldown: nil} -> true
      _ -> false
    end)
  end

  defp admiral_on_board?(view), do: on_board_admiral(view) != nil

  defp on_board_admiral(view) do
    view.characters
    |> Map.values()
    |> Enum.find(fn c -> c.type == :admiral end)
  end

  # --- colony ship -------------------------------------------------------------

  # Order one :transport_1 into the admiral's army when: admiral deployed,
  # no transport present/ordered, home queue idle (ships share the system
  # production queue), and the home system has a shipyard built.
  # Verified transport_1 costs (ship-fast.ex): 12k credit, 2k technology,
  # 6.3k production — the priciest early purchase in the loop, and the only
  # ship needing NO shipyard.
  @transport_credit 12_000
  @transport_tech 2_000
  @credit_floor 6_000

  defp ship_actions(view) do
    with true <- view.player.credit.value >= @transport_credit + @credit_floor,
         true <- view.player.technology.value >= @transport_tech,
         admiral when admiral != nil <- on_board_admiral(view),
         false <- transport_pending?(admiral),
         [%{id: home_id} | _] <- view.player.stellar_systems,
         home when home != nil <- view.systems[home_id],
         true <- HomeDev.queue_idle?(home),
         tile when tile != nil <- free_army_tile(admiral) do
      [{:order_ship, home_id, admiral.id, tile.id, :transport_1}]
    else
      _ -> []
    end
  end

  # A BUILT transport — a planned-but-unconstructed ship occupies the tile
  # (so ordering is correctly deduped) but fails colonization's
  # has_colonization_ship check, causing dispatch→fail→re-dispatch loops.
  defp has_transport?(admiral) do
    Enum.any?(admiral.army.tiles, fn tile ->
      tile.ship != nil and tile.ship.key == :transport_1 and Map.get(tile, :ship_status) == :filled
    end)
  end

  defp transport_pending?(admiral) do
    Enum.any?(admiral.army.tiles, fn tile -> tile.ship != nil and tile.ship.key == :transport_1 end)
  end

  defp free_army_tile(admiral), do: Enum.find(admiral.army.tiles, &(&1.ship == nil))

  # --- the mission ----------------------------------------------------------------

  # Dispatch when everything is staged: admiral deployed with a built
  # transport, an empty action queue, and a free system slot. Re-dispatches
  # if a previous attempt was silently swallowed (queue empty again while the
  # target is still unowned).
  # Dispatch when everything is staged AND the admiral is truly idle. The
  # action QUEUE being empty is not enough — the currently-executing action
  # lives in `action_status`, and gating on the queue alone re-queued the
  # mission every decision (40+ stacked jumps per game).
  defp mission_actions(view, mem) do
    player = view.player
    admiral = on_board_admiral(view)

    cond do
      admiral == nil ->
        {[], block(mem, :no_admiral)}

      not has_transport?(admiral) ->
        {[], block(mem, :no_transport)}

      admiral.action_status != :idle ->
        {[], block(mem, {:busy, admiral.action_status})}

      not queue_empty?(admiral) ->
        {[], block(mem, :queue_not_empty)}

      length(player.stellar_systems) >= player.max_systems.value ->
        {[], block(mem, :no_system_slot)}

      true ->
        mem = ensure_target_scores(view, mem)

        case pick_target(view, mem) do
          nil ->
            {[], block(mem, :no_target)}

          target ->
            case path_hops(view, admiral.system, target) do
              nil ->
                # Unreachable through the lane graph — drop it and let the
                # next decision pick the runner-up.
                {[], mem |> block(:no_path) |> drop_target(target)}

              hops ->
                {[{:queue_mission, admiral.id, hops, target}], %{mem | dispatched: target}}
            end
        end
    end
  end

  defp drop_target(mem, target), do: %{mem | target_scores: Map.delete(mem.target_scores, target)}

  defp path_hops(view, from, to), do: Headless.Bot.Nav.path_hops(view.galaxy, from, to)

  defp queue_empty?(admiral), do: match?(%{queue: %{q: {[], []}}}, admiral.actions)

  # Score every candidate system ONCE (full state reads are the expensive
  # part) and cache in policy memory; the per-decision pick re-checks only
  # cheap facts (still uninhabited, distance from the admiral).
  defp ensure_target_scores(view, %{target_scores: nil} = mem) do
    scores =
      view.galaxy.stellar_systems
      |> Enum.filter(&(&1.status == :uninhabited))
      |> Enum.filter(&takeable?(view, &1.id))
      |> Map.new(fn s -> {s.id, system_strength(view, s.id)} end)

    %{mem | target_scores: scores}
  end

  # The engine's claim rule (own sector or adjacent-owned sector) — same
  # check the colonization action enforces; public game knowledge.
  defp takeable?(view, system_id) do
    case Game.call(view.instance_id, :galaxy, :master, {:check_system_takeability, system_id, view.player.faction}) do
      {:ok, :takeable} -> true
      _ -> false
    end
  end

  defp ensure_target_scores(_view, mem), do: mem

  defp pick_target(view, mem) do
    systems = view.galaxy.stellar_systems
    here = Enum.find(systems, fn s -> s.id == admiral_system_id(view) end)

    if here do
      systems
      # Only candidates that were scored (uninhabited AND takeable at scan
      # time), re-checked for status now.
      |> Enum.filter(fn s -> s.status == :uninhabited and Map.has_key?(mem.target_scores, s.id) end)
      |> Enum.map(fn s ->
        strength = Map.get(mem.target_scores, s.id, 0)
        {s.id, strength - @distance_weight * :math.sqrt(dist2(s.position, here.position))}
      end)
      |> Enum.max_by(fn {_id, score} -> score end, fn -> nil end)
      |> case do
        {id, _score} -> id
        nil -> nil
      end
    end
  end

  defp system_strength(view, system_id) do
    case Game.call(view.instance_id, :stellar_system, system_id, :get_state) do
      {:ok, system} ->
        system.bodies
        |> HomeDev.flatten_bodies()
        |> Enum.map(fn body ->
          Map.get(body, :industrial_factor, 0) + Map.get(body, :technological_factor, 0) +
            Map.get(body, :activity_factor, 0)
        end)
        |> Enum.sum()

      _ ->
        0
    end
  end

  defp admiral_system_id(view) do
    case on_board_admiral(view) do
      nil -> nil
      admiral -> admiral.system
    end
  end

  defp dist2(%{x: x1, y: y1}, %{x: x2, y: y2}), do: (x1 - x2) * (x1 - x2) + (y1 - y2) * (y1 - y2)
  defp dist2(_, _), do: 1.0e12
end
