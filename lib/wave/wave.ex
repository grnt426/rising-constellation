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
      # Below this level an idle agitator (or a seducer with agitator points)
      # practises on a shared neutral within this much travel.
      "siderian_train_max_level" => 5,
      "siderian_train_max_travel_ut" => 480.0,
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
      # How long a hostile reading stays good before the Erased pass takes
      # another, and how much it may read when it does.
      "erased_recon_interval_ut" => 3.0,
      "erased_scan_cap" => 60,
      "erased_probe_cap" => 12,

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
