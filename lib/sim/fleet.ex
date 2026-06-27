defmodule Sim.Fleet do
  @moduledoc """
  Builds the `Instance.Character.Character` (a single admiral + its army)
  that `Fight.Manager.fight/2` consumes, from a compact fleet spec.

  A spec is a list of `{tile_id, ship_key}` or `{tile_id, ship_key, level}`
  (`tile_id` in `1..Sim.Setup.tile_count()`, `level` 0..15, default 0). Ships
  deploy in lines of 3 over the battle, so tile position (which line a ship
  lands in) is part of the design, not just the bag of counts.

  Only `character.level` (commander level) and each ship's `level` affect
  combat — admiral skills/bonuses drive economy coefficients the fight never
  reads. So we build a neutral, deterministic commander and expose
  `:commander_level` and per-ship `level` as the controlled knobs. Combat
  reads `ship.level` directly, so we set it on the built ship rather than
  feeding XP through the level curve.

  NOTE: the two fleets in a battle must use distinct `:id`s — the fight keys
  armies and ship refs by `character.id`.
  """

  alias Instance.Character.Character
  alias Instance.Character.Player
  alias Instance.Character.Army

  @instance_id :sim

  @doc """
  Build an admiral Character from `slots`.

  Opts:
    * `:id`              (default `1`)        — character id; the two sides of a battle must differ.
    * `:commander_level` (default `0`)        — feeds ship morale.
    * `:faction`         (default `:myrmezir`)
    * `:build_seed`      (default `:id`)       — seeds the combat-irrelevant rolls in `Character.new`.
  """
  def build(slots, opts \\ []) do
    id = Keyword.get(opts, :id, 1)
    commander_level = Keyword.get(opts, :commander_level, 0)
    faction = Keyword.get(opts, :faction, :myrmezir)
    build_seed = Keyword.get(opts, :build_seed, id)

    # Make the (combat-irrelevant) construction rolls in Character.new
    # deterministic so fleets are byte-for-byte reproducible.
    Process.put(:rc_sim_rand_state, :rand.seed_s(:exrop, build_seed))

    character = Character.new(id, :admiral, :common, 1, @instance_id)

    character = %{
      character
      | owner: %Player{id: id, name: "sim-#{id}", faction: faction, faction_id: id},
        status: :on_board,
        action_status: :idle,
        army: Army.new(@instance_id)
    }

    character =
      Enum.reduce(slots, character, fn slot, char ->
        {tile_id, ship_key, level} = normalize_slot(slot)
        {:ok, char} = Character.order_ship(char, {nil, tile_id, ship_key, nil})
        char = Character.put_ship(char, tile_id, 0.0)
        set_ship_level(char, tile_id, level)
      end)

    # Combat reads only character.level (morale); pin a clean, controlled
    # commander rather than the random spec/skills Character.new rolled.
    %{character | level: commander_level, skills: [0, 0, 0, 0, 0, 0], experience: Core.DynamicValue.new(0.0)}
  end

  @doc "A fleet of `count` copies of `ship_key` (opt `:level`) in the first `count` tiles."
  def mono(ship_key, count, opts \\ []) do
    level = Keyword.get(opts, :level, 0)

    1..count
    |> Enum.map(fn t -> {t, ship_key, level} end)
    |> build(opts)
  end

  @doc "Build from a `%{ship_key => count}` map (opt `:level` for all), packing into tiles in order."
  def from_counts(counts, opts \\ []) when is_map(counts) do
    level = Keyword.get(opts, :level, 0)

    {slots, _} =
      Enum.reduce(counts, {[], 1}, fn {key, count}, {slots, next} ->
        {slots ++ Enum.map(0..(count - 1), fn i -> {next + i, key, level} end), next + count}
      end)

    build(slots, opts)
  end

  @doc "Decode a genome (see Sim.Genome) for `stage` and build the fleet."
  def from_genome(genome, stage, opts \\ []) do
    genome
    |> Sim.Genome.decode(stage)
    |> build(opts)
  end

  @doc "Filled-tile ship slots of a built fleet as `[{ship_key, level}]`."
  def ship_slots(character) do
    character.army.tiles
    |> Enum.filter(fn t -> t.ship_status == :filled and is_map(t.ship) end)
    |> Enum.map(fn t -> {t.ship.key, t.ship.level} end)
  end

  @doc "The ship keys in a built fleet (one per filled tile, ignoring level)."
  def ship_keys(character), do: character |> ship_slots() |> Enum.map(fn {k, _} -> k end)

  ## helpers

  defp normalize_slot({tile, key}), do: {tile, key, 0}
  defp normalize_slot({tile, key, level}), do: {tile, key, level}

  defp set_ship_level(character, _tile_id, 0), do: character

  defp set_ship_level(character, tile_id, level) do
    tiles =
      Enum.map(character.army.tiles, fn t ->
        if t.id == tile_id and t.ship_status == :filled and is_map(t.ship),
          do: %{t | ship: %{t.ship | level: level, experience: 0.0}},
          else: t
      end)

    %{character | army: %{character.army | tiles: tiles}}
  end
end
