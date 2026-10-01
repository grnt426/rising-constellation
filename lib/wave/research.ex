defmodule Wave.Research do
  @moduledoc """
  What the Rebellion researches: which patents and lexes it buys, and which
  lexes it enacts. Pure — `Wave.Warlord.Agent` reads the catalogs and the
  players and sends the purchases through the player agent, so the engine
  prices and validates each one like a human's.

  ## Patents

  A patent can only be bought once its one ancestor is owned
  (`Instance.Player.Player.purchase_patent/2`), so every plan here lists
  ancestors first.

    * **Starter set** (`starter_patents/2`): the tree's roots, then for each
      building branch the first few patents a player can afford — the cheapest
      one on offer, again and again. Given once, at the first research pass.
    * **Ship patents** (`ship_patents/2`): whatever the humans hold in the
      ship branch. The Rebellion copies them rather than choosing.
    * **Building patents** (`building_pool/2`): everything else on offer; the
      agent picks one at random.

  Rebel systems are run by the system AI, which builds without consulting
  patents, so a building patent changes nothing the Rebellion builds today.

  ## Lexes

  A lex does nothing until enacted, and a penalty only bites while enacted. So
  the Rebellion may own a penalised lex — it has to, to reach the lexes behind
  one — but never enacts it:

    * **Targets** (`lex_targets/2`): unowned lexes worth wanting, which is
      every lex without a penalty plus the whole expansion branch.
    * **Next step** (`next_step/3`): the first unowned lex on the way from the
      root to a target. Penalised lexes are bought only as such steps.
    * **Enactment** (`enactable/4`): the lexes named in the `lex_always` knob
      first, then the other clean ones, strongest (dearest) first, with lexes
      that only raise caps the Rebellion already bypasses last.
  """

  # A negative bonus on these is the benefit, not the penalty.
  @lower_is_better [:army_maintenance]

  # Caps Wave.Config.player_bonuses/1 already lifts for the bot.
  @caps [:player_system, :player_dominion, :player_admiral, :player_spy, :player_speaker]

  @ship_class :ship
  @root_class :root
  @expansion_class :expansion

  # --- trees ----------------------------------------------------------------------

  @doc "Keys from the root down to `key` (inclusive); `[]` for an unknown key."
  def path(nodes, key) do
    by_key = Map.new(nodes, &{&1.key, &1})
    climb(by_key, key, [])
  end

  defp climb(_by_key, nil, acc), do: acc

  defp climb(by_key, key, acc) do
    case Map.get(by_key, key) do
      nil -> []
      # A cycle in the content would loop forever; a tree never revisits a key.
      node -> if key in acc, do: acc, else: climb(by_key, node.ancestor, [key | acc])
    end
  end

  @doc """
  `wanted` and every ancestor they need, without what is `owned`, in an order
  the engine accepts: each key after its ancestor.
  """
  def purchase_plan(nodes, wanted, owned) do
    wanted
    |> Enum.flat_map(&path(nodes, &1))
    |> Enum.uniq()
    |> Enum.reject(&(&1 in owned))
  end

  # --- patents --------------------------------------------------------------------

  @doc """
  The starter set: the roots, then per branch in `quotas` (`%{class => count}`)
  the `count` patents a player reaches first by always taking the cheapest one
  on offer. A fixed list for a given catalog — what is already owned plays no
  part — so a half-finished grant resumes on the same patents.
  """
  def starter_patents(patents, quotas) when is_map(quotas) do
    indexed = Enum.with_index(patents)
    roots = for p <- patents, p.ancestor == nil, do: p.key

    patents
    |> Enum.map(& &1.class)
    |> Enum.uniq()
    |> Enum.reduce(roots, fn class, plan -> take_cheapest(indexed, class, Map.get(quotas, class, 0), plan) end)
  end

  defp take_cheapest(_indexed, _class, count, plan) when count <= 0, do: plan

  defp take_cheapest(indexed, class, count, plan) do
    indexed
    |> Enum.filter(fn {p, _index} -> p.class == class and p.key not in plan and p.ancestor in plan end)
    |> Enum.min_by(fn {p, index} -> {p.cost, index} end, fn -> nil end)
    |> case do
      nil -> plan
      {p, _index} -> take_cheapest(indexed, class, count - 1, plan ++ [p.key])
    end
  end

  @doc "The ship-branch patents any rival holds. `rivals` is one patent list per player."
  def ship_patents(patents, rivals) do
    ship = for p <- patents, p.class == @ship_class, into: MapSet.new(), do: p.key

    rivals
    |> List.flatten()
    |> Enum.uniq()
    |> Enum.filter(&MapSet.member?(ship, &1))
  end

  @doc "Building patents on offer: outside the ship branch, unowned, ancestor owned."
  def building_pool(patents, owned) do
    for p <- patents,
        p.class not in [@ship_class, @root_class],
        p.key not in owned,
        p.ancestor == nil or p.ancestor in owned,
        do: p.key
  end

  # --- lexes ----------------------------------------------------------------------

  @doc "True when enacting the lex costs something: a negative bonus, upkeep cuts aside."
  def penalised?(%{bonus: bonuses}), do: Enum.any?(bonuses, &penalty?/1)

  defp penalty?(%{value: value, to: to}) when is_number(value), do: value < 0 and to not in @lower_is_better
  defp penalty?(_bonus), do: false

  @doc "True when every bonus of the lex raises a cap the bot already bypasses."
  def cap_only?(%{bonus: []}), do: false
  def cap_only?(%{bonus: bonuses}), do: Enum.all?(bonuses, &(&1.to in @caps))

  @doc "Unowned lexes worth wanting: the ones without a penalty, plus the expansion branch."
  def lex_targets(lexes, owned) do
    for d <- lexes, d.key not in owned, d.class == @expansion_class or not penalised?(d), do: d.key
  end

  @doc "The first unowned lex on the way from the root to `target`, or nil."
  def next_step(lexes, target, owned) do
    lexes |> purchase_plan([target], owned) |> List.first()
  end

  @doc """
  The owned lexes the Rebellion would enact, best first: `always` in its own
  order, then the rest by price, with cap-only lexes last. A penalised lex is
  left out unless it is in `always`, or in the expansion branch with
  `expansion_penalties?` on.
  """
  def enactable(lexes, owned, always, expansion_penalties? \\ false) do
    named = Enum.filter(always, &(&1 in owned))

    rest =
      lexes
      |> Enum.with_index()
      |> Enum.filter(fn {d, _index} ->
        d.key in owned and d.key not in named and
          (not penalised?(d) or (expansion_penalties? and d.class == @expansion_class))
      end)
      |> Enum.sort_by(fn {d, index} -> {cap_only?(d), -d.cost, index} end)
      |> Enum.map(fn {d, _index} -> d.key end)

    named ++ rest
  end

  @doc """
  Lex slots worth holding: one per enactable lex, but no more than the best
  rival has — except that the `always` lexes get a slot each regardless.
  """
  def slots_wanted(enactable_count, always_count, rival_slots),
    do: min(enactable_count, max(rival_slots, always_count))
end
