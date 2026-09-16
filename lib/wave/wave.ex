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

  Combat roles (pillage/bombard), Siderian and Erased behaviour, blueprint
  mining, and the wave schedule are the next slices.
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
      # Rank to buy. :common is the one-star tier.
      "hire_rank" => "common",
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
