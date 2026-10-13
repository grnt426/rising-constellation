defmodule Daily.Headhunter do
  @moduledoc """
  The rules of the Headhunter daily: an enemy court that sends its Erased into
  the player's system for the whole run, and the counter-intelligence sweep
  that exposes them.

  Everything here is pure — the numbers and the per-date roster. The process
  that applies them to a live instance is `Daily.Director`.

  ## The day

  One enemy Erased slips into the player's home system every 15 real seconds
  (`interval_seconds/0`), from the first interval to the last one before the
  deadline: 119 over a 30-minute run (`total/0`). They
  arrive under cover, so the player sees nothing of them until one is exposed.
  The score is the number the player's own Erased remove.

  The roster is a function of the date (`recruit/2`), so every player of a day
  faces the same agents in the same order. A recruit's level is drawn evenly
  from a band that widens with the clock (`level_band/1`). It opens at 1 to 3,
  an average of 2, and every 2 minutes the average rises by 0.75: the bottom
  stays at 1 and the top gains a level and a half. So the typical agent gets
  harder gently, an easy one can still arrive late, and a high-level one can
  arrive as soon as the band reaches it. The last two minutes draw from 1 to
  24, an average of 12.5. An agent's Protection is 10 per level, which is
  what the player's removal roll is made against: level decides both how
  readily an agent is exposed and how hard it is to remove.

  ## Exposure

  Ordinary play only uncovers a foreign Erased when it acts and spends its
  cover. These agents mostly wait, so the day adds its own rule. Every enemy
  Erased standing in one of the player's systems is measured against that
  system's Intelligence (counter-intelligence in code):

      chance = whole 25s of Intelligence × 20% ÷ the agent's level

  The chance is not rolled again and again: each recruit carries a fixed
  `evasion` between 0 and 1, and it is exposed the moment the chance passes
  it (`exposed?/3`). So the same Intelligence exposes the same agents for
  every player, raising Intelligence later still catches the ones that
  arrived earlier, and each new 25 points turns up a fresh batch at once.
  Below 25 Intelligence nothing is exposed this way.

  An exposed agent stays exposed until it is removed: the Director holds its
  cover at `exposed_cover/0`, under the discovery threshold.

  ## Removal attempts on the player

  One recruit in eight is bold (`recruit/2`). While not exposed, a bold agent
  has a one-in-four chance at each interval to try to remove one of the
  player's Erased standing in the same system — once; whatever happens, it
  does not try again. The attempt is the ordinary removal action: the
  target's Protection plus the system's Intelligence defend, and the attacker
  pays the usual cover, which nearly always puts it in plain sight for a
  minute or two. Their removal skill is half their level, so the Intelligence
  that exposes them also shields the player's own agents, up to a point: it
  takes about 42 Intelligence to shut out each point of removal skill, a
  little over 200 for an agent of level 10 and more than any system has for
  the level 20s of the last minutes.
  """

  @interval_seconds 15
  @intel_step 25
  @reveal_per_step 0.2
  @exposed_cover 45
  @bold_one_in 8
  @strike_chance 0.25
  @min_level 1
  @opening_top_level 3
  @level_window_seconds 120
  # the average gains 0.75 per window, so the top of the band gains twice that
  @top_level_per_window 1.5

  @doc "Real seconds between two arrivals, and between two sweeps."
  def interval_seconds, do: @interval_seconds

  @doc """
  How many enemy Erased a run of `time_limit_seconds` sends: one per interval,
  none at the deadline itself.
  """
  def total(time_limit_seconds \\ Daily.Generator.time_limit_minutes() * 60) do
    max(div(time_limit_seconds, @interval_seconds) - 1, 0)
  end

  @doc "How many should have arrived once `elapsed_seconds` of the run have passed."
  def due(elapsed_seconds, time_limit_seconds \\ Daily.Generator.time_limit_minutes() * 60) do
    elapsed_seconds
    |> Kernel./(@interval_seconds)
    |> Float.floor()
    |> trunc()
    |> max(0)
    |> min(total(time_limit_seconds))
  end

  @doc """
  The levels a recruit arriving `elapsed_seconds` into the run is drawn from,
  as `{lowest, highest}`. The band opens at 1 to 3 and its top gains a level
  and a half per 2-minute window, which raises the average by 0.75. In every
  other window `highest` therefore ends in .5: half the recruits of that
  window draw up to the level below it and half up to the level above.
  """
  def level_band(elapsed_seconds) when is_number(elapsed_seconds) do
    window = div(trunc(max(elapsed_seconds, 0)), @level_window_seconds)
    {@min_level, @opening_top_level + @top_level_per_window * window}
  end

  @doc """
  The `n`th enemy Erased of `date_iso` (1-based, arriving `n` intervals into
  the run): its level, its six skill slots (removal only), whether it is
  bold, and its `evasion` (see `exposed?/3`).
  """
  def recruit(date_iso, n) when is_binary(date_iso) and is_integer(n) and n >= 1 do
    [level_hi, level_lo, top_byte, bold_byte, evasion_hi, evasion_lo | _] =
      :crypto.hash(:sha256, "tetrarchy-daily-headhunter:v1:#{date_iso}:#{n}") |> :binary.bin_to_list()

    {lowest, highest} = level_band(n * @interval_seconds)
    # a half-level top is the level below for one recruit in two, the level above for the other
    top = if highest == trunc(highest), do: trunc(highest), else: trunc(highest) + rem(top_byte, 2)
    level = lowest + rem(level_hi * 256 + level_lo, top - lowest + 1)

    %{
      n: n,
      level: level,
      skills: [0, removal_points(level), 0, 0, 0, 0],
      bold?: rem(bold_byte, @bold_one_in) == 0,
      evasion: (evasion_hi * 256 + evasion_lo) / 65_536
    }
  end

  @doc "Removal (assassin) skill points of an enemy Erased of `level`: half its level, rounded up."
  def removal_points(level), do: div(level + 1, 2)

  @doc """
  Chance that a system with `intel` Intelligence exposes an enemy Erased of
  `level`.
  """
  def reveal_chance(intel, level) when is_number(intel) and is_number(level) do
    steps = intel |> max(0) |> Kernel./(@intel_step) |> Float.floor()
    min(steps * @reveal_per_step / max(level, 1), 1.0)
  end

  def reveal_chance(_intel, _level), do: 0.0

  @doc "Whether `intel` Intelligence exposes a recruit of `level` and `evasion`."
  def exposed?(intel, level, evasion), do: reveal_chance(intel, level) > evasion

  @doc "Cover an exposed agent is held at (the discovery threshold is 75)."
  def exposed_cover, do: @exposed_cover

  @doc "Chance per interval that a bold agent under cover makes its one removal attempt."
  def strike_chance, do: @strike_chance
end
