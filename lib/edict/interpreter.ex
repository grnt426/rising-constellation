defmodule Edict.Interpreter do
  @moduledoc """
  Evaluates Edict trees.

  The interpreter is a closed world. It walks the tree and dispatches on a
  fixed set of node kinds, builtins and actions, all written into this module
  as explicit clauses: there is no `apply/3`, no dynamic module or function
  name, no atom built from input, no access to processes, files, the network,
  the clock or the game. A script reaches the game in exactly two ways:

    * it **reads** the world, a plain data snapshot (records, lists, numbers
      and text) the host builds before each pulse and passes in;
    * it **acts** by calling an action, which only appends a description of
      the effect (`%{"action" => "give", "args" => ...}`) to a list. The host
      validates and applies that list after the script has finished.

  So evaluation is a pure function from (tree, world, state) to (state,
  effects): deterministic, replayable, and testable without a game.

  Every step spends fuel (`Edict.Limits.fuel_per_pulse/0` per pulse); list
  and text builtins spend one unit per element they touch. Numbers are
  floats capped at `Edict.Limits.max_number/0`; lists, records and text have
  size caps; user function calls nest at most `max_call_depth` deep. Breaking
  any of these raises a script error, never a crash of the host.
  """

  alias Edict.{Catalog, Limits, Printer}

  defmodule Ctx do
    @moduledoc false
    # mode: :handler (actions allowed) | :pure (score, conditions, vars) |
    #       :setup (setup block: no world, no actions)
    defstruct fuel: 0,
              depth: 0,
              effects: [],
              effect_count: 0,
              logs: [],
              globals: %{},
              fns: %{},
              world: nil,
              mode: :pure,
              seed: "",
              rand_n: 0
  end

  defmodule Error do
    @moduledoc false
    # out_of_fuel: the error is the step budget running out, so the whole
    # pulse's budget is spent (the host must not hand the rest to others)
    defexception [:message, :node_id, :at, out_of_fuel: false]
  end

  # --- entry points ----------------------------------------------------------

  @doc "A fresh context. `fns` maps names to `fn` declarations."
  def new_ctx(opts \\ []) do
    %Ctx{
      fuel: Keyword.get(opts, :fuel, Limits.fuel_per_pulse()),
      fns: Keyword.get(opts, :fns, %{}),
      globals: Keyword.get(opts, :globals, %{}),
      world: Keyword.get(opts, :world),
      mode: Keyword.get(opts, :mode, :pure),
      seed: Keyword.get(opts, :seed, "")
    }
  end

  @doc """
  Run a list of statements (a handler body) with `bindings` as its first
  frame. Returns `{:ok, ctx}` or `{:error, %Error{}, ctx}`.
  """
  def run_block(stmts, bindings, %Ctx{} = ctx) do
    guard(ctx, fn ->
      {_env, ctx} = exec_block(stmts, [bindings], ctx)
      ctx
    end)
  end

  @doc "Evaluate one expression. Returns `{:ok, value, ctx}` or `{:error, %Error{}, ctx}`."
  def eval_expr(expr, %Ctx{} = ctx) do
    case guard(ctx, fn -> eval(expr, [%{}], ctx) end) do
      {:ok, {value, ctx}} -> {:ok, value, ctx}
      {:error, error, ctx} -> {:error, error, ctx}
    end
  end

  @doc """
  Run a setup block: every statement must set a setup field. Returns
  `{:ok, %{field => value}, ctx}` or `{:error, %Error{}, ctx}`.
  """
  def run_setup(stmts, %Ctx{} = ctx) do
    ctx = %{ctx | mode: :setup, world: nil}

    case guard(ctx, fn -> exec_block_flat(stmts, [%{}], ctx) end) do
      {:ok, {[frame | _], ctx}} -> {:ok, frame, ctx}
      {:error, error, ctx} -> {:error, error, ctx}
    end
  end

  # Errors, control flow escaping a function, and the BEAM's own arithmetic
  # errors all end up as a script error here. Anything else is a bug in the
  # interpreter and is re-raised.
  defp guard(ctx, fun) do
    {:ok, fun.()}
  rescue
    e in Error -> {:error, e, ctx}
    ArithmeticError -> {:error, %Error{message: "a calculation went out of range"}, ctx}
  catch
    {:edict_return, _value, _env, ctx} -> {:error, %Error{message: "return can only be used inside a fn"}, ctx}
    {:edict_loop, kind, _env, ctx} -> {:error, %Error{message: "#{kind} can only be used inside a loop"}, ctx}
  end

  defp fail(message, node) do
    raise Error, message: message, node_id: node_id(node), at: node_at(node)
  end

  defp node_id(%{id: id}), do: id
  defp node_id(_), do: nil
  defp node_at(%{at: at}), do: at
  defp node_at(_), do: nil

  defp spend(%Ctx{fuel: fuel} = ctx, n, node) do
    if fuel < n do
      raise Error,
        message: "the script ran out of steps (#{Limits.fuel_per_pulse()} per second); look for a loop that never ends",
        node_id: node_id(node),
        at: node_at(node),
        out_of_fuel: true
    end

    %{ctx | fuel: fuel - n}
  end

  # --- statements ------------------------------------------------------------

  defp exec_block(stmts, env, ctx) do
    {[_ | env], ctx} = exec_block_flat(stmts, [%{} | env], ctx)
    {env, ctx}
  end

  # run statements in the given (already pushed) frame
  defp exec_block_flat(stmts, env, ctx), do: Enum.reduce(stmts, {env, ctx}, fn s, {env, ctx} -> exec(s, env, ctx) end)

  defp exec(%{k: :note}, env, ctx), do: {env, ctx}

  defp exec(stmt, env, ctx) do
    ctx = spend(ctx, 1, stmt)
    run(stmt, env, ctx)
  end

  defp run(%{k: :let, name: name, expr: e}, [frame | rest], ctx) do
    {value, ctx} = eval(e, [frame | rest], ctx)
    {[Map.put(frame, name, value) | rest], ctx}
  end

  # In setup, `name = value` declares a setup field.
  defp run(%{k: :assign, target: %{k: :ident, name: name}, expr: e} = stmt, [frame | rest], %Ctx{mode: :setup} = ctx) do
    unless name in Catalog.setup_names(), do: fail("#{name} isn't a setup field", stmt)
    {value, ctx} = eval(e, [frame | rest], ctx)
    {[Map.put(frame, name, value) | rest], ctx}
  end

  defp run(%{k: :assign} = stmt, _env, %Ctx{mode: :setup}),
    do: fail("setup only takes lines of the form field = value", stmt)

  defp run(%{k: :assign, target: target, expr: e} = stmt, env, ctx) do
    {value, ctx} = eval(e, env, ctx)
    {root, path} = target_path(target)
    {current, where} = lookup_var(root, env, ctx, stmt)
    {updated, ctx} = set_path(current, path, value, env, ctx, stmt)
    store_var(root, updated, where, env, ctx, stmt)
  end

  defp run(%{k: :if, cond: c, then: then_body, else: else_body}, env, ctx) do
    {test, ctx} = eval(c, env, ctx)

    case truth(test, c, "if") do
      true -> exec_block(then_body, env, ctx)
      false when is_list(else_body) -> exec_block(else_body, env, ctx)
      false -> {env, ctx}
    end
  end

  defp run(%{k: :for, var: var, iter: iter, body: body} = stmt, env, ctx) do
    {items, ctx} = eval(iter, env, ctx)

    unless is_list(items) do
      fail(
        "for … in needs a list, but this is #{type_name(items)}#{if is_map(items), do: " (use keys() or values())", else: ""}",
        iter
      )
    end

    loop_items(items, var, body, env, ctx, stmt)
  end

  defp run(%{k: :while, cond: c, body: body} = stmt, env, ctx) do
    loop_while(c, body, env, ctx, stmt)
  end

  defp run(%{k: :return, expr: nil}, env, ctx), do: throw({:edict_return, nil, env, ctx})

  defp run(%{k: :return, expr: e}, env, ctx) do
    {value, ctx} = eval(e, env, ctx)
    throw({:edict_return, value, env, ctx})
  end

  defp run(%{k: :break}, env, ctx), do: throw({:edict_loop, :break, env, ctx})
  defp run(%{k: :continue}, env, ctx), do: throw({:edict_loop, :continue, env, ctx})

  defp run(%{k: :expr, expr: e}, env, ctx) do
    {_value, ctx} = eval(e, env, ctx)
    {env, ctx}
  end

  defp run(stmt, _env, _ctx), do: fail("this can't be used as a statement", stmt)

  # A loop body runs in its own frame; break and continue arrive as throws
  # carrying the environment as it was, so assignments made before them stick.
  defp loop_items([], _var, _body, env, ctx, _stmt), do: {env, ctx}

  defp loop_items([item | rest], var, body, env, ctx, stmt) do
    ctx = spend(ctx, 1, stmt)

    case loop_step(fn -> exec_block_flat(body, [%{var => item} | env], ctx) end, env) do
      {:next, env, ctx} -> loop_items(rest, var, body, env, ctx, stmt)
      {:stop, env, ctx} -> {env, ctx}
    end
  end

  defp loop_while(c, body, env, ctx, stmt) do
    ctx = spend(ctx, 1, stmt)
    {test, ctx} = eval(c, env, ctx)

    if truth(test, c, "while") do
      case loop_step(fn -> exec_block_flat(body, [%{} | env], ctx) end, env) do
        {:next, env, ctx} -> loop_while(c, body, env, ctx, stmt)
        {:stop, env, ctx} -> {env, ctx}
      end
    else
      {env, ctx}
    end
  end

  defp loop_step(fun, outer) do
    {inner, ctx} = fun.()
    {:next, restore(inner, outer), ctx}
  catch
    {:edict_loop, :break, inner, ctx} -> {:stop, restore(inner, outer), ctx}
    {:edict_loop, :continue, inner, ctx} -> {:next, restore(inner, outer), ctx}
  end

  # The frames the loop was entered with, as updated by the body.
  defp restore(inner, outer), do: Enum.take(inner, -length(outer))

  # --- variables -------------------------------------------------------------

  defp target_path(%{k: :ident, name: name}), do: {name, []}

  defp target_path(%{k: :field, obj: obj, name: name}) do
    {root, path} = target_path(obj)
    {root, path ++ [{:field, name}]}
  end

  defp target_path(%{k: :index, obj: obj, index: index}) do
    {root, path} = target_path(obj)
    {root, path ++ [{:index, index}]}
  end

  defp lookup_var(name, env, ctx, node) do
    case Enum.find_index(env, &Map.has_key?(&1, name)) do
      nil ->
        cond do
          Map.has_key?(ctx.globals, name) ->
            {Map.fetch!(ctx.globals, name), :global}

          name in Catalog.world_roots() ->
            fail("#{name} is part of the game and can't be changed directly; use an action", node)

          true ->
            fail("#{name} doesn't exist yet; make it with let #{name} = …", node)
        end

      index ->
        {Map.fetch!(Enum.at(env, index), name), {:local, index}}
    end
  end

  defp store_var(name, value, :global, env, ctx, node) do
    if ctx.mode != :handler do
      fail("a var can only be changed by a handler (on, every, at, when), not by a score or a condition", node)
    end

    {env, %{ctx | globals: Map.put(ctx.globals, name, value)}}
  end

  defp store_var(name, value, {:local, index}, env, ctx, _node) do
    {List.update_at(env, index, &Map.put(&1, name, value)), ctx}
  end

  defp set_path(_current, [], value, _env, ctx, _node), do: {value, ctx}

  defp set_path(current, [{:field, name} | rest], value, env, ctx, node) do
    unless is_map(current), do: fail("can't set .#{name} on #{type_name(current)}", node)
    {inner, ctx} = set_path(Map.get(current, name), rest, value, env, ctx, node)
    updated = Map.put(current, name, inner)
    check_map_size(updated, node)
    {updated, ctx}
  end

  defp set_path(current, [{:index, index_expr} | rest], value, env, ctx, node) do
    {index, ctx} = eval(index_expr, env, ctx)

    cond do
      is_list(current) ->
        i = list_index(index, length(current), index_expr)
        if i == nil, do: fail("position #{Printer.plain(index)} is outside the list", node)
        {inner, ctx} = set_path(Enum.at(current, i), rest, value, env, ctx, node)
        {List.replace_at(current, i, inner), ctx}

      is_map(current) and is_binary(index) ->
        {inner, ctx} = set_path(Map.get(current, index), rest, value, env, ctx, node)
        updated = Map.put(current, index, inner)
        check_map_size(updated, node)
        {updated, ctx}

      true ->
        fail("can't set [#{to_text(index)}] on #{type_name(current)}", node)
    end
  end

  # --- expressions -----------------------------------------------------------

  defp eval(node, env, ctx) do
    ctx = spend(ctx, 1, node)
    ev(node, env, ctx)
  end

  defp ev(%{k: :num, v: v}, _env, ctx), do: {v, ctx}
  defp ev(%{k: :str, v: v}, _env, ctx), do: {v, ctx}
  defp ev(%{k: :bool, v: v}, _env, ctx), do: {v, ctx}
  defp ev(%{k: :nil_lit}, _env, ctx), do: {nil, ctx}
  defp ev(%{k: :hole} = node, _env, _ctx), do: fail("a value is missing here (?)", node)

  defp ev(%{k: :tmpl, parts: parts} = node, env, ctx) do
    {pieces, ctx} =
      Enum.map_reduce(parts, ctx, fn
        text, ctx when is_binary(text) -> {text, ctx}
        e, ctx -> with {v, ctx} <- eval(e, env, ctx), do: {to_text(v), ctx}
      end)

    text = IO.iodata_to_binary(pieces)
    check_text(text, node)
    {text, spend(ctx, div(byte_size(text), 64), node)}
  end

  defp ev(%{k: :ident, name: name} = node, env, ctx), do: {resolve(name, env, ctx, node), ctx}

  defp ev(%{k: :field, obj: obj, name: name} = node, env, ctx) do
    {value, ctx} = eval(obj, env, ctx)
    {field(value, name, node), ctx}
  end

  defp ev(%{k: :index, obj: obj, index: i} = node, env, ctx) do
    {value, ctx} = eval(obj, env, ctx)
    {index, ctx} = eval(i, env, ctx)

    result =
      cond do
        is_list(value) ->
          case list_index(index, length(value), i) do
            nil -> nil
            at -> Enum.at(value, at)
          end

        is_map(value) and is_binary(index) ->
          Map.get(value, index)

        is_binary(value) and is_number(index) ->
          case list_index(index, String.length(value), i) do
            nil -> nil
            at -> String.at(value, at)
          end

        value == nil ->
          fail("can't look up [#{to_text(index)}] in nothing (nil)", node)

        true ->
          fail("can't look up [#{to_text(index)}] in #{type_name(value)}", node)
      end

    {result, ctx}
  end

  defp ev(%{k: :call} = node, env, ctx), do: call(node, env, ctx)

  defp ev(%{k: :bin, op: "and", l: l, r: r}, env, ctx) do
    {a, ctx} = eval(l, env, ctx)

    if truth(a, l, "and") do
      {b, ctx} = eval(r, env, ctx)
      {truth(b, r, "and"), ctx}
    else
      {false, ctx}
    end
  end

  defp ev(%{k: :bin, op: "or", l: l, r: r}, env, ctx) do
    {a, ctx} = eval(l, env, ctx)

    if truth(a, l, "or") do
      {true, ctx}
    else
      {b, ctx} = eval(r, env, ctx)
      {truth(b, r, "or"), ctx}
    end
  end

  defp ev(%{k: :bin, op: op, l: l, r: r} = node, env, ctx) do
    {a, ctx} = eval(l, env, ctx)
    {b, ctx} = eval(r, env, ctx)
    binary(op, a, b, node, ctx)
  end

  defp ev(%{k: :un, op: "not", e: e}, env, ctx) do
    {v, ctx} = eval(e, env, ctx)
    {not truth(v, e, "not"), ctx}
  end

  defp ev(%{k: :un, op: "-", e: e} = node, env, ctx) do
    {v, ctx} = eval(e, env, ctx)
    unless is_number(v), do: fail("can't negate #{type_name(v)}", node)
    {-v, ctx}
  end

  defp ev(%{k: :list, items: items} = node, env, ctx) do
    {values, ctx} = Enum.map_reduce(items, ctx, &eval(&1, env, &2))
    check_list(values, node)
    {values, ctx}
  end

  defp ev(%{k: :map, entries: entries} = node, env, ctx) do
    {pairs, ctx} =
      Enum.map_reduce(entries, ctx, fn %{key: key, value: v}, ctx ->
        {value, ctx} = eval(v, env, ctx)
        {{key, value}, ctx}
      end)

    record = Map.new(pairs)
    check_map_size(record, node)
    {record, ctx}
  end

  defp ev(%{k: :lambda, params: params, body: body}, env, ctx), do: {{:closure, params, body, env}, ctx}

  defp ev(%{k: :cond, cond: c, then: a, else: b}, env, ctx) do
    {test, ctx} = eval(c, env, ctx)
    if truth(test, c, "if"), do: eval(a, env, ctx), else: eval(b, env, ctx)
  end

  defp ev(node, _env, _ctx), do: fail("this can't be used as a value", node)

  # A name, as a value: a local or var, else a function (to pass to map and
  # friends), else a part of the world.
  defp resolve(name, env, ctx, node) do
    case Enum.find(env, &Map.has_key?(&1, name)) do
      %{} = frame ->
        Map.fetch!(frame, name)

      nil ->
        cond do
          Map.has_key?(ctx.globals, name) ->
            Map.fetch!(ctx.globals, name)

          Map.has_key?(ctx.fns, name) ->
            {:fn_ref, name}

          Catalog.builtin(name) != nil ->
            {:builtin_ref, name}

          name in Catalog.world_roots() ->
            world_root(name, ctx, node)

          Catalog.action(name) != nil ->
            fail("#{name} is an action: call it with #{name}(…)", node)

          true ->
            fail("unknown name #{name}", node)
        end
    end
  end

  defp world_root(name, %Ctx{world: nil}, node),
    do: fail("#{name} can't be read here: the game hasn't started when setup, vars and schedules are worked out", node)

  defp world_root(name, %Ctx{world: world}, _node), do: Map.get(world, name)

  defp field(value, name, node) do
    cond do
      is_map(value) ->
        Map.get(value, name)

      value == nil ->
        fail("can't read .#{name} of nothing (nil)", node)

      is_list(value) ->
        fail("a list has no .#{name}#{if name in ["length", "size", "count"], do: "; use len(list)", else: ""}", node)

      true ->
        fail("#{type_name(value)} has no .#{name}", node)
    end
  end

  defp truth(true, _node, _where), do: true
  defp truth(false, _node, _where), do: false
  defp truth(v, node, where), do: fail("#{where} needs true or false, but this is #{type_name(v)}", node)

  # --- operators -------------------------------------------------------------

  defp binary("+", a, b, node, ctx) when is_number(a) and is_number(b), do: {num(a + b, node), ctx}

  defp binary("+", a, b, node, ctx) when is_binary(a) or is_binary(b) do
    text = to_text(a) <> to_text(b)
    check_text(text, node)
    {text, spend(ctx, div(byte_size(text), 64), node)}
  end

  defp binary("+", a, b, node, ctx) when is_list(a) and is_list(b) do
    joined = a ++ b
    check_list(joined, node)
    {joined, spend(ctx, length(joined), node)}
  end

  defp binary("-", a, b, node, ctx) when is_number(a) and is_number(b), do: {num(a - b, node), ctx}
  defp binary("*", a, b, node, ctx) when is_number(a) and is_number(b), do: {num(a * b, node), ctx}

  defp binary("/", _a, b, node, _ctx) when b == 0, do: fail("division by zero", node)
  defp binary("/", a, b, node, ctx) when is_number(a) and is_number(b), do: {num(a / b, node), ctx}

  defp binary(op, a, b, _node, ctx) when op in ["==", "!="] do
    equal = a == b
    {if(op == "==", do: equal, else: not equal), ctx}
  end

  defp binary(op, a, b, node, ctx) when op in ["<", "<=", ">", ">="] do
    unless (is_number(a) and is_number(b)) or (is_binary(a) and is_binary(b)) do
      fail("can't compare #{type_name(a)} with #{type_name(b)} using #{op}", node)
    end

    result =
      case op do
        "<" -> a < b
        "<=" -> a <= b
        ">" -> a > b
        ">=" -> a >= b
      end

    {result, ctx}
  end

  defp binary("in", a, b, node, ctx) do
    cond do
      is_list(b) -> {Enum.member?(b, a), spend(ctx, length(b), node)}
      is_binary(b) and is_binary(a) -> {String.contains?(b, a), ctx}
      is_map(b) and is_binary(a) -> {Map.has_key?(b, a), ctx}
      true -> fail("x in y needs a list, a text or a record on the right, but this is #{type_name(b)}", node)
    end
  end

  defp binary(op, a, b, node, _ctx),
    do: fail("can't use #{op} on #{type_name(a)} and #{type_name(b)}", node)

  defp num(x, node) do
    if abs(x) > Limits.max_number(), do: fail("a number grew too large (over a million billion)", node)
    x / 1
  end

  # --- calls -----------------------------------------------------------------

  defp call(%{fn: %{k: :ident, name: name}} = node, env, ctx) do
    # a local holding a function wins over a function of the same name
    case Enum.find(env, &Map.has_key?(&1, name)) do
      %{} = frame ->
        {args, named, ctx} = call_args(node, env, ctx)
        no_named!(named, node)
        apply_value(Map.fetch!(frame, name), args, node, ctx)

      nil ->
        cond do
          Map.has_key?(ctx.fns, name) ->
            {args, named, ctx} = call_args(node, env, ctx)
            call_fn(name, args, named, node, ctx)

          Catalog.builtin(name) != nil ->
            {args, named, ctx} = call_args(node, env, ctx)
            no_named!(named, node)
            builtin(name, args, node, ctx)

          Catalog.action(name) != nil ->
            {args, named, ctx} = call_args(node, env, ctx)
            action(name, args, named, node, ctx)

          Map.has_key?(ctx.globals, name) ->
            {args, named, ctx} = call_args(node, env, ctx)
            no_named!(named, node)
            apply_value(Map.fetch!(ctx.globals, name), args, node, ctx)

          true ->
            fail("unknown function #{name}", node)
        end
    end
  end

  defp call(%{fn: callee} = node, env, ctx) do
    {f, ctx} = eval(callee, env, ctx)
    {args, named, ctx} = call_args(node, env, ctx)
    no_named!(named, node)
    apply_value(f, args, node, ctx)
  end

  defp call_args(%{args: args, named: named}, env, ctx) do
    {values, ctx} = Enum.map_reduce(args, ctx, &eval(&1, env, &2))

    {named, ctx} =
      Enum.map_reduce(named, ctx, fn %{name: name, expr: e}, ctx ->
        {v, ctx} = eval(e, env, ctx)
        {{name, v}, ctx}
      end)

    {values, named, ctx}
  end

  defp no_named!([], _node), do: :ok
  defp no_named!([{name, _} | _], node), do: fail("#{name}: can only be given to an action or a fn", node)

  defp apply_value({:closure, params, body, closure_env}, args, node, ctx) do
    if length(args) != length(params) do
      fail("this function takes #{length(params)} value(s) but got #{length(args)}", node)
    end

    ctx = enter(ctx, node)
    {value, ctx} = eval(body, [Map.new(Enum.zip(params, args)) | closure_env], ctx)
    {value, leave(ctx)}
  end

  defp apply_value({:fn_ref, name}, args, node, ctx), do: call_fn(name, args, [], node, ctx)
  defp apply_value({:builtin_ref, name}, args, node, ctx), do: builtin(name, args, node, ctx)
  defp apply_value(other, _args, node, _ctx), do: fail("#{type_name(other)} can't be called like a function", node)

  defp call_fn(name, args, named, node, ctx) do
    %{params: params, body: body} = Map.fetch!(ctx.fns, name)

    if length(args) > length(params) do
      fail("#{name} takes #{length(params)} value(s) but got #{length(args)}", node)
    end

    bound = Map.new(Enum.zip(params, args))

    bound =
      Enum.reduce(named, bound, fn {key, value}, acc ->
        cond do
          key not in params -> fail("#{name} has no parameter called #{key}", node)
          Map.has_key?(acc, key) -> fail("#{key} is given twice", node)
          true -> Map.put(acc, key, value)
        end
      end)

    missing = Enum.reject(params, &Map.has_key?(bound, &1))
    if missing != [], do: fail("#{name} is missing #{Enum.join(missing, ", ")}", node)

    ctx = enter(ctx, node)

    try do
      {_env, ctx} = exec_block_flat(body, [bound], ctx)
      {nil, leave(ctx)}
    catch
      {:edict_return, value, _env, ctx} -> {value, leave(ctx)}
      # a break in a fn's own body must not escape into the caller's loop
      {:edict_loop, kind, _env, _ctx} -> fail("#{kind} can only be used inside a loop", node)
    end
  end

  defp enter(ctx, node) do
    if ctx.depth >= Limits.max_call_depth() do
      fail(
        "functions call each other too deeply (#{Limits.max_call_depth()} levels); is one calling itself forever?",
        node
      )
    end

    %{ctx | depth: ctx.depth + 1}
  end

  defp leave(ctx), do: %{ctx | depth: ctx.depth - 1}

  # --- builtins ----------------------------------------------------------------

  defp builtin(name, args, node, ctx) do
    %{params: params} = Catalog.builtin(name)
    check_arity(name, params, args, node)
    bi(name, args, node, ctx)
  end

  defp check_arity(name, params, args, node) do
    required = Enum.count(params, &(not &1.optional))
    rest? = Enum.any?(params, & &1.rest)
    max = if rest?, do: :infinity, else: length(params)

    cond do
      length(args) < required ->
        fail("#{name} needs #{required} value(s) but got #{length(args)}", node)

      max != :infinity and length(args) > max ->
        fail("#{name} takes at most #{max} value(s) but got #{length(args)}", node)

      true ->
        :ok
    end
  end

  # math
  defp bi("abs", [x], node, ctx), do: {abs(number!(x, node)), ctx}
  defp bi("floor", [x], node, ctx), do: {Float.floor(number!(x, node)), ctx}
  defp bi("ceil", [x], node, ctx), do: {Float.ceil(number!(x, node)), ctx}
  defp bi("trunc", [x], node, ctx), do: {trunc(number!(x, node)) / 1, ctx}
  defp bi("round", [x], node, ctx), do: {Float.round(number!(x, node)), ctx}

  defp bi("round", [x, d], node, ctx) do
    digits = trunc(number!(d, node))
    if digits < 0 or digits > 10, do: fail("round keeps 0 to 10 decimals", node)
    {Float.round(number!(x, node), digits), ctx}
  end

  defp bi("sqrt", [x], node, ctx) do
    x = number!(x, node)
    if x < 0, do: fail("can't take the square root of a negative number", node)
    {:math.sqrt(x), ctx}
  end

  defp bi("pow", [x, y], node, ctx), do: {num(:math.pow(number!(x, node), number!(y, node)), node), ctx}

  defp bi(name, values, node, ctx) when name in ["min", "max"] do
    list =
      case values do
        [l] when is_list(l) -> l
        _ -> values
      end

    if list == [], do: fail("#{name} needs at least one value", node)
    Enum.each(list, &number!(&1, node))
    ctx = spend(ctx, length(list), node)
    {if(name == "min", do: Enum.min(list), else: Enum.max(list)), ctx}
  end

  defp bi("clamp", [x, lo, hi], node, ctx) do
    {x, lo, hi} = {number!(x, node), number!(lo, node), number!(hi, node)}
    if lo > hi, do: fail("clamp's low is above its high", node)
    {x |> max(lo) |> min(hi), ctx}
  end

  defp bi("mod", [x, y], node, ctx) do
    {x, y} = {number!(x, node), number!(y, node)}
    if y == 0, do: fail("mod by zero", node)
    {x - y * Float.floor(x / y), ctx}
  end

  defp bi("lerp", [a, b, t], node, ctx),
    do: {num(number!(a, node) + (number!(b, node) - number!(a, node)) * number!(t, node), node), ctx}

  # text
  defp bi("str", [v], node, ctx), do: {checked_text(to_text(v), node), ctx}
  defp bi("upper", [t], node, ctx), do: {String.upcase(text!(t, node)), ctx}
  defp bi("lower", [t], node, ctx), do: {String.downcase(text!(t, node)), ctx}
  defp bi("join", [l], node, ctx), do: bi("join", [l, ""], node, ctx)

  defp bi("join", [l, sep], node, ctx) do
    list = list!(l, node)
    text = Enum.map_join(list, text!(sep, node), &to_text/1)
    {checked_text(text, node), spend(ctx, length(list), node)}
  end

  defp bi("fmt_time", [s], node, ctx) do
    total = s |> number!(node) |> max(0) |> trunc()
    {"#{div(total, 60)}:#{total |> rem(60) |> Integer.to_string() |> String.pad_leading(2, "0")}", ctx}
  end

  defp bi("fmt_number", [x], node, ctx) do
    whole = x |> number!(node) |> Float.round() |> trunc()
    sign = if whole < 0, do: "-", else: ""

    digits =
      whole
      |> abs()
      |> Integer.to_string()
      |> String.reverse()
      |> String.to_charlist()
      |> Enum.chunk_every(3)
      |> Enum.join(",")
      |> String.reverse()

    {sign <> digits, ctx}
  end

  # lists
  defp bi("len", [v], node, ctx) do
    cond do
      is_list(v) -> {length(v) / 1, ctx}
      is_binary(v) -> {String.length(v) / 1, ctx}
      is_map(v) -> {map_size(v) / 1, ctx}
      true -> fail("len needs a list, a text or a record, but this is #{type_name(v)}", node)
    end
  end

  defp bi("first", [l], node, ctx), do: {List.first(list!(l, node)), ctx}
  defp bi("last", [l], node, ctx), do: {List.last(list!(l, node)), ctx}
  defp bi("range", [to], node, ctx), do: bi("range", [1.0, to], node, ctx)

  defp bi("range", [from, to], node, ctx) do
    {a, b} = {trunc(number!(from, node)), trunc(number!(to, node))}
    count = max(b - a + 1, 0)
    if count > Limits.max_list(), do: fail("range would make #{count} items (#{Limits.max_list()} at most)", node)
    ctx = spend(ctx, count, node)
    {if(count == 0, do: [], else: Enum.map(a..b, &(&1 / 1))), ctx}
  end

  defp bi("push", [l, item], node, ctx) do
    list = list!(l, node) ++ [item]
    check_list(list, node)
    {list, spend(ctx, length(list), node)}
  end

  defp bi("concat", [a, b], node, ctx) do
    list = list!(a, node) ++ list!(b, node)
    check_list(list, node)
    {list, spend(ctx, length(list), node)}
  end

  defp bi("reverse", [l], node, ctx), do: {Enum.reverse(list!(l, node)), spend(ctx, length(l), node)}
  defp bi("slice", [l, start], node, ctx), do: bi("slice", [l, start, Limits.max_list() / 1], node, ctx)

  defp bi("slice", [l, start, count], node, ctx) do
    list = list!(l, node)
    {s, c} = {trunc(number!(start, node)), trunc(number!(count, node))}
    if s < 0 or c < 0, do: fail("slice needs a start and count of 0 or more", node)
    {Enum.slice(list, s, c), spend(ctx, length(list), node)}
  end

  defp bi("contains", [haystack, needle], node, ctx) do
    cond do
      is_list(haystack) -> {Enum.member?(haystack, needle), spend(ctx, length(haystack), node)}
      is_binary(haystack) and is_binary(needle) -> {String.contains?(haystack, needle), ctx}
      true -> fail("contains needs a list or a text first", node)
    end
  end

  defp bi("unique", [l], node, ctx), do: {Enum.uniq(list!(l, node)), spend(ctx, length(l), node)}

  defp bi("sort", [l], node, ctx) do
    list = list!(l, node)
    sortable!(list, node)
    {Enum.sort(list), spend(ctx, length(list) * 2, node)}
  end

  defp bi("sum", [l], node, ctx) do
    list = list!(l, node)
    Enum.each(list, &number!(&1, node))
    {num(Enum.sum([0.0 | list]), node), spend(ctx, length(list), node)}
  end

  defp bi("sum", [l, f], node, ctx) do
    {values, ctx} = map_each(list!(l, node), f, node, ctx)
    bi("sum", [values], node, ctx)
  end

  defp bi("count", [l], node, ctx), do: {length(list!(l, node)) / 1, ctx}

  defp bi("count", [l, f], node, ctx) do
    {tests, ctx} = map_each(list!(l, node), f, node, ctx)
    {Enum.count(tests, &truth(&1, node, "count's function")) / 1, ctx}
  end

  defp bi("map", [l, f], node, ctx), do: map_each(list!(l, node), f, node, ctx)

  defp bi("filter", [l, f], node, ctx) do
    list = list!(l, node)
    {tests, ctx} = map_each(list, f, node, ctx)
    {for({item, test} <- Enum.zip(list, tests), truth(test, node, "filter's function"), do: item), ctx}
  end

  defp bi("find", [l, f], node, ctx) do
    Enum.reduce_while(list!(l, node), {nil, ctx}, fn item, {_, ctx} ->
      {test, ctx} = apply_value(f, [item], node, ctx)
      if truth(test, node, "find's function"), do: {:halt, {item, ctx}}, else: {:cont, {nil, ctx}}
    end)
  end

  defp bi("any", [l], node, ctx), do: {Enum.any?(list!(l, node), &truth(&1, node, "any")), ctx}
  defp bi("all", [l], node, ctx), do: {Enum.all?(list!(l, node), &truth(&1, node, "all")), ctx}

  defp bi("any", [l, f], node, ctx) do
    Enum.reduce_while(list!(l, node), {false, ctx}, fn item, {_, ctx} ->
      {test, ctx} = apply_value(f, [item], node, ctx)
      if truth(test, node, "any's function"), do: {:halt, {true, ctx}}, else: {:cont, {false, ctx}}
    end)
  end

  defp bi("all", [l, f], node, ctx) do
    Enum.reduce_while(list!(l, node), {true, ctx}, fn item, {_, ctx} ->
      {test, ctx} = apply_value(f, [item], node, ctx)
      if truth(test, node, "all's function"), do: {:cont, {true, ctx}}, else: {:halt, {false, ctx}}
    end)
  end

  defp bi("sort_by", [l, f], node, ctx) do
    list = list!(l, node)
    {keys, ctx} = map_each(list, f, node, ctx)
    sortable!(keys, node)
    sorted = list |> Enum.zip(keys) |> Enum.sort_by(&elem(&1, 1)) |> Enum.map(&elem(&1, 0))
    {sorted, spend(ctx, length(list) * 2, node)}
  end

  defp bi(name, [l, f], node, ctx) when name in ["max_by", "min_by"] do
    list = list!(l, node)
    {keys, ctx} = map_each(list, f, node, ctx)
    sortable!(keys, node)

    case Enum.zip(list, keys) do
      [] -> {nil, ctx}
      pairs when name == "max_by" -> {pairs |> Enum.max_by(&elem(&1, 1)) |> elem(0), ctx}
      pairs -> {pairs |> Enum.min_by(&elem(&1, 1)) |> elem(0), ctx}
    end
  end

  # records
  defp bi("keys", [r], node, ctx), do: {r |> record!(node) |> Map.keys() |> Enum.sort(), spend(ctx, map_size(r), node)}

  defp bi("values", [r], node, ctx) do
    record = record!(r, node)
    {record |> Enum.sort_by(&elem(&1, 0)) |> Enum.map(&elem(&1, 1)), spend(ctx, map_size(record), node)}
  end

  defp bi("get", [r, k], node, ctx), do: bi("get", [r, k, nil], node, ctx)
  defp bi("get", [r, k, default], node, ctx), do: {Map.get(record!(r, node), text!(k, node), default), ctx}

  defp bi("put", [r, k, v], node, ctx) do
    record = Map.put(record!(r, node), text!(k, node), v)
    check_map_size(record, node)
    {record, spend(ctx, map_size(record), node)}
  end

  defp bi("has", [r, k], node, ctx), do: {Map.has_key?(record!(r, node), text!(k, node)), ctx}

  # chance
  defp bi("random", keys, _node, ctx), do: roll(keys, ctx)

  defp bi("random_int", [lo, hi | keys], node, ctx) do
    {lo, hi} = {Float.ceil(number!(lo, node)), Float.floor(number!(hi, node))}
    if lo > hi, do: fail("random_int's low is above its high", node)
    {r, ctx} = roll(["int" | keys], ctx)
    {lo + Float.floor(r * (hi - lo + 1)), ctx}
  end

  defp bi("chance", [p | keys], node, ctx) do
    p = number!(p, node)
    {r, ctx} = roll(["chance" | keys], ctx)
    {r < p, ctx}
  end

  defp bi("pick", [l | keys], node, ctx) do
    case list!(l, node) do
      [] ->
        {nil, ctx}

      list ->
        {r, ctx} = roll(["pick" | keys], ctx)
        {Enum.at(list, trunc(r * length(list))), ctx}
    end
  end

  defp bi(name, args, node, _ctx), do: fail("#{name} can't take #{length(args)} value(s)", node)

  defp map_each(list, f, node, ctx) do
    ctx = spend(ctx, length(list), node)
    Enum.map_reduce(list, ctx, fn item, ctx -> apply_value(f, [item], node, ctx) end)
  end

  # A number in [0, 1) fixed by the scenario's seed and the keys. With no keys
  # the run's own counter stands in, so repeated calls differ but replay the
  # same way.
  defp roll([], ctx), do: roll(["seq", ctx.rand_n / 1], %{ctx | rand_n: ctx.rand_n + 1})

  defp roll(keys, ctx) do
    material = Enum.map_join([ctx.seed | Enum.map(keys, &to_text/1)], <<0>>, & &1)
    <<bits::unsigned-size(53), _::bitstring>> = :crypto.hash(:sha256, material)
    {bits / 9_007_199_254_740_992, ctx}
  end

  # --- actions -------------------------------------------------------------------

  defp action(name, args, named, node, ctx) do
    if ctx.mode != :handler do
      where =
        case ctx.mode do
          :setup -> "setup"
          _ -> "a score, a condition or a var's starting value"
        end

      fail("#{name}() changes the game, so it can't be used in #{where}", node)
    end

    sig = Catalog.action(name)
    check_arity(name, sig.params, args, node)

    positional =
      sig.params
      |> Enum.zip(args)
      |> Map.new(fn {param, value} -> {param.name, check_arg(name, param, value, node)} end)

    named_values =
      Map.new(named, fn {key, value} ->
        case Enum.find(sig.named, &(&1.name == key)) do
          nil ->
            choices = Enum.map_join(sig.named, ", ", &(&1.name <> ":"))
            fail("#{name} has no #{key}:#{if choices != "", do: " (it takes #{choices})", else: ""}", node)

          param ->
            {key, check_arg(name, param, value, node)}
        end
      end)

    effect = %{"action" => name, "args" => Map.merge(positional, named_values), "node" => node_id(node)}

    if name == "log" do
      {nil, %{ctx | logs: [%{"value" => Map.get(positional, "value"), "node" => node_id(node)} | ctx.logs]}}
    else
      if ctx.effect_count >= Limits.max_effects_per_pulse() do
        fail("too many actions at once (#{Limits.max_effects_per_pulse()} per second at most)", node)
      end

      {nil, %{ctx | effects: [effect | ctx.effects], effect_count: ctx.effect_count + 1}}
    end
  end

  defp check_arg(action, %{name: pname, type: type}, value, node) do
    value = typed!(type, value, "#{action}'s #{pname}", node)

    case get_in(Catalog.action_limits(), [action, pname]) do
      {lo, hi} when is_number(value) ->
        if value < lo or value > hi do
          fail("#{action}'s #{pname} must be between #{Printer.plain(lo / 1)} and #{Printer.plain(hi / 1)}", node)
        end

        value

      _ ->
        value
    end
  end

  defp typed!({:enum, values}, v, what, node) do
    if v in values, do: v, else: fail("#{what} must be one of #{Enum.map_join(values, ", ", &inspect/1)}", node)
  end

  defp typed!("number", v, what, node), do: if(is_number(v), do: v, else: fail("#{what} must be a number", node))
  defp typed!("text", v, what, node), do: if(is_binary(v), do: v, else: fail("#{what} must be text", node))
  defp typed!(_any, v, _what, _node), do: v

  # --- value helpers ---------------------------------------------------------------

  # Always a float: world values may arrive as integers, and the Float
  # functions only take floats.
  defp number!(v, _node) when is_number(v), do: v / 1
  defp number!(v, node), do: fail("expected a number but got #{type_name(v)}", node)
  defp text!(v, _node) when is_binary(v), do: v
  defp text!(v, node), do: fail("expected text but got #{type_name(v)}", node)
  defp list!(v, _node) when is_list(v), do: v
  defp list!(v, node), do: fail("expected a list but got #{type_name(v)}", node)
  defp record!(v, _node) when is_map(v) and not is_struct(v), do: v
  defp record!(v, node), do: fail("expected a record but got #{type_name(v)}", node)

  defp sortable!(list, node) do
    unless Enum.all?(list, &is_number/1) or Enum.all?(list, &is_binary/1) do
      fail("can only sort numbers or texts, not a mix", node)
    end
  end

  defp list_index(index, size, node) do
    i = number!(index, node)
    if i != Float.round(i / 1), do: fail("a position must be a whole number", node)
    i = trunc(i)
    i = if i < 0, do: size + i, else: i
    if i >= 0 and i < size, do: i, else: nil
  end

  defp check_text(text, node) do
    if byte_size(text) > Limits.max_string(),
      do: fail("a text grew too long (#{Limits.max_string()} characters at most)", node)
  end

  defp checked_text(text, node) do
    check_text(text, node)
    text
  end

  defp check_list(list, node) do
    if length(list) > Limits.max_list(), do: fail("a list grew too long (#{Limits.max_list()} items at most)", node)
  end

  defp check_map_size(map, node) do
    if map_size(map) > Limits.max_map(), do: fail("a record grew too large (#{Limits.max_map()} keys at most)", node)
  end

  @doc "How a value reads as text (str(), templates, joining with +)."
  def to_text(v) when is_binary(v), do: v
  def to_text(v) when is_number(v), do: Printer.plain(v / 1)
  def to_text(true), do: "true"
  def to_text(false), do: "false"
  def to_text(nil), do: "nil"

  def to_text(v) when is_list(v),
    do: "[" <> Enum.map_join(Enum.take(v, 50), ", ", &short_text/1) <> if(length(v) > 50, do: ", …]", else: "]")

  def to_text(v) when is_map(v) do
    "{" <> (v |> Enum.sort() |> Enum.take(30) |> Enum.map_join(", ", fn {k, x} -> "#{k}: #{short_text(x)}" end)) <> "}"
  end

  def to_text(_), do: "<fn>"

  defp short_text(v) when is_binary(v), do: inspect(v)
  defp short_text(v), do: to_text(v)

  @doc "A value's kind, as error messages name it."
  def type_name(v) when is_number(v), do: "a number"
  def type_name(v) when is_binary(v), do: "text"
  def type_name(v) when is_boolean(v), do: "true/false"
  def type_name(nil), do: "nothing (nil)"
  def type_name(v) when is_list(v), do: "a list"
  def type_name(v) when is_map(v), do: "a record"
  def type_name(_), do: "a function"
end
