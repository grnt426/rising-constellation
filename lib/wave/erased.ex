defmodule Wave.Erased do
  @moduledoc """
  The Rebellion's Erased: who they are, where they serve, and what they strike.

  Pure decisions only — `Wave.Recon` gathers the readings, `Wave.Warlord.Agent`
  gives the orders, and everything in between lives here so it can be tested
  without an instance.

  ## Theatres

  Every Erased serves in one of two theatres, rolled once when it is hired and
  never re-rolled except by graduation:

    * `:home` — a minority (`erased_home_share`, 20–30%) that never leaves the
      sectors the Rebellion owns. It hunts enemy agents standing in rebel
      space, sabotages fleets operating there — sieges first — and, while it
      is too green for either, trains by infiltrating the neutral systems
      inside its own borders.
    * `:field` — the rest, who work the border and enemy sectors: infiltrating
      enemy systems and dominions, removing enemy agents, and sabotaging
      enemy fleets.

  A third theatre, `:forward`, is never rolled: it is a posting a few field
  informers are given (see "Forward postings").

  ## Duties

  A duty is the standing job an Erased looks for work under:

  | duty | action | target |
  |---|---|---|
  | `:removal` | `assassination` | an enemy character in reach |
  | `:sabotage` | `sabotage` | an enemy Navarch with a fleet worth breaking |
  | `:infiltration` | `infiltrate` | an enemy system or dominion |
  | `:training` | `infiltrate` | a neutral system inside rebel space |

  Duties are rolled against the theatre's weights, each weight scaled by the
  points the agent actually holds in that skill, so a saboteur is rarely asked
  to assassinate. `:training` is a home-only duty and is only ever handed to an
  agent with fewer than `erased_home_duty_points` (2) points across removal and
  sabotage.

  ## Graduation

  A trainee stops training once its informer skill reaches a target rolled per
  agent in `erased_train_points` (3–6). It then takes a permanent posting: a
  roll on `erased_graduate_home_share` sends it to home removal/sabotage work,
  anything else to the field. That home roll is only offered to an agent
  holding at least `erased_home_duty_points` between removal and sabotage —
  the Rebellion does not keep a useless killer at home.

  ## Restraint

  Three rules keep the Erased from piling on:

    * **Slots** — at most `erased_target_cap` Erased work one target at a time
      (`erased_home_target_cap` in rebel space), and each extra one joins with
      probability `erased_overlap_falloff^n`, so a second is uncommon and a
      third rare. A slot frees the moment its holder is removed or seduced
      away, because commitments are read off the live roster.
    * **Odds** — removal is the one action that can be thrown away on a single
      roll, so an agent weighs it: an unreadable defence is a flat 20% gamble,
      a readable one runs through `Wave.Intel.attempt_chance/2`.
    * **Worth** — sabotage ignores fleets already broken below
      `erased_sabotage_min_tiles` (6 in the field, 4 at home, where a wounded
      fleet is still a fleet standing on our ground), unless the fleet carries
      a colony ship, which is worth stopping at any size.

  And two the spec calls out by name: a replacement officer (`CMO`) is left
  alone until it has earned a level, and nothing infiltrates a system the
  Rebellion can already see in full.

  ## Between strikes

  An Erased whose duty has nothing to strike does not stand still. Below
  `erased_train_max_level` it trains, the way players train theirs:

    * **Infiltration practice** on neutral systems and other factions'
      dominions in its theatre. A system's Intelligence is only known once one
      of our infiltrations there has reported it, so practice goes anywhere
      until a system is known to be soft, then prefers the known-soft ones and
      skips the known-hopeless ones (`erased_train_min_chance`). An agent with
      no informer points can still infiltrate: the roll is 0 against the
      Intelligence, which wins about half the time against 0 and never
      against anything more, and every attempt pays some experience.
    * **Sabotage practice** for an agent with sabotage points but no informer
      points: it sabotages the Rebellion's own training Navarch, the loop teams
      run between two teammates, when that Navarch is within
      `erased_dummy_max_travel_ut` of travel.

  At the level cap, or with nothing to practise on, it scouts: it walks to the
  nearest system the Rebellion has never seen, which is what players do with
  their first agents. Everything seen, it waits.

  ## Forward postings

  The field theatre stops `erased_field_depth` sectors out, and for most of a
  match the humans are much further away than that. Players do not wait for
  the fronts to meet: they send a few Erased ahead to watch the enemy's
  advance, and a few more behind the lines to collect Shadows points where
  nobody has built Intelligence. The Rebellion does the same with two
  postings, both infiltration only, both for life:

  | duty | works | order |
  |---|---|---|
  | `:scout` | every system and dominion the humans hold | the edge nearest rebel space first, then inwards |
  | `:deep` | the same ground | the sector furthest from rebel space first, then outwards |

  The quotas scale with the humans faced (`erased_scouts_per_player`,
  `erased_deep_per_player`) and together never take more than
  `erased_forward_max_share` of the roster. They are filled from idle field
  agents holding at least `erased_forward_min_points` informer points, the
  strongest informer first and scouts before deep infiltrators, because the
  border is where the humans' Intelligence is. A posting lost with its agent
  is refilled the same way.

  Neither posting weighs the Visibility track: the humans answer it with
  Intelligence, which is the point of sending them.
  """

  # Spy specialization indices, from Data.Game.Content.Character.
  @informer 0
  @assassin 1
  @saboteur 2

  @doc "The spy skill points that matter, by role."
  def skill_points(skills) when is_list(skills) do
    %{
      infiltration: Enum.at(skills, @informer, 0) || 0,
      removal: Enum.at(skills, @assassin, 0) || 0,
      sabotage: Enum.at(skills, @saboteur, 0) || 0
    }
  end

  def skill_points(_skills), do: %{infiltration: 0, removal: 0, sabotage: 0}

  @doc """
  An Erased's strength in one action, from its skill points and the spy
  `specializations` table: the `:spy_infiltrate` / `:spy_assassination` /
  `:spy_sabotage` bonus its points grant. An agent at zero across all three
  can never win a roll and is not worth a roster slot.
  """
  def strength(skills, specializations, key) when is_list(skills) and is_list(specializations) do
    for %{index: index, bonus: bonuses} <- specializations,
        %{to: ^key, type: :add, value: value} <- bonuses,
        reduce: 0 do
      acc -> acc + value * (Enum.at(skills, index, 0) || 0)
    end
  end

  def strength(_skills, _specializations, _key), do: 0

  @doc "Total strength across the three offensive actions — the hiring score."
  def offensive_strength(skills, specializations) do
    [:spy_infiltrate, :spy_assassination, :spy_sabotage]
    |> Enum.map(&strength(skills, specializations, &1))
    |> Enum.sum()
  end

  # --- postings ---------------------------------------------------------------

  @doc "Roll a theatre: `:home` with probability `share`, else `:field`."
  def theatre(roll, share) when is_number(roll) and is_number(share),
    do: if(roll < share, do: :home, else: :field)

  @doc """
  True when an agent is fit for home removal/sabotage work: at least
  `min_points` across its removal and sabotage skills. Gates both the initial
  home posting and the graduation roll.
  """
  def fit_for_home_duty?(skills, min_points) do
    points = skill_points(skills)
    points.removal + points.sabotage >= min_points
  end

  @doc """
  Roll a duty from `weights` (`%{duty => weight}`), each weight scaled by
  `1 + points` for that duty, so an agent is steered toward what it is good at
  without ever being locked out of a job. `roll` is uniform in [0, 1).
  """
  def duty(roll, weights, skills) do
    points = skill_points(skills)

    scaled =
      weights
      |> Enum.map(fn {duty, weight} -> {duty, weight * (1 + Map.get(points, duty, 0))} end)
      |> Enum.filter(fn {_duty, weight} -> weight > 0 end)
      |> Enum.sort()

    case scaled do
      [] -> :infiltration
      _ -> weighted_pick(scaled, roll)
    end
  end

  @doc "The informer points a trainee must reach before it graduates: `roll` over `lo..hi`."
  def train_target(roll, lo, hi) when is_number(roll) and is_integer(lo) and is_integer(hi) and hi >= lo,
    do: (lo + trunc(roll * (hi - lo + 1))) |> min(hi)

  def train_target(_roll, lo, _hi), do: lo

  @doc "True once a trainee's informer skill has reached its target."
  def trained?(skills, train_target) when is_integer(train_target),
    do: skill_points(skills).infiltration >= train_target

  def trained?(_skills, _train_target), do: false

  @doc """
  The posting a graduating trainee takes: `{theatre, duty}`. `rolls` is
  `{theatre_roll, duty_roll}`. The home option needs `min_points` between
  removal and sabotage; without them the agent is sent to the field whatever
  it rolled.
  """
  def graduate(skills, {theatre_roll, duty_roll}, opts) do
    home_share = Keyword.fetch!(opts, :home_share)
    min_points = Keyword.fetch!(opts, :min_points)

    if fit_for_home_duty?(skills, min_points) and theatre_roll < home_share do
      {:home, duty(duty_roll, Keyword.fetch!(opts, :home_weights), skills)}
    else
      {:field, duty(duty_roll, Keyword.fetch!(opts, :field_weights), skills)}
    end
  end

  # --- forward postings -------------------------------------------------------

  @doc """
  How many scouts and deep infiltrators the Rebellion keeps forward:
  `%{scout: n, deep: n}`. Each is its per-player rate times the humans faced,
  rounded, and the two together never exceed `room` agents: scouts are seated
  first and deep infiltration takes what is left.
  """
  def forward_quotas(players, scouts_per_player, deep_per_player, room)
      when is_number(players) and is_number(scouts_per_player) and is_number(deep_per_player) and is_integer(room) do
    room = max(room, 0)
    scouts = (players * scouts_per_player) |> round() |> max(0) |> min(room)
    deep = (players * deep_per_player) |> round() |> max(0) |> min(room - scouts)

    %{scout: scouts, deep: deep}
  end

  @doc "How many Erased hold each forward posting today."
  def forward_held(roster) do
    held =
      roster
      |> Enum.filter(fn {_id, entry} -> Map.get(entry, :theatre) == :forward end)
      |> Enum.frequencies_by(fn {_id, entry} -> Map.get(entry, :duty) end)

    %{scout: Map.get(held, :scout, 0), deep: Map.get(held, :deep, 0)}
  end

  @doc "The forward postings still open, scouts first, as a list of duties."
  def forward_vacancies(quotas, held) do
    for duty <- [:scout, :deep],
        _ <- 1..max(Map.get(quotas, duty, 0) - Map.get(held, duty, 0), 0)//1,
        do: duty
  end

  @doc "True when an agent can be sent forward: it holds at least `min_points` informer points."
  def fit_for_forward?(skills, min_points), do: skill_points(skills).infiltration >= min_points

  @doc """
  Orders the candidates for a forward posting: the strongest informer first,
  and between equals the one already on infiltration duty, so a remover or a
  saboteur is only taken off its trade when nobody else will do.
  """
  def forward_rank(infiltrate_strength, duty, id),
    do: {-infiltrate_strength, if(duty == :infiltration, do: 0, else: 1), id}

  @doc "Ground a forward agent works: a system or a dominion another faction holds."
  def forward_ground?(system, bot_faction) do
    system.faction not in [nil, bot_faction] and system.status in [:inhabited_dominion, :inhabited_player]
  end

  # A sector no chain of adjacency reaches from rebel space has no depth. A
  # scout treats it as the far end of the map; a deep infiltrator, which
  # counts from the far end, as the near one.
  @unreached_depth 99

  @doc """
  Ranks forward ground for one posting. `depth` is the sector's distance from
  rebel space (`Wave.Geometry.depth_of/2`), `chance` the agent's odds against
  the Intelligence the Rebellion has learned there (nil when it never has).

  A scout sweeps from the edge nearest rebel space inwards, a deep infiltrator
  from the far end outwards. Inside a sector both take a system known to be
  soft before one never tried, and one known to be hard last, the nearest
  first.
  """
  def forward_priority(:deep, system, depth, chance, hops),
    do: {-(depth || 0), odds_rank(chance), hops, system.id}

  def forward_priority(_scout, system, depth, chance, hops),
    do: {depth || @unreached_depth, odds_rank(chance), hops, system.id}

  defp odds_rank(nil), do: 1
  defp odds_rank(chance) when chance >= 0.5, do: 0
  defp odds_rank(_chance), do: 2

  # --- target rules -----------------------------------------------------------

  @doc """
  True for a replacement officer — the level-1 stand-in
  (`Instance.Character.Character.replace_agent_with_default/2`) the engine
  hands a player whose Navarch was removed. Killing one buys nothing, so the
  Erased leave it alone until it has earned a level of its own.
  """
  def replacement_officer?(%{type: :admiral, name: name}) when is_binary(name), do: String.starts_with?(name, "CMO #")
  def replacement_officer?(_character), do: false

  @doc "True when a hostile is worth removing: an enemy agent that isn't an unproven CMO."
  def removable?(hostile) do
    hostile.type in [:admiral, :spy, :speaker] and
      not Map.get(hostile, :governor?, false) and
      not (replacement_officer?(hostile) and (hostile.level || 1) <= 1)
  end

  @doc """
  True when a fleet is worth sabotaging: an enemy Navarch carrying at least
  `min_tiles` filled tiles — or any fleet with a colony ship in it, which is a
  colony the Rebellion would rather never happen. `colony_ship?` is `nil` when
  the Rebellion can't read the fleet's ship keys, and an unread fleet is
  judged on its tile count alone.
  """
  def worth_sabotaging?(hostile, min_tiles) do
    hostile.type == :admiral and not Map.get(hostile, :governor?, false) and
      ((hostile.tiles || 0) >= min_tiles or hostile.colony_ship? == true)
  end

  @doc """
  True when a system is worth infiltrating: the Rebellion cannot already see
  it in full. Visibility 5 is everything there is to know, so another informer
  buys nothing.
  """
  def worth_infiltrating?(visibility), do: is_integer(visibility) and visibility < 5

  @doc """
  True when a target is worth travelling to.

  A hostile in a system the Rebellion sees only because one of its own agents
  happens to be standing there is real, but the sight is borrowed: it ends the
  moment that agent moves on or is caught. Crossing the map for such a target
  would quietly tie a remover's success to an infiltrator's — two failures for
  the price of one — so borrowed sight only justifies a strike already within
  `transient_hops`. Sight from informers keeps, and carries any distance.
  """
  def committable?(hostile, hops, transient_hops) do
    not Map.get(hostile, :transient?, false) or hops <= transient_hops
  end

  @doc """
  Where an Erased with nothing to strike or practise should scout: systems
  the Rebellion has never seen at all (`seen?` is false), within `max_hops`,
  of any kind — an empty system is a colony site worth knowing about. The
  engine files an explorer contact on every system an agent jumps into, so a
  scout also sees everything along its path, and a system once seen stays
  seen. That is what stops two neighbours trading places forever: the one
  just left is no longer unseen.
  """
  def explore_targets(systems, seen?, max_hops, distances) do
    Enum.filter(systems, fn system ->
      case Map.get(distances, system.id) do
        nil -> false
        hops -> hops > 0 and hops <= max_hops and not seen?.(system.id)
      end
    end)
  end

  @doc "Ranks a scouting target: nearest first, then dominions, held systems, neutral ground, the rest."
  def explore_priority(system, hops), do: {hops, roam_priority(system), system.id}

  @doc "Ranks a system by what it holds: dominions, then held systems, then neutral ground."
  def roam_priority(%{status: :inhabited_dominion}), do: 0
  def roam_priority(%{status: :inhabited_player}), do: 1
  def roam_priority(_system), do: 2

  # --- practice -----------------------------------------------------------------

  @doc """
  True while an agent below `max_level` should train ahead of scouting. Past
  it an agent still trains, but only once there is nothing else left to do.
  """
  def trains?(level, max_level) when is_integer(level) and is_number(max_level), do: level < max_level
  def trains?(_level, _max_level), do: false

  @doc """
  How an idle agent practises: `:sabotage` on the training Navarch when it
  holds sabotage points but no informer points and a training Navarch is
  available, `:infiltration` otherwise. Infiltration is the better teacher,
  so any informer point settles it.
  """
  def practice(skills, dummy_available?) do
    points = skill_points(skills)

    if points.infiltration == 0 and points.sabotage > 0 and dummy_available?,
      do: :sabotage,
      else: :infiltration
  end

  @doc """
  What the Rebellion knows about an infiltration target, from the success
  chance its learned Intelligence gives this agent (`nil` when it has never
  been told): `:unknown`, `:soft` at `min_chance` or better, else `:hopeless`.
  """
  def practice_odds(nil, _min_chance), do: :unknown
  def practice_odds(chance, min_chance) when chance >= min_chance, do: :soft
  def practice_odds(_chance, _min_chance), do: :hopeless

  @doc """
  Rank practice targets: known-soft systems first, best odds first; then the
  unknown ones, nearest first. Known-hopeless targets are dropped before this.
  """
  def practice_priority(system, chance, hops) do
    case chance do
      nil -> {1, 0.0, hops, system.id}
      chance -> {0, -chance, hops, system.id}
    end
  end

  @doc """
  Rank sabotage targets: fleets besieging something the Rebellion holds come
  first, then colony ships, then the biggest fleet, then the nearest.
  """
  def sabotage_priority(hostile, hops) do
    {
      if(hostile.besieging_ours?, do: 0, else: 1),
      if(hostile.colony_ship? == true, do: 0, else: 1),
      -(hostile.tiles || 0),
      hops,
      hostile.id
    }
  end

  @doc """
  Rank removal targets: the best odds first (unknown odds sort last among
  equals), then the higher level, then the nearest.
  """
  def removal_priority(hostile, chance, hops) do
    {-(chance || 0.0), if(is_nil(chance), do: 1, else: 0), -(hostile.level || 0), hops, hostile.id}
  end

  # --- slots ------------------------------------------------------------------

  @doc """
  The targets an Erased may join, given how many of its fellows already work
  each one.

  `committed` answers the current count for a candidate. A target at `cap` is
  closed outright; below it, an extra Erased joins with probability
  `falloff^n`. `roll` is one uniform draw in [0, 1) shared by the whole
  admission, which is what makes the drop-off feel like a decision rather than
  a lottery per candidate.
  """
  def admit(candidates, committed, roll, falloff, cap)
      when is_function(committed, 1) and is_number(roll) and is_number(falloff) and is_integer(cap) do
    Enum.filter(candidates, fn candidate ->
      n = committed.(candidate)
      n < cap and :math.pow(falloff, n) > roll
    end)
  end

  @doc "How many Erased are committed to each target key, leaving out `except`."
  def commitments(roster, except \\ nil) do
    roster
    |> Enum.reject(fn {id, entry} -> id == except or Map.get(entry, :target_key) == nil end)
    |> Enum.frequencies_by(fn {_id, entry} -> Map.get(entry, :target_key) end)
  end

  # --- telemetry --------------------------------------------------------------

  @acting [:infiltration, :sabotage, :assassination]

  @doc """
  Which state an observed Erased is in. `:resting` is the one that matters:
  a discovered Erased has its coefficients zeroed until its cover recovers,
  so it is not idle by choice — it is lying low.
  """
  def bucket(action_status, discovered?) do
    cond do
      action_status in [:moving, :docking] -> :moving
      action_status in @acting -> :acting
      action_status == :idle and discovered? -> :resting
      action_status == :idle -> :idle
      true -> :other
    end
  end

  # --- internals ---------------------------------------------------------------

  defp weighted_pick(scaled, roll) do
    total = scaled |> Enum.map(&elem(&1, 1)) |> Enum.sum()
    target = roll * total

    scaled
    |> Enum.reduce_while(0.0, fn {duty, weight}, acc ->
      acc = acc + weight
      if target < acc, do: {:halt, duty}, else: {:cont, acc}
    end)
    |> case do
      duty when is_atom(duty) -> duty
      _ -> scaled |> List.last() |> elem(0)
    end
  end
end
