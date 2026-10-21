defmodule Edict.Simulator do
  @moduledoc """
  A dry run of a scenario script against a model of a player, for the
  editor's Simulate panel.

  The model is deliberately simple and says so: one home system, incomes
  that rise in a straight line from a start value to an end value over the
  run, stocks that accumulate them, and the script's own effects applied on
  top (`give`, `take`, `destabilize`, `send_agent`). It plays no actual game;
  what it answers is "what does my script do, when, and does it break?".
  Authors can bend the model with **pretend** entries ("at 15:00,
  player.patents is [\"capital_1\"]") to test goals the model never reaches
  on its own.

  The simulator drives the real runtime (`Edict.Runtime`), pulse by pulse,
  so schedules, catch-up, edges, errors and the score behave exactly as they
  will in a live run. The whole simulation runs inside `Edict.Sandbox` with a
  total step budget.
  """

  alias Edict.{Catalog, Interpreter, Runtime, Sandbox, Scenario}

  # Real seconds per game day at the daily's clock (factor 240: 180 / 240).
  @seconds_per_day 0.75
  # income per game day at the start and at the deadline (a typical run)
  @default_economy %{"credit" => [30.0, 800.0], "technology" => [6.0, 120.0], "ideology" => [6.0, 100.0]}
  @paces %{"slow" => 0.5, "typical" => 1.0, "strong" => 2.0}
  # The heaviest example spends 0.2 M steps over a whole 30-minute run; the
  # worst script that keeps running reaches 10 M in about 0.6 s of CPU.
  @max_total_fuel 10_000_000
  @max_timeline 400
  @sample_every 15

  @doc "The model's assumptions, for the editor to show."
  def assumptions,
    do: %{economy: @default_economy, stock: default_stock(), seconds_per_day: @seconds_per_day, paces: @paces}

  # The model starts where a real run does: the Legacy starting stocks the
  # daily uses (a playtest showed the gap when this was a guess).
  defp default_stock do
    c = hd(Data.Game.Constant.Content.Slow.data())

    %{
      "credit" => c.player_starting_credit / 1,
      "technology" => c.player_starting_technology / 1,
      "ideology" => c.player_starting_ideology / 1
    }
  end

  @doc "The total step budget of one simulation."
  def budget, do: @max_total_fuel

  @doc """
  Simulate `program`. Options: `:pace` ("slow" | "typical" | "strong"),
  `:pretend` (a list of `%{"at" => seconds, "path" => "player.credit", "value"
  => v}`), `:seed`. Returns `{:ok, report}` or `{:error, errors}`.
  """
  def run(program, opts \\ []) do
    case Sandbox.run(fn -> simulate(program, opts) end, timeout: 15_000) do
      {:ok, result} -> result
      {:error, reason} -> {:error, [%{message: Sandbox.describe(reason), node_id: nil, at: nil}]}
    end
  end

  defp simulate(program, opts) do
    with {:ok, pretend} <- parse_pretend(Keyword.get(opts, :pretend, [])),
         {:ok, rt} <- Runtime.new(program, Keyword.take(opts, [:seed])) do
      limit = rt.config["time_limit"]
      pace = Map.get(@paces, Keyword.get(opts, :pace, "typical"), 1.0)
      model = init_model(rt.config, rt.seed, pace)
      state = %{rt: rt, model: model, timeline: [], dropped: 0, samples: [], errors: %{}, effects: 0, ended: nil}

      state = Enum.reduce_while(0..trunc(limit), state, fn t, state -> step(state, t / 1, limit, pretend) end)
      t_end = if state.ended, do: state.ended.t, else: limit / 1
      world = world(state.model, t_end, limit)
      {rt, final} = Runtime.finish(state.rt, world, t_end)
      state = record_errors(%{state | rt: rt}, final.errors, t_end)

      # the chart ends exactly on the score shown with it
      state = %{
        state
        | samples: [sample(t_end, final.score, state.model) | Enum.reject(state.samples, &(&1.t >= t_end))]
      }

      timeline =
        if final.fired != [] or final.effects != [] or final.logs != [] do
          state.timeline ++ [entry(t_end, final)]
        else
          state.timeline
        end

      {:ok,
       %{
         config: Map.put(rt.config, "faction", Scenario.faction(rt.config, rt.seed)),
         seed: rt.seed,
         timeline: timeline,
         timeline_dropped: state.dropped,
         samples: Enum.reverse(state.samples),
         result: %{
           score: final.score,
           tiebreak: final.tiebreak,
           ended_at: t_end,
           time_left: max(limit - t_end, 0.0),
           reason: if(state.ended, do: "finished", else: "deadline"),
           message: state.ended && state.ended.message,
           end_effects: final.effects
         },
         errors: state.errors |> Map.values() |> Enum.sort_by(& &1.first_t),
         final_world: world["player"] |> Map.take(["credit", "technology", "ideology", "income"]),
         stats: %{fuel_used: rt.fuel_used, effects: state.effects},
         assumptions: %{pace: pace, economy: @default_economy, stock: default_stock()}
       }}
    end
  end

  defp step(state, t, limit, pretend) do
    model = apply_pretend(state.model, pretend, t)
    world = world(model, t, limit)
    {rt, res} = Runtime.pulse(state.rt, world, t)

    if rt.fuel_used > @max_total_fuel do
      throw_budget(state)
    end

    model = model |> apply_effects(res.effects) |> grow(t)
    state = %{state | rt: rt, model: model, effects: state.effects + length(res.effects)}
    state = record_errors(state, res.errors, t)

    state =
      if res.fired != [] or res.effects != [] or res.logs != [] do
        if length(state.timeline) >= @max_timeline,
          do: %{state | dropped: state.dropped + 1},
          else: %{state | timeline: state.timeline ++ [entry(t, res)]}
      else
        state
      end

    state =
      if rem(trunc(t), @sample_every) == 0 do
        %{state | samples: [sample(t, Runtime.peek_score(rt, world), model) | state.samples]}
      else
        state
      end

    case res.finished do
      nil -> {:cont, state}
      finished -> {:halt, %{state | ended: Map.put(finished, :t, t)}}
    end
  end

  defp sample(t, score, model) do
    %{
      t: t,
      score: score,
      credit: model.stock["credit"],
      technology: model.stock["technology"],
      ideology: model.stock["ideology"]
    }
  end

  defp throw_budget(_state) do
    raise Interpreter.Error,
      message: "the script does too much work to simulate a whole run (it would slow the game down)"
  end

  defp entry(t, res) do
    %{t: t, fired: res.fired, effects: res.effects, errors: Map.get(res, :errors, []), logs: res.logs}
  end

  # The same error every second would flood the panel: keep each distinct
  # error once, with how often and since when it happened.
  defp record_errors(state, errors, t) do
    merged =
      Enum.reduce(errors, state.errors, fn err, acc ->
        key = {err.message, err.node_id}

        Map.update(acc, key, Map.merge(err, %{count: 1, first_t: t}), fn e -> %{e | count: e.count + 1} end)
      end)

    %{state | errors: merged}
  end

  # --- the model -----------------------------------------------------------------

  defp init_model(config, seed, pace) do
    %{
      stock: default_stock(),
      economy: Map.new(@default_economy, fn {k, [a, b]} -> {k, [a * pace, b * pace]} end),
      config: config,
      faction: Scenario.faction(config, seed),
      stability: 10.0,
      agents_sent: 0,
      overrides: %{}
    }
  end

  defp income(model, t, limit) do
    progress = if limit > 0, do: min(t / limit, 1.0), else: 1.0
    Map.new(model.economy, fn {k, [a, b]} -> {k, a + (b - a) * progress} end)
  end

  defp grow(model, t) do
    limit = model.config["time_limit"]
    per_second = income(model, t, limit) |> Map.new(fn {k, v} -> {k, v / @seconds_per_day} end)
    %{model | stock: Map.new(model.stock, fn {k, v} -> {k, v + per_second[k]} end)}
  end

  defp world(model, t, limit) do
    income = income(model, t, limit)

    home = %{
      "id" => 1.0,
      "name" => "Home",
      "home" => true,
      "population" => 15.0 + 25.0 * min(t / max(limit, 1), 1.0),
      "housing" => 20.0 + 30.0 * min(t / max(limit, 1), 1.0),
      "stability" => model.stability,
      "production" => 20.0 + 180.0 * min(t / max(limit, 1), 1.0),
      "intelligence" => 10.0 + 90.0 * min(t / max(limit, 1), 1.0),
      "defense" => 0.0,
      "income" => income
    }

    base = %{
      "time" => %{"elapsed" => t, "left" => max(limit - t, 0.0), "limit" => limit / 1},
      "player" => %{
        "name" => "You",
        "faction" => model.faction,
        "credit" => model.stock["credit"],
        "technology" => model.stock["technology"],
        "ideology" => model.stock["ideology"],
        "income" => income,
        "systems" => [home],
        "systems_owned" => 1.0,
        "dominions" => 0.0,
        "population" => home["population"],
        "agents" => [],
        "patents" => model.config["grant_patents"],
        "wonders" => [],
        "agents_removed" => 0.0
      },
      "rival" => %{
        "present" => model.config["rival"] == true,
        "faction" => if(model.config["rival"], do: "rival", else: nil),
        "agents_sent" => model.agents_sent / 1,
        "agents_left" => model.agents_sent / 1
      },
      "scenario" => %{
        "name" => model.config["name"],
        "systems" => model.config["systems"] / 1,
        "time_limit" => limit / 1
      }
    }

    Enum.reduce(model.overrides, base, fn {path, value}, world -> put_in(world, path, value) end)
  end

  defp apply_effects(model, effects), do: Enum.reduce(effects, model, &apply_effect/2)

  defp apply_effect(%{"action" => "give", "args" => %{"resource" => r, "amount" => n}}, model),
    do: update_in(model.stock[r], &(&1 + n))

  defp apply_effect(%{"action" => "take", "args" => %{"resource" => r, "amount" => n}}, model),
    do: update_in(model.stock[r], &(&1 - n))

  defp apply_effect(%{"action" => "destabilize", "args" => %{"amount" => n}}, model),
    do: %{model | stability: model.stability - n}

  defp apply_effect(%{"action" => "send_agent"}, model), do: %{model | agents_sent: model.agents_sent + 1}
  defp apply_effect(_effect, model), do: model

  # --- pretend ---------------------------------------------------------------------

  defp parse_pretend(list) when is_list(list) and length(list) <= 20 do
    Enum.reduce_while(list, {:ok, []}, fn item, {:ok, acc} ->
      with %{"at" => at, "path" => path, "value" => value} when is_number(at) and is_binary(path) <- item,
           segments = String.split(path, "."),
           type when type != nil <- Catalog.world_type(segments),
           true <- pretend_value?(value) do
        {:cont, {:ok, acc ++ [%{at: at / 1, path: segments, value: normalize(value)}]}}
      else
        _ ->
          {:halt,
           {:error,
            [
              %{
                message: "a pretend entry needs a time, a world path such as player.credit, and a plain value",
                node_id: nil,
                at: nil
              }
            ]}}
      end
    end)
  end

  defp parse_pretend(_), do: {:error, [%{message: "pretend takes a list of at most 20 entries", node_id: nil, at: nil}]}

  defp pretend_value?(v) when is_number(v) or is_binary(v) or is_boolean(v), do: true
  defp pretend_value?(v) when is_list(v), do: length(v) <= 50 and Enum.all?(v, &(is_number(&1) or is_binary(&1)))
  defp pretend_value?(_), do: false

  defp normalize(v) when is_integer(v), do: v / 1
  defp normalize(v) when is_list(v), do: Enum.map(v, &normalize/1)
  defp normalize(v), do: v

  defp apply_pretend(model, pretend, t) do
    case Enum.filter(pretend, &(&1.at <= t)) do
      [] -> model
      due -> %{model | overrides: Map.new(due, &{&1.path, &1.value})}
    end
  end
end
