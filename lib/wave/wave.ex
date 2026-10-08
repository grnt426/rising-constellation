defmodule Wave do
  @moduledoc """
  Wave Defense — the PvE mode where every human plays one faction and a
  bot-run "Rebellion" faction plays the other. Design: `docs/wave-defense.md`.

  This module holds the mode's identity constants and the default knob set.
  Everything the running engine needs to read at runtime goes through
  `Wave.Config`, which reads the per-instance metadata cache (never the DB).

  ## MVP scope (2026-09-13)

  The first slice deliberately proves the load-bearing plumbing rather than
  the full design:

    * the Rebellion exists as a real faction, held by a real bot profile that
      is the only member of its faction;
    * a `Wave.Warlord` tick server runs inside the instance supervision tree
      and drives the faction on a game-time cadence;
    * it hires a one-star Navarch from the character market, deploys it, and
      materializes a colony ship into its fleet with no production;
    * that Navarch colonizes, then is recalled and dismissed;
    * the bot bypasses the system/dominion/agent caps and cannot go bankrupt,
      while human players in the same instance are untouched;
    * rebellion-held systems and dominions develop on a dedicated behavior
      tree ("Rebel Dominion") at a much faster cadence than neutral systems.

  Since then the Siderians (dominion capture) and the Erased (removal,
  sabotage, infiltration and a training path — see `Wave.Erased`) have been
  built on the same Warlord pass. Navarch combat roles (pillage/bombard),
  blueprint mining and the wave schedule are the next slices.
  """

  @mode_type "wave"

  @doc "The `game_mode_type` value that marks an instance as Wave Defense."
  def mode_type, do: @mode_type

  @doc "The faction key the Rebellion always uses."
  def rebellion_faction, do: :rebellion

  @doc """
  True when `faction` (an `RC.Instances.Faction` row) is the bot-held faction
  of a wave `instance` (an `RC.Instances.Instance` row). Used by the lobby's
  registration guard, so it reads the DB structs rather than the runtime
  metadata cache — the instance may not be running yet.
  """
  def locked_faction?(%{game_data: %{} = game_data}, %{faction_ref: faction_ref}) do
    game_data["game_mode_type"] == @mode_type and
      faction_ref == (get_in(game_data, ["wave", "bot_faction"]) || "rebellion")
  end

  def locked_faction?(_instance, _faction), do: false

  @doc """
  Engine hook: a Navarch came out of a fight (`:fight`, with its status) or
  finished a pillage, bombardment or invasion (with the roll's result). In a
  Wave Defense game the Rebellion's own Navarchs are reported to the Warlord,
  which scores the fleet's design by it (`Wave.Doctrine`). Everything else is
  ignored, and nothing here can fail the caller.
  """
  def report_fleet(%{instance_id: instance_id, id: id, owner: %{faction: faction}}, kind, result)
      when is_integer(instance_id) do
    if Wave.Config.bot_faction?(instance_id, faction),
      do: Game.cast(instance_id, :wave, :master, {:fleet_result, id, kind, result})

    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  def report_fleet(_character, _kind, _result), do: :ok

  @doc """
  Default knobs, merged under whatever `game_data["wave"]` carries. Keys are
  strings because this map round-trips through the instance's jsonb game_data.

  Times are in unit-time (ut). At Legacy speed 1 ut = 1 in-game day = 3 real
  minutes, so 120 ut = 6 real hours and 1.667 ut = 5 real minutes.
  """
  def defaults do
    %{
      # Faction keys. `bot_faction` is the one the Warlord drives.
      "bot_faction" => "rebellion",
      "human_faction" => "tetrarchy",

      # --- recruitment cycle -------------------------------------------
      # How often the Rebellion buys and deploys a colonising Navarch.
      "hire_interval_ut" => 120.0,
      # Fallback rank when the schedule below opens nothing. :common is one star.
      "hire_rank" => "common",
      # Match day each market rank becomes buyable, for every role. The
      # Rebellion's resource floors mean price is never a brake, so without
      # this it would field three-star agents on day one; the schedule is what
      # makes its early agents green and its late ones dangerous. Ranks are
      # `Data.Game.CharacterRank`: common (1★), remarkable (2★), exceptional (3★).
      "rank_unlock_days" => %{"common" => 0, "remarkable" => 5, "exceptional" => 8},
      # Army tile the free colony ship is dropped into.
      "colony_ship_tile" => 1,
      # Deployed colonisers never exceed the Navarch ceiling (below). An
      # instance may add a hard `max_active_colonisers` cap; there is no default.
      # Colonisers are also capped at this multiple of the open systems left in
      # reachable sectors (rounded down); surplus idle ones are released.
      "idle_navarch_factor" => 1.5,
      # Every this many passes, re-read every tracked agent instead of only the
      # ones the player's roster reports idle.
      "state_refresh_passes" => 20,
      # The bot player coalesces its systems' state updates over this window
      # (wall milliseconds) and recomputes its bonuses once per window.
      "system_update_batch_ms" => 500,

      # --- Siderian dominion capture ---------------------------------------
      # Agent ceilings. Per match day (index 0 = day 1; later days keep the
      # last value): the agents a typical human player had on board, the
      # 62.5th percentile across every player of the official Legacy matches
      # i20, i49, i87 and i121, held non-decreasing. The Rebellion's ceiling
      # for each kind is that value times the human players in the game,
      # rounded, at least 1 (Wave.Warlord.agent_ceiling/2). The Navarch curve
      # takes the higher of the replay rebuild and i121's nightly snapshots.
      # See docs/wave-defense.md.
      "siderians_per_player_by_day" => [0, 1, 1, 1, 1, 1, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 3, 3, 3, 3, 3],
      "erased_per_player_by_day" => [
        0,
        0.875,
        1,
        1,
        2,
        2,
        2,
        2,
        2,
        2,
        2,
        2.5,
        3,
        3,
        3,
        4,
        4.5,
        4.75,
        5,
        5,
        5,
        5,
        5,
        5,
        5,
        5,
        5
      ],
      "navarchs_per_player_by_day" => [
        0,
        1,
        1,
        1,
        1,
        1,
        1,
        1,
        1,
        1,
        1,
        1,
        1.125,
        1.25,
        1.25,
        2,
        2.25,
        2.25,
        2.25,
        2.25,
        3.125,
        3.125,
        3.125,
        3.125,
        3.125,
        4,
        4
      ],
      # The player count the ceilings scale with never drops below this. Test
      # games with a single human raise it to an official match's size (14–17).
      "scale_players_min" => 1,
      # Sector pace. The Rebellion opens new fronts only while it holds fewer
      # sectors than this share of the map allows, by match day, looked up
      # `sector_pace_lead_days` ahead because flipping a sector takes time. The
      # curve is the leading human faction's sector count on the Citadel map in
      # official match i121, over its 19 sectors (1, 1, 2, 2, 3, 3, 4, 5, 5, 6,
      # 7, 8, 8, 8, 8, 9, 10, 11, 11, 11, 13, 13).
      # `sector_pace_speedup` runs that clock faster from a given day on:
      # `[[from_day, factor], ...]` in days elapsed. `[[9, 2], [11, 4]]` halves
      # the wait between two sector openings from day 9 and halves it again
      # from day 11. `sector_open_contested_from_day`, when set, lifts the
      # gate altogether for a neighbouring sector with a human system or
      # dominion in it from that day on.
      "sector_pace_speedup" => [],
      "sector_open_contested_from_day" => nil,
      "sector_share_by_day" => [
        0.0526,
        0.0526,
        0.1053,
        0.1053,
        0.1579,
        0.1579,
        0.2105,
        0.2632,
        0.2632,
        0.3158,
        0.3684,
        0.4211,
        0.4211,
        0.4211,
        0.4211,
        0.4737,
        0.5263,
        0.5789,
        0.5789,
        0.5789,
        0.6842,
        0.6842
      ],
      "sector_pace_lead_days" => 1.0,
      # Inside its own sectors the Rebellion colonizes and captures only while
      # its vote lead over the next voter is below this, so a comfortably held
      # sector is left for humans to contest.
      "hold_margin" => 2,
      # Game time per match day (Legacy runs at 20 ut an hour).
      "ut_per_day" => 480.0,
      # A target already carrying n Siderians is considered with probability
      # falloff^n: a second Siderian joins it 20% of the time, a third 4%.
      "capture_overlap_falloff" => 0.2,
      # The first Siderian is hired at once; further ones wait this long.
      "siderian_hire_interval_ut" => 120.0,
      # Only Siderians with capture strength (the proselyte skill) are bought.
      # When the market has none, look again after this long, not every pass.
      "siderian_retry_ut" => 10.0,
      # Sector-class weights for picking a capture target: sectors next to
      # rebel space, rebel sectors on the edge, rebel sectors fully inside.
      "capture_weights" => %{"frontier" => 80, "border" => 15, "internal" => 5},

      # --- Siderian trades (docs/wave-defense.md, "destabilization and
      # seduction") ---------------------------------------------------------
      # How the Siderian ceiling is split between the trades. Capture only
      # takes its share while there are capture targets; the rest goes to
      # destabilization and seduction by weight (Wave.Siderian.quotas/3).
      "siderian_role_weights" => %{"capture" => 40, "destab" => 30, "seduce" => 30},
      # Mass destabilization: agitators converge on one enemy system or
      # dominion within this much travel, at most `destab_focus_cap` at a
      # time, until the estimated happiness reaches `destab_floor` (general
      # uprising, the 80% cut); then one keeps it there, striking again when
      # the estimate climbs back above floor + margin.
      "destab_max_travel_ut" => 480.0,
      "destab_focus_cap" => 5,
      "destab_floor" => -30,
      "destab_rehit_margin" => 10,
      # With no enemy in reach, an agitator softens the neutral a capture
      # Siderian is heading for while its estimate is above this.
      "capture_soften_above" => 10,
      # An agitator with no duty (or a seducer with agitator points) practises
      # on a shared neutral within this much travel, in one of the Rebellion's
      # border sectors when it can. Better over-levelled than idle, so there
      # is no level cap; a number here sets one.
      "siderian_train_max_level" => nil,
      "siderian_train_max_travel_ut" => 480.0,
      # A seducer needs someone to seduce. Until a human holds a system or a
      # dominion in a sector the Rebellion owns, or within this many sectors
      # of one, only this many seducers are kept; the places that frees go to
      # capture while it has targets and are otherwise left unfilled.
      "seducers_before_contact" => 1,
      "seduce_contact_depth" => 1,
      # Seduction weighs its odds like removal does.
      "seduce_gate" => %{"unknown" => 0.2, "steepness" => 12.0, "midpoint" => 0.5},
      # A Siderian on its cooldown outside rebel-held sectors keeps moving
      # between neighbouring systems: it cannot hide, and nothing intercepts
      # it in transit.
      "siderian_evade" => true,

      # --- Erased (docs/wave-defense.md §1.3) ------------------------------
      # The first Erased is hired at once; further ones wait this long. When
      # the market has nobody able to infiltrate, remove or sabotage, look
      # again after `erased_retry_ut` rather than on every pass.
      "erased_hire_interval_ut" => 120.0,
      "erased_retry_ut" => 10.0,
      # The share of the roster that never leaves rebel sectors. The rest work
      # the border and enemy sectors.
      "erased_home_share" => 0.25,
      # How far out the field theatre reaches, in sectors from the nearest
      # rebel-owned one. Beyond this an Erased has no business.
      "erased_field_depth" => 2,
      # Duty weights per theatre, each scaled by the points the agent holds in
      # that skill (Wave.Erased.duty/3). Home Erased that are too green for
      # either attack train instead — see `erased_train_points`.
      "erased_home_weights" => %{"removal" => 50, "sabotage" => 50},
      "erased_field_weights" => %{"infiltration" => 40, "removal" => 30, "sabotage" => 30},
      # A trainee graduates once its informer skill reaches a target rolled in
      # this range. The home posting on graduation needs at least
      # `erased_home_duty_points` across removal and sabotage; without them the
      # agent goes to the field whatever it rolls.
      "erased_train_points" => [3, 6],
      "erased_graduate_home_share" => 0.5,
      "erased_home_duty_points" => 2,
      # At most this many Erased work one target at a time, and each extra one
      # joins with probability falloff^n — a second is uncommon, a third rare.
      "erased_target_cap" => 5,
      "erased_home_target_cap" => 7,
      "erased_overlap_falloff" => 0.35,
      # Sabotage ignores fleets already broken below this many filled tiles —
      # unless the fleet carries a colony ship, which is worth stopping at any
      # size. A wounded fleet standing on rebel ground is still worth breaking,
      # so the home threshold is lower.
      "erased_sabotage_min_tiles" => 6,
      "erased_home_sabotage_min_tiles" => 4,
      # Removal gate (Wave.Intel.attempt_chance/2): a defence the Rebellion
      # cannot read is a flat gamble; a readable one runs through a logistic
      # centred on an even chance, so appetite climbs steeply past a coin flip.
      "erased_removal_gate" => %{"unknown" => 0.2, "steepness" => 12.0, "midpoint" => 0.5},
      # A target seen only because one of our own agents happens to be standing
      # in its system is a target that vanishes when that agent moves or dies.
      # Erased will still strike one within this many hops, but will not commit
      # to a journey for it — anything further has to be visible from informers,
      # which persist. Keeps removers from silently riding on infiltrators and
      # failing with them.
      "erased_transient_hops" => 1,
      # An Erased whose duty has nothing to strike trains instead, until it
      # reaches this level; at or above it the agent only explores or waits.
      "erased_train_max_level" => 5,
      # Infiltration practice goes anywhere until the Rebellion has learned a
      # system's Intelligence from its own results; from then on a system is
      # worth an attempt only at this success chance or better. Real
      # infiltration duty skips the known-hopeless systems too.
      "erased_train_min_chance" => 0.25,
      # An infiltration waits until the agent's cover stands this far above the
      # discovery threshold: 12 is the most a success costs, so only a failure
      # shows the agent to the system's owner. 0 strikes the moment it can.
      "erased_infiltrate_cover_margin" => 12,
      # After a failed infiltration at odds below this in a system somebody
      # holds, every Erased whose own odds there are below it too leaves the
      # system alone for this long (a day at Legacy speed). At better odds a
      # failure is bad luck and the agent goes again.
      "erased_fail_cooloff_chance" => 0.75,
      "erased_fail_cooloff_ut" => 480.0,
      # Erased with sabotage points but no informer points train by
      # sabotaging the Rebellion's own training Navarch — the loop teams run
      # between two teammates — when it is within this much travel (a day at
      # Legacy speed).
      "erased_dummy" => true,
      "erased_dummy_max_travel_ut" => 480.0,
      # With nothing to strike and nothing left to train, an Erased goes to
      # the nearest system the Rebellion has never seen, this often per idle
      # pass, the way players scout at the start of a match.
      "erased_roam_chance" => 0.35,
      "erased_roam_max_hops" => 6,
      # Forward postings: field informers sent past the field theatre to work
      # the ground the humans hold, however far away it is. Scouts take the
      # edge nearest rebel space first; deep infiltrators start at the far end,
      # where Intelligence is usually thinnest, and collect Shadows points.
      # Each quota is its rate times the human players (one scout per three
      # players, one deep infiltrator per five), and the two together never
      # take more than `erased_forward_max_share` of the roster. Only agents
      # with at least `erased_forward_min_points` informer points are sent.
      "erased_scouts_per_player" => 0.35,
      "erased_deep_per_player" => 0.2,
      "erased_forward_max_share" => 0.3,
      "erased_forward_min_points" => 1,
      # How long a hostile reading stays good before the Erased pass takes
      # another, and how much it may read when it does.
      "erased_recon_interval_ut" => 3.0,
      "erased_scan_cap" => 60,
      "erased_probe_cap" => 12,

      # --- fleets --------------------------------------------------------
      # Fleet Navarchs: hired for a role, given a design players fielded
      # (Wave.Blueprints), built in a shipyard system and posted. `fleets`
      # true switches the step on; a game that never sets it raises none.
      "fleets" => false,
      # Fleet ceiling, per human player by match day like the agent ceilings
      # above: the fleets of nine ships or more a player had flying in the
      # official Legacy matches (the middle of i20, i49, i87 and i121), held
      # non-decreasing. Fleets stay rare until the frigate patents land around
      # day 13, then double within three days.
      "fleets_per_player_by_day" => [
        0,
        0.1,
        0.15,
        0.2,
        0.25,
        0.25,
        0.3,
        0.5,
        0.5,
        0.55,
        0.6,
        0.6,
        0.7,
        1,
        1.7,
        2,
        2,
        2,
        2,
        2,
        2.1,
        2.5,
        2.5,
        3.5,
        3.5
      ],
      # How often the Rebellion hires a fleet Navarch while under the ceiling.
      "fleet_hire_interval_ut" => 60.0,
      # A shipyard system lays down one ship per interval (15 real minutes at
      # Legacy), one fleet at a time.
      "fleet_ship_interval_ut" => 5.0,
      # 0 keeps that flat rule. Above 0 a yard also pays for each hull out of
      # its own production, this many times as fast as a player's system
      # would, with the interval as the floor: at 1 a Cruiser (120,000
      # production) ties up a 600-production yard for 200 ut where a scout
      # swarm still takes 5.
      "fleet_production_pace" => 0,
      # Classes that take longer than the interval above: a capital ship
      # holds the yard for 20 ut, one real hour.
      "fleet_class_interval_ut" => %{"capital" => 20.0},
      # Capital ships per fleet. Players never massed them, for their cost:
      # one or two per fleet in the first days after the patent, three or four
      # late, six at the very most. The Rebellion may put one in a fleet once a
      # human fields a capital hull, and one more every 600 ut (30 real hours),
      # up to the maximum. Capitals of a design past the allowance are built as
      # the hull the design has most of.
      "fleet_capital_step_ut" => 600.0,
      "fleet_capital_max" => 6,
      # The Rebellion's own designs (Wave.Doctrine). Per role it keeps this
      # many identities, each a library design fuzzed: `fleet_fuzz_swaps`
      # tiles take another unlocked hull of their class (or of the class next
      # to it while that class has only one) and `fleet_fuzz_moves` pairs of
      # tiles change places.
      "fleet_identities_per_role" => 2,
      "fleet_fuzz_swaps" => 3,
      "fleet_fuzz_moves" => 2,
      # Every review (a real day) an identity is judged by what its fleets
      # did since the last one. With at least `fleet_design_min_results`
      # results: a win share of `fleet_design_win_share` or more is winning,
      # and it is fuzzed again, lightly; under `fleet_design_lose_share` is
      # losing, a strike. An identity is replaced from the library when it
      # has more strikes than `fleet_design_forgiveness`, so one bad day is
      # forgiven. A winning review clears the strikes.
      "fleet_review_interval_ut" => 480.0,
      "fleet_design_min_results" => 2,
      "fleet_design_win_share" => 0.5,
      "fleet_design_lose_share" => 0.34,
      "fleet_design_forgiveness" => 1,
      # An identity that is not winning is also replaced once what it builds
      # costs under this share of the cheapest design the library would still
      # offer its role: the book follows the hulls as they unlock.
      "fleet_design_outdated_share" => 0.75,
      "fleet_refuzz_swaps" => 1,
      "fleet_refuzz_moves" => 1,
      # The system types whose systems are shipyards: the military type, which
      # is the one that rolls the shipyards and the academy.
      "fleet_yard_profiles" => ["defense"],
      # A yard builds only the hulls whose shipyard stands in the system.
      # False lets every military system build everything.
      "fleet_yard_needs_shipyard" => true,
      # Military dominions count as yards too. A Navarch can only be deployed
      # in a system the Rebellion runs itself, so a fleet for a dominion yard
      # walks there first.
      "fleet_yard_dominions" => true,
      # Game time between two looks at the yards (which shipyards stand, what
      # experience each gives).
      "fleet_yard_refresh_ut" => 120.0,
      # The stages of a match for the role split, in days elapsed.
      "fleet_stage_days" => [5, 12],
      # Share of the fleet roster each role takes, by stage. From what the
      # players' fleets were seen doing in the official matches: three in ten
      # stand guard at every stage; sieges and invasions wait for the frigate
      # and Carrier patents; every siege or invasion fleet has a fleet-killer
      # to cover it.
      "fleet_role_weights" => %{
        "early" => %{"defense" => 40, "raid" => 60},
        "mid" => %{"defense" => 30, "raid" => 35, "siege" => 5, "screen" => 30},
        "late" => %{"defense" => 30, "raid" => 25, "siege" => 15, "conquest" => 10, "screen" => 20}
      },
      # Of the designs the patents allow for a role, only the costliest share
      # stays in the draw (at least three designs).
      "fleet_design_share" => 0.5,
      # Share of the defense fleets posted in border sectors; the rest stand
      # inside. Shipyard systems are garrisoned first in both.
      "fleet_defense_border_share" => 0.6,
      # The stance a finished fleet takes, by role: Interdiction for the
      # garrisons, Fury for the screens, Defender for the rest.
      "fleet_stances" => %{
        "defense" => "attack_enemies",
        "raid" => "defend",
        "siege" => "defend",
        "conquest" => "defend",
        "screen" => "attack_everyone"
      },
      # A posted fleet that has lost this share of its ships walks back to a
      # yard and refits.
      "fleet_refit_share" => 0.35,

      # --- economy ------------------------------------------------------
      # The Warlord tops the bot's stock back up to these floors each tick, so
      # market purchases never fail on affordability. Market prices climb with
      # every purchase: at a 25k ideology floor a scaled Siderian roster stalled
      # at 9-10 hires (Citadel run 5), so the floors sit far above any price the
      # roster reaches. Paired with the bankruptcy suppression in
      # Instance.Player.Player.
      "credit_floor" => 10_000_000,
      "technology_floor" => 2_000_000,
      "ideology_floor" => 2_000_000,

      # --- research -------------------------------------------------------
      # Patents and lexes, bought through the player agent at the engine's
      # price (see Wave.Research). `research` false switches the step off.
      "research" => true,
      # One purchase per interval, a building patent and a lex in turn: about
      # the pace of a human player (22 purchases in 74 hours in i185).
      "research_interval_ut" => 60.0,
      # Given at the first research pass: the first patents of each building
      # branch, cheapest on offer first. Planets are `open` and `dome`; moons
      # and asteroids are `orbital`.
      "patent_starter" => %{"open" => 4, "dome" => 4, "orbital" => 4},
      # Ship patents are copied from the humans: this often the Rebellion buys
      # every ship-branch patent a human holds. The same look refreshes the
      # lex slot ceiling (the most slots any human has).
      "ship_patent_interval_ut" => 120.0,
      # Building patents follow the humans the same way: one held by this
      # many of them is bought at the same look. Each human specialises and
      # the Rebellion plays every role, so what several hold between them is
      # what a generalist would hold by now. 0 switches it off.
      "patent_follow_humans" => 2,
      # The clock buys a building patent this often: about one a day, which
      # with the starter set and what the humans hold keeps the Rebellion on
      # the players' curve (a median of 16 to 18 patents after five days and
      # 25 to 29 after twelve in the official matches). The other purchases
      # of `research_interval_ut` are lexes.
      "patent_interval_ut" => 480.0,
      # The stages of a game, in days elapsed: mid-game begins after the
      # first, the late game after the second. A game runs two to three
      # weeks; in the official matches the tools of each stage arrive at the
      # same point for every player.
      "research_stage_days" => [5, 12],
      # The dearest building patent the clock buys early, and from mid-game
      # on (technology, before the price climbs with what is owned). The
      # 8,000 to 40,000 patents wait for mid-game. The 50,000 and up are
      # never bought on the clock: they come when enough humans hold them.
      "patent_stage_cost" => [5_000, 45_000],
      # Lexes bought with the starter set and kept enacted, ancestors
      # included: Reaction Force, Pace of War, Digitalization of Interactions,
      # Propaganda.
      "lex_always" => ["admiral_1", "prod_2", "spy_def_1", "stab_2"],
      # The Rebellion plays every role at once, so it works its way down the
      # lexes that raise a resource: bought in this order, ancestors included,
      # one per lex purchase, ahead of any random lex, and enacted in this
      # order after the standing ones as far as the slots go. Freedom of
      # Movement (+20 mobility in every system), Decentralized
      # Cryptocurrencies (+10% credit), Predictive Sciences (+15%
      # technology), Stelloliberalized Entertainment (+15% ideology),
      # Synthetic Drugs (+5% credit, technology and production), Relaxed
      # Production Standards (+30 production), Modular Construction (+12%
      # production), Secret Organization (+15% credit).
      "lex_economy" => [
        "mobility_1",
        "credit_perc_1",
        "tech_3",
        "ideo_3",
        "stab_1",
        "prod_1",
        "upgrade_repair",
        "spy_2"
      ],
      # Expansion lexes raise caps the bot already bypasses, so the ones that
      # carry a penalty are bought but left on the shelf. True enacts them.
      "lex_enact_expansion_penalties" => false,

      # --- cap bypasses (bot player only) --------------------------------
      "max_systems_bonus" => 500,
      "max_dominions_bonus" => 500,
      "max_admirals_bonus" => 50,
      "max_spies_bonus" => 50,
      "max_speakers_bonus" => 50,

      # --- rebel system development ---------------------------------------
      # Cadence of the Rebel Dominion behavior tree on rebellion-held systems
      # and dominions. Vanilla neutral systems stay on their 50 ut cadence.
      "ai_interval_ut" => 1.667,

      # --- Warlord cadence --------------------------------------------------
      "tick_interval_ut" => 1.0
    }
  end
end
