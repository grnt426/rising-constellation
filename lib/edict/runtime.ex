defmodule Edict.Runtime do
  @moduledoc """
  Runs a scenario script over the course of a run: works out its setup, its
  starting state and its schedule, then fires its handlers pulse by pulse.

  The runtime is pure. A host calls `pulse/3` about once a second with the
  world as it is (`Edict.World` builds it from a live game; the simulator
  builds a model of one) and the run's elapsed seconds; it gets back the
  updated runtime and what happened: the effects to apply, the handlers that
  fired, errors and log lines. When the run ends, `finish/3` counts the
  score and runs the `on end` handlers. The live runner and the simulator
  share all of this, so what the editor simulates is what the game runs.

  ## Semantics a scenario author can rely on

    * **Snapshot reads.** The world is read once per pulse. Effects apply
      after the pulse, so a handler doesn't see its own `give()` in
      `player.credit` until the next second.
    * **Atomic handlers.** A handler that fails (a script error, or running
      out of steps) leaves no trace: its effects are dropped and its `var`
      changes undone. A handler that fails three times is switched off.
    * **Catch-up.** `every` counts from the run's start, so a late pulse runs
      the occurrences it missed (up to 10 at once) and every run sees the
      same sequence; `as n` numbers them 1, 2, 3 …
    * **Edges.** `when` fires on the pulse its condition turns true, then
      waits for it to turn false before it can fire again.
    * **Order.** Handlers run in the order they're written; after `finish()`
      no further handler runs that pulse.
  """

  alias Edict.{Interpreter, Limits, Printer}
  alias Edict.Interpreter.Error

  defstruct program: nil,
            config: %{},
            globals: %{},
            fns: %{},
            score: nil,
            tiebreak: nil,
            handlers: [],
            seed: "",
            started?: false,
            finished: nil,
            fuel_used: 0,
            # keyless random()/chance()/pick() calls so far: each second's
            # rolls follow on from the last's instead of repeating them
            rand_n: 0

  @max_catch_up 10
  @max_failures 3

  @doc """
  Prepare a program for a run. Returns `{:ok, runtime}` or `{:error, errors}`
  (a list of `%{message, node_id, at}`). Options: `:seed` (overrides the
  script's own).
  """
  def new(%{k: :program, decls: decls} = program, opts \\ []) do
    fns = for %{k: :fn, name: name} = d <- decls, into: %{}, do: {name, d}
    setup_stmts = for %{k: :setup, body: body} <- decls, s <- body, do: s

    with {:ok, config} <- run_setup(setup_stmts, fns),
         seed = seed_for(opts, config, program),
         {:ok, globals} <- init_vars(decls, fns, seed),
         {:ok, handlers} <- init_handlers(decls, fns, globals, seed) do
      {:ok,
       %__MODULE__{
         program: program,
         config: config,
         globals: globals,
         fns: fns,
         score: Enum.find_value(decls, &(&1.k == :score && &1.expr)),
         tiebreak: Enum.find_value(decls, &(&1.k == :tiebreak && &1.expr)),
         handlers: handlers,
         seed: seed
       }}
    end
  end

  defp run_setup(stmts, fns) do
    ctx = Interpreter.new_ctx(fuel: Limits.fuel_for_setup(), fns: fns, mode: :setup)

    case Interpreter.run_setup(stmts, ctx) do
      {:ok, fields, _ctx} -> Edict.Scenario.config(fields)
      {:error, error, _ctx} -> {:error, [diag(error)]}
    end
  end

  # Every player of a scenario must face the same rolls, so the seed is the
  # setup's `seed` if it has one, else the scenario's name. Not a digest of
  # the whole script: an author fixing a typo in a description shouldn't see
  # every roll change (the usability sessions tripped on that).
  defp seed_for(opts, config, _program) do
    case Keyword.get(opts, :seed) || Map.get(config, "seed") do
      nil -> "name:" <> (Map.get(config, "name") || "untitled")
      seed -> Interpreter.to_text(seed)
    end
  end

  defp init_vars(decls, fns, seed) do
    Enum.reduce_while(decls, {:ok, %{}}, fn
      %{k: :var, name: name, expr: e}, {:ok, globals} ->
        ctx = Interpreter.new_ctx(fuel: Limits.fuel_for_setup(), fns: fns, globals: globals, seed: seed)

        case Interpreter.eval_expr(e, ctx) do
          {:ok, value, _ctx} -> {:cont, {:ok, Map.put(globals, name, value)}}
          {:error, error, _ctx} -> {:halt, {:error, [diag(error)]}}
        end

      _, acc ->
        {:cont, acc}
    end)
  end

  defp init_handlers(decls, fns, globals, seed) do
    eval_time = fn e ->
      ctx = Interpreter.new_ctx(fuel: Limits.fuel_for_setup(), fns: fns, globals: globals, seed: seed)

      case Interpreter.eval_expr(e, ctx) do
        {:ok, v, _} when is_number(v) ->
          {:ok, v / 1}

        {:ok, v, _} ->
          {:error,
           %Error{
             message: "a time must be a number of seconds, not #{Interpreter.type_name(v)}",
             node_id: e.id,
             at: Map.get(e, :at)
           }}

        {:error, error, _} ->
          {:error, error}
      end
    end

    decls
    |> Enum.filter(&(&1.k in [:on, :every, :at, :when]))
    |> Enum.reduce_while({:ok, []}, fn decl, {:ok, acc} ->
      case handler(decl, eval_time) do
        {:ok, h} -> {:cont, {:ok, [h | acc]}}
        {:error, error} -> {:halt, {:error, [diag(error)]}}
      end
    end)
    |> case do
      {:ok, handlers} -> {:ok, Enum.reverse(handlers)}
      error -> error
    end
  end

  defp handler(%{k: :on, event: event} = d, _eval_time) do
    {:ok, base(d, if(event == "start", do: :start, else: :end))}
  end

  defp handler(%{k: :every} = d, eval_time) do
    with {:ok, interval} <- eval_time.(d.interval),
         :ok <- at_least(interval, 1.0, d.interval, "every needs an interval of at least 1s"),
         {:ok, from} <- opt_time(d.from, eval_time, interval),
         {:ok, until} <- opt_time(d.until, eval_time, nil) do
      {:ok, Map.merge(base(d, :every), %{interval: interval, next_due: from, until: until, as: d.as})}
    end
  end

  defp handler(%{k: :at} = d, eval_time) do
    with {:ok, time} <- eval_time.(d.time) do
      {:ok, Map.put(base(d, :at), :time, time)}
    end
  end

  defp handler(%{k: :when} = d, _eval_time), do: {:ok, Map.merge(base(d, :when), %{cond: d.cond, armed?: true})}

  defp base(d, kind),
    do: %{id: d.id, kind: kind, label: label(d), body: d.body, count: 0, failures: 0, off?: false, decl: d}

  # How a handler reads in a timeline: its head as written ("every 3m from
  # 10m as visit", "at 21m", "when player.credit > 1000"), so two timers can
  # be told apart.
  defp label(%{k: :on, event: event}), do: "on #{event}"

  defp label(%{k: :every} = d) do
    "every " <>
      Printer.print_expr(d.interval) <>
      if(d.from, do: " from " <> Printer.print_expr(d.from), else: "") <>
      if(d.until, do: " until " <> Printer.print_expr(d.until), else: "") <>
      if(d.as, do: " as " <> d.as, else: "")
  end

  defp label(%{k: :at, time: t}), do: "at " <> Printer.print_expr(t)
  defp label(%{k: :when, cond: c}), do: "when " <> String.slice(Printer.print_expr(c), 0, 50)

  defp opt_time(nil, _eval_time, default), do: {:ok, default}
  defp opt_time(e, eval_time, _default), do: eval_time.(e)

  defp at_least(v, min, _node, _msg) when v >= min, do: :ok
  defp at_least(_v, _min, node, msg), do: {:error, %Error{message: msg, node_id: node.id, at: Map.get(node, :at)}}

  # --- pulses ------------------------------------------------------------------

  @doc """
  Run every handler that is due at `t` (seconds since the start). Returns
  `{runtime, result}` where result has `:effects` (in order), `:fired`
  (`%{id, kind, n}`), `:errors`, `:logs` and `:finished` (nil, or
  `%{message}` when the script called finish()).
  """
  def pulse(%__MODULE__{finished: f} = rt, _world, _t) when f != nil, do: {rt, empty_result()}

  def pulse(%__MODULE__{} = rt, world, t) do
    ctx =
      Interpreter.new_ctx(
        fns: rt.fns,
        globals: rt.globals,
        world: world,
        mode: :handler,
        seed: rt.seed,
        rand_n: rt.rand_n
      )

    acc = %{ctx: ctx, fired: [], errors: [], finished: nil, starved: 0}

    {handlers, acc} =
      Enum.map_reduce(rt.handlers, acc, fn h, acc ->
        cond do
          h.off? or acc.finished -> {h, acc}
          # the budget is gone: the rest wait for the next second, unblamed
          acc.ctx.fuel <= 0 -> {h, %{acc | starved: acc.starved + 1}}
          true -> due(h, t, acc)
        end
      end)

    acc =
      if acc.starved > 0 do
        note = %{
          message: "#{acc.starved} handler(s) didn't run this second: the script used up its steps",
          node_id: nil,
          at: nil,
          t: t
        }

        %{acc | errors: [note | acc.errors]}
      else
        acc
      end

    ctx = acc.ctx
    effects = Enum.reverse(ctx.effects)

    {globals, errors} =
      if :erlang.external_size(ctx.globals) > Limits.max_state_bytes() do
        {rt.globals,
         [
           %{
             message:
               "the script's vars grew too large (#{div(Limits.max_state_bytes(), 1024)} KB at most); this second's changes were undone",
             node_id: nil,
             at: nil,
             t: t
           }
         ]}
      else
        {ctx.globals, []}
      end

    finished = acc.finished || finish_effect(effects)

    rt = %{
      rt
      | handlers: handlers,
        globals: globals,
        started?: true,
        finished: if(finished, do: Map.put(finished, :t, t), else: nil),
        fuel_used: rt.fuel_used + (Limits.fuel_per_pulse() - ctx.fuel),
        rand_n: ctx.rand_n
    }

    {rt,
     %{
       effects: effects,
       fired: Enum.reverse(acc.fired),
       errors: Enum.reverse(acc.errors) ++ errors,
       logs: Enum.reverse(ctx.logs),
       finished: finished
     }}
  end

  defp empty_result, do: %{effects: [], fired: [], errors: [], logs: [], finished: nil}

  defp finish_effect(effects) do
    Enum.find_value(effects, fn
      %{"action" => "finish", "args" => args} -> %{message: Map.get(args, "message")}
      _ -> nil
    end)
  end

  defp due(%{kind: :start, count: 0} = h, t, acc), do: fire(h, %{}, t, acc)
  defp due(%{kind: :start} = h, _t, acc), do: {h, acc}
  defp due(%{kind: :end} = h, _t, acc), do: {h, acc}

  defp due(%{kind: :at, count: 0, time: time} = h, t, acc) when t >= time, do: fire(h, %{}, t, acc)
  defp due(%{kind: :at} = h, _t, acc), do: {h, acc}

  defp due(%{kind: :every} = h, t, acc), do: catch_up(h, t, acc, 0)

  defp due(%{kind: :when} = h, t, acc) do
    case test(h.cond, acc) do
      {:ok, true, acc} when h.armed? ->
        {h, acc} = fire(h, %{}, t, acc)
        {%{h | armed?: false}, acc}

      {:ok, true, acc} ->
        {h, acc}

      {:ok, false, acc} ->
        {%{h | armed?: true}, acc}

      {:error, error, acc} ->
        failed(h, error, t, acc)
    end
  end

  defp catch_up(h, t, acc, done) do
    cond do
      done >= @max_catch_up or h.off? or acc.finished != nil or acc.ctx.fuel <= 0 ->
        {h, acc}

      h.next_due > t ->
        {h, acc}

      h.until != nil and h.next_due > h.until ->
        {h, acc}

      true ->
        bindings = if h.as, do: %{h.as => (h.count + 1) / 1}, else: %{}
        {h, acc} = fire(h, bindings, t, acc)
        catch_up(%{h | next_due: h.next_due + h.interval}, t, acc, done + 1)
    end
  end

  # A condition is evaluated in pure mode: it may read but not act.
  defp test(cond_expr, acc) do
    ctx = %{acc.ctx | mode: :pure}

    case Interpreter.eval_expr(cond_expr, ctx) do
      {:ok, v, ctx} when is_boolean(v) ->
        {:ok, v, %{acc | ctx: %{ctx | mode: :handler}}}

      {:ok, v, ctx} ->
        error = %Error{
          message: "when needs true or false, but this is #{Interpreter.type_name(v)}",
          node_id: cond_expr.id,
          at: Map.get(cond_expr, :at)
        }

        {:error, error, %{acc | ctx: %{ctx | mode: :handler}}}

      {:error, error, _ctx} ->
        {:error, error, %{acc | ctx: spent(acc.ctx, error)}}
    end
  end

  # Run one handler body atomically: on error, its effects and var changes
  # are dropped (only the fuel it burnt stays spent).
  defp fire(h, bindings, t, acc) do
    before = acc.ctx

    case Interpreter.run_block(h.body, bindings, before) do
      {:ok, ctx} ->
        n = h.count + 1
        fired = %{id: h.id, kind: h.kind, label: h.label, n: n, t: t}

        finished =
          acc.finished || finish_effect(Enum.reverse(Enum.take(ctx.effects, ctx.effect_count - before.effect_count)))

        {%{h | count: n}, %{acc | ctx: ctx, fired: [fired | acc.fired], finished: finished}}

      {:error, error, _ctx} ->
        failed(%{h | count: h.count + 1}, error, t, %{acc | ctx: spent(before, error)})
    end
  end

  # A failed handler's own changes are dropped, but steps it burnt stay
  # spent: an error that ran out of steps used up the whole pulse. (Any
  # other error stops early, so it can't have run long.)
  defp spent(ctx, %Error{out_of_fuel: true}), do: %{ctx | fuel: 0}
  defp spent(ctx, _error), do: ctx

  defp failed(h, error, t, acc) do
    failures = h.failures + 1
    off? = failures >= @max_failures

    message =
      if off?, do: error.message <> " (this handler failed #{failures} times and is now off)", else: error.message

    err = %{message: message, node_id: error.node_id || h.id, at: error.at || Map.get(h.decl, :at), t: t, handler: h.id}
    {%{h | failures: failures, off?: off?}, %{acc | errors: [err | acc.errors]}}
  end

  # --- the end ---------------------------------------------------------------

  @doc """
  End the run: count the score and tiebreak against `world`, then run the
  `on end` handlers. Returns `{runtime, %{score, tiebreak, effects, errors,
  logs}}`. A score that fails to evaluate counts as 0 (with the error).
  """
  def finish(%__MODULE__{} = rt, world, t) do
    {score, score_errors} = measure(rt, rt.score, world)
    {tiebreak, tie_errors} = measure(rt, rt.tiebreak, world)

    ctx =
      Interpreter.new_ctx(
        fns: rt.fns,
        globals: rt.globals,
        world: world,
        mode: :handler,
        seed: rt.seed,
        rand_n: rt.rand_n
      )

    acc = %{ctx: ctx, fired: [], errors: [], finished: nil, starved: 0}

    {handlers, acc} =
      Enum.map_reduce(rt.handlers, acc, fn
        %{kind: :end, off?: false} = h, acc -> fire(h, %{}, t, acc)
        h, acc -> {h, acc}
      end)

    rt = %{rt | handlers: handlers, globals: acc.ctx.globals, finished: rt.finished || %{message: nil, t: t}}

    {rt,
     %{
       score: score,
       tiebreak: tiebreak,
       effects: acc.ctx.effects |> Enum.reverse() |> Enum.reject(&(&1["action"] == "finish")),
       fired: Enum.reverse(acc.fired),
       errors: score_errors ++ tie_errors ++ Enum.reverse(acc.errors),
       logs: Enum.reverse(acc.ctx.logs)
     }}
  end

  @doc """
  Whether the scenario is a race: its score reads `time.left`, so it only
  means something once finish() has run (before that, at the deadline, it is
  0). Live displays show the goal instead of a running number.
  """
  def race?(%__MODULE__{score: nil}), do: false

  def race?(%__MODULE__{score: score}) do
    [score | Edict.AST.nodes(score)]
    |> Enum.any?(&match?(%{k: :field, name: "left", obj: %{k: :ident, name: "time"}}, &1))
  end

  @doc "The score as it stands against `world` (for live displays and the simulator's chart)."
  def peek_score(%__MODULE__{} = rt, world) do
    {score, _} = measure(rt, rt.score, world)
    score
  end

  defp measure(_rt, nil, _world), do: {0.0, []}

  defp measure(rt, expr, world) do
    ctx = Interpreter.new_ctx(fns: rt.fns, globals: rt.globals, world: world, mode: :pure, seed: rt.seed)

    case Interpreter.eval_expr(expr, ctx) do
      {:ok, v, _} when is_number(v) ->
        {v / 1, []}

      {:ok, v, _} ->
        {0.0,
         [
           %{
             message: "the score must be a number, not #{Interpreter.type_name(v)}",
             node_id: expr.id,
             at: Map.get(expr, :at)
           }
         ]}

      {:error, error, _} ->
        {0.0, [diag(error)]}
    end
  end

  defp diag(%Error{} = e), do: %{message: e.message, node_id: e.node_id, at: e.at}
  defp diag(%{message: _} = d), do: d
end
