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
      # Hard ceiling on simultaneously deployed colonisers, so a stalled
      # colonisation can never let the roster grow without bound.
      "max_active_colonisers" => 6,

      # --- economy ------------------------------------------------------
      # The Warlord tops the bot's credit back up to this floor each tick, so
      # market purchases never fail on affordability. Paired with the
      # bankruptcy suppression in Instance.Player.Player.
      "credit_floor" => 250_000,
      "technology_floor" => 25_000,
      "ideology_floor" => 25_000,

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
