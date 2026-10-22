defmodule Edict.Checker do
  @moduledoc """
  Finds mistakes in a script before it runs, and says where they are.

  The checker walks the tree once with a scope and a context, and reports
  diagnostics as `%{severity: "error" | "warning", message, node_id, at}`.
  The editor shows them on the node (visual view) or the line (text view).
  It catches:

    * names that don't exist (with a "did you mean" when one is close), and
      fields the world doesn't have (`player.credt`);
    * calls with the wrong number of values, unknown `name:` values, and
      choices outside an action's list (`give("credits", …)`);
    * actions where the game can't be changed: in a score, a `when`
      condition, a var's starting value or setup, including through a `fn`
      that acts;
    * `return` outside a fn, `break` outside a loop, assigning to something
      that isn't a variable, a missing value (`?`);
    * setup fields that don't exist or hold impossible values;
    * plain type slips the checker can see without running anything
      (multiplying a list, an `if` on a number).

  Draft blocks are not checked: they're the editor's scratch space.
  """

  alias Edict.{AST, Catalog, Scenario}

  @doc "Check a program. Returns a list of diagnostics (errors first)."
  def check(%{k: :program, decls: decls}) do
    live = Enum.reject(decls, &(&1.k in [:draft, :note]))

    fns = for %{k: :fn} = d <- live, into: %{}, do: {d.name, d}
    vars = for %{k: :var} = d <- live, into: %{}, do: {d.name, d}

    top = top_level(live, fns, vars) ++ unconnected(decls)
    effectful = effectful_fns(fns, vars)

    rival? =
      Enum.any?(live, fn
        %{k: :setup, body: body} ->
          Enum.any?(body, &match?(%{k: :assign, target: %{k: :ident, name: "rival"}, expr: %{k: :bool, v: true}}, &1))

        _ ->
          false
      end)

    base = %{fns: fns, vars: vars, effectful: effectful, rival?: rival?, diags: []}

    st =
      Enum.reduce(live, base, fn decl, st ->
        decl(decl, st)
      end)

    (top ++ Enum.reverse(st.diags))
    |> Enum.uniq_by(&{&1.message, &1.node_id})
    |> Enum.sort_by(&if(&1.severity == "error", do: 0, else: 1))
  end

  defp diag(severity, message, node, fix \\ nil) do
    base = %{severity: severity, message: message, node_id: Map.get(node || %{}, :id), at: Map.get(node || %{}, :at)}
    if fix, do: Map.put(base, :fix, fix), else: base
  end

  defp err(st, message, node, fix \\ nil), do: %{st | diags: [diag("error", message, node, fix) | st.diags]}
  defp warn(st, message, node, fix \\ nil), do: %{st | diags: [diag("warning", message, node, fix) | st.diags]}

  # A one-click repair the editor can offer: set `field` of the node
  # `target` to `value` (a misspelled name, a choice outside the list).
  defp fix(_target, _field, nil), do: nil
  defp fix(%{id: id}, field, value), do: %{target: id, field: field, value: value}

  # --- the top level ------------------------------------------------------------

  defp top_level(decls, fns, vars) do
    reserved = Catalog.builtin_names() ++ Catalog.action_names() ++ Catalog.world_roots()

    dupes = fn kind ->
      decls
      |> Enum.filter(&(&1.k == kind))
      |> Enum.group_by(& &1.name)
      |> Enum.flat_map(fn {name, [_ | extra]} -> Enum.map(extra, &diag("error", "#{name} is defined twice", &1)) end)
    end

    clashes =
      Enum.flat_map(Map.values(fns) ++ Map.values(vars), fn d ->
        cond do
          d.name in reserved -> [diag("error", "#{d.name} is already a name in the game's library; choose another", d)]
          d.k == :var and Map.has_key?(fns, d.name) -> [diag("error", "#{d.name} is both a var and a fn", d)]
          true -> []
        end
      end)

    singles =
      Enum.flat_map([setup: "setup", score: "score", tiebreak: "tiebreak"], fn {kind, word} ->
        case Enum.filter(decls, &(&1.k == kind)) do
          [_, extra | _] -> [diag("error", "a script has one #{word} at most", extra)]
          _ -> []
        end
      end)

    no_score =
      if Enum.any?(decls, &(&1.k == :score)),
        do: [],
        else: [diag("warning", "there's no score yet, so players can't be ranked (add: score player.credit)", nil)]

    dupes.(:fn) ++ dupes.(:var) ++ clashes ++ singles ++ no_score
  end

  # Parts left unconnected on the canvas never run; say so on them, so a
  # loose node with a mistake in it isn't mistaken for working code.
  defp unconnected(decls) do
    decls
    |> Enum.filter(&(&1.k == :draft))
    |> Enum.flat_map(fn
      %{body: [%{k: :expr, expr: e}]} -> [e]
      %{body: [first | _]} -> [first]
      _ -> []
    end)
    |> Enum.map(&diag("warning", "not connected to anything, so it never runs", &1))
  end

  # A fn "acts" if it calls an action, changes a var, or calls a fn that acts.
  defp effectful_fns(fns, vars) do
    direct =
      for {name, d} <- fns, acts_directly?(d.body, Map.keys(vars), d.params), into: MapSet.new(), do: name

    calls = Map.new(fns, fn {name, d} -> {name, called_fns(d.body, fns)} end)

    Stream.iterate(direct, fn set ->
      Enum.reduce(calls, set, fn {name, callees}, acc ->
        if Enum.any?(callees, &MapSet.member?(set, &1)), do: MapSet.put(acc, name), else: acc
      end)
    end)
    |> Stream.chunk_every(2, 1)
    |> Enum.find(fn [a, b] -> MapSet.equal?(a, b) end)
    |> hd()
  end

  defp acts_directly?(body, var_names, params) do
    body
    |> Enum.flat_map(&[&1 | Edict.AST.nodes(&1)])
    |> Enum.any?(fn
      %{k: :call, fn: %{k: :ident, name: name}} -> Catalog.action(name) != nil and name != "log"
      %{k: :assign, target: target} -> root_name(target) in var_names and root_name(target) not in params
      _ -> false
    end)
  end

  defp called_fns(body, fns) do
    body
    |> Enum.flat_map(&[&1 | Edict.AST.nodes(&1)])
    |> Enum.flat_map(fn
      %{k: :call, fn: %{k: :ident, name: name}} -> if Map.has_key?(fns, name), do: [name], else: []
      %{k: :ident, name: name} -> if Map.has_key?(fns, name), do: [name], else: []
      _ -> []
    end)
  end

  defp root_name(%{k: :ident, name: name}), do: name
  defp root_name(%{obj: obj}), do: root_name(obj)
  defp root_name(_), do: nil

  # --- declarations -------------------------------------------------------------

  # ctx: mode (:setup | :pure | :handler | :fn), world? (may read the world),
  # in_fn?, in_loop?, scopes (list of %{name => type}).
  defp ctx(mode, world?, scopes \\ [%{}]),
    do: %{mode: mode, world?: world?, in_fn?: mode == :fn, in_loop?: false, scopes: scopes}

  defp decl(%{k: :setup, body: body}, st), do: setup(body, st)

  defp decl(%{k: kind, expr: e}, st) when kind in [:score, :tiebreak] do
    {type, st} = expr(e, ctx(:pure, true), st)

    if known?(type) and type != :number,
      do: err(st, "the #{kind} must be a number, but this is #{type_word(type)}", e),
      else: st
  end

  defp decl(%{k: :var, expr: e}, st), do: e |> expr(ctx(:pure, false), st) |> elem(1)

  defp decl(%{k: :fn, params: params, body: body}, st) do
    scope = Map.new(params, &{&1, :any})
    block(body, ctx(:fn, true, [scope]), st)
  end

  defp decl(%{k: :on, body: body}, st), do: block(body, ctx(:handler, true), st)

  defp decl(%{k: :every} = d, st) do
    st = timing(d.interval, st)
    st = if d.from, do: timing(d.from, st), else: st
    st = if d.until, do: timing(d.until, st), else: st

    st =
      case d.interval do
        %{k: :num, v: v} when v < 1 -> err(st, "every needs an interval of at least 1s", d.interval)
        _ -> st
      end

    scope = if d.as, do: %{d.as => :number}, else: %{}
    block(d.body, ctx(:handler, true, [scope]), st)
  end

  defp decl(%{k: :at, time: t, body: body}, st), do: block(body, ctx(:handler, true), timing(t, st))

  defp decl(%{k: :when, cond: c, body: body}, st) do
    {type, st} = expr(c, ctx(:pure, true), st)

    st =
      if known?(type) and type != :bool,
        do: err(st, "when needs a condition (true or false), but this is #{type_word(type)}", c),
        else: st

    block(body, ctx(:handler, true), st)
  end

  defp decl(_, st), do: st

  defp timing(e, st) do
    {type, st} = expr(e, ctx(:pure, false), st)

    if known?(type) and type != :number,
      do: err(st, "a time must be a number of seconds (such as 15s or 2m)", e),
      else: st
  end

  # --- setup ----------------------------------------------------------------------

  defp setup(body, st) do
    {_, st} =
      Enum.reduce(body, {MapSet.new(), st}, fn
        %{k: :note}, acc ->
          acc

        %{k: :assign, target: %{k: :ident, name: name}, expr: e} = s, {seen, st} ->
          st =
            cond do
              name not in Catalog.setup_names() ->
                err(st, "#{name} isn't a setup field#{suggest(name, Catalog.setup_names())}", s)

              MapSet.member?(seen, name) ->
                warn(st, "#{name} is set twice; the last one counts", s)

              true ->
                st
            end

          {_, st} = expr(e, ctx(:setup, false), st)
          st = setup_value(name, e, st)
          {MapSet.put(seen, name), st}

        other, {seen, st} ->
          {seen, err(st, "setup only takes lines of the form field = value", other)}
      end)

    st
  end

  # A list of patents or mutators: each item on its own, so a slip gets its
  # "did you mean" and a one-click fix; a patent's internal key ("capital_1")
  # still works but is better written by name ("armoring").
  defp setup_value(name, %{k: :list, items: items} = e, st) when name in ["grant_patents", "mutators"] do
    {known, what} =
      if name == "mutators", do: {Catalog.mutator_keys(), "mutator"}, else: {Catalog.patent_names(), "patent"}

    {st, bad?} =
      Enum.reduce(items, {st, false}, fn
        %{k: :str, v: v} = item, {st, bad?} ->
          better = if name == "grant_patents", do: Catalog.patent_name(v)

          cond do
            v in known ->
              {st, bad?}

            better != nil ->
              {warn(
                 st,
                 "#{AST.quoted(v)} is the game's internal key; write #{inspect(better)}",
                 item,
                 fix(item, "v", better)
               ), bad?}

            true ->
              {err(
                 st,
                 "#{AST.quoted(v)} isn't a #{what}#{suggest(v, known)}",
                 item,
                 fix(item, "v", best_match(v, known))
               ), true}
          end

        _other, acc ->
          acc
      end)

    # what's left (how many) is the setup's own rule
    if bad?, do: st, else: setup_value(:whole, name, e, st)
  end

  defp setup_value("patent_discounts", %{k: :map, entries: entries} = e, st) do
    legacy = for %{key: k} <- entries, (name = Catalog.patent_name(k)) != nil and name != k, do: {k, name}

    st =
      Enum.reduce(legacy, st, fn {k, name}, st ->
        warn(st, "#{AST.quoted(k)} is the game's internal key; write #{name}", e)
      end)

    setup_value(:whole, "patent_discounts", e, st)
  end

  defp setup_value(name, e, st), do: setup_value(:whole, name, e, st)

  # When the value is written out literally, check it against the field now.
  defp setup_value(:whole, name, e, st) do
    with true <- name in Catalog.setup_names(),
         {:ok, value} <- constant(e),
         {:error, [%{message: message} | _]} <- Scenario.config(%{name => value}) do
      err(st, message, e)
    else
      _ -> st
    end
  end

  defp constant(%{k: k, v: v}) when k in [:num, :str, :bool], do: {:ok, v}
  defp constant(%{k: :nil_lit}), do: {:ok, nil}

  defp constant(%{k: :list, items: items}) do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, acc} ->
      case constant(item) do
        {:ok, v} -> {:cont, {:ok, acc ++ [v]}}
        :error -> {:halt, :error}
      end
    end)
  end

  defp constant(%{k: :map, entries: entries}) do
    Enum.reduce_while(entries, {:ok, %{}}, fn %{key: k, value: v}, {:ok, acc} ->
      case constant(v) do
        {:ok, value} -> {:cont, {:ok, Map.put(acc, k, value)}}
        :error -> {:halt, :error}
      end
    end)
  end

  defp constant(_), do: :error

  # --- statements ---------------------------------------------------------------------

  defp block(stmts, ctx, st) do
    ctx = %{ctx | scopes: [%{} | ctx.scopes]}
    {_ctx, st} = Enum.reduce(stmts, {ctx, st}, fn s, {ctx, st} -> stmt(s, ctx, st) end)
    st
  end

  defp stmt(%{k: :note}, ctx, st), do: {ctx, st}

  defp stmt(%{k: :let, name: name, expr: e} = s, ctx, st) do
    {type, st} = expr(e, ctx, st)

    st =
      cond do
        name in Catalog.world_roots() ->
          err(st, "#{name} is part of the game; pick another name for this variable", s)

        Catalog.builtin(name) != nil or Catalog.action(name) != nil ->
          err(st, "#{name} is a function in the game's library; pick another name", s)

        Map.has_key?(st.fns, name) ->
          err(st, "#{name} is one of your fns; pick another name", s)

        true ->
          st
      end

    [scope | rest] = ctx.scopes
    {%{ctx | scopes: [Map.put(scope, name, type) | rest]}, st}
  end

  defp stmt(%{k: :assign, target: target, expr: e} = s, ctx, st) do
    {_type, st} = expr(e, ctx, st)
    root = root_name(target)

    st =
      cond do
        root == nil ->
          err(st, "only a variable (or a field of one) can be set with =", s)

        local_type(ctx, root) != nil ->
          index_parts(target, ctx, st)

        Map.has_key?(st.vars, root) ->
          index_parts(target, ctx, st)

        root in Catalog.world_roots() ->
          err(
            st,
            "#{root} is part of the game and can't be changed directly; use an action such as give() or take()",
            s
          )

        true ->
          err(st, "#{root} doesn't exist yet; make it with let #{root} = …", s)
      end

    {ctx, st}
  end

  defp stmt(%{k: :if, cond: c, then: a, else: b}, ctx, st) do
    st = condition(c, ctx, st, "if")
    st = block(a, ctx, st)
    st = if b, do: block(b, ctx, st), else: st
    {ctx, st}
  end

  defp stmt(%{k: :for, var: var, iter: iter, body: body}, ctx, st) do
    {type, st} = expr(iter, ctx, st)

    st =
      if known?(type) and not match?({:list, _}, type),
        do: err(st, "for … in needs a list, but this is #{type_word(type)}", iter),
        else: st

    item = with {:list, t} <- type, do: t, else: (_ -> :any)
    inner = %{ctx | in_loop?: true, scopes: [%{var => item} | ctx.scopes]}
    {ctx, block(body, inner, st)}
  end

  defp stmt(%{k: :while, cond: c, body: body}, ctx, st) do
    st = condition(c, ctx, st, "while")
    {ctx, block(body, %{ctx | in_loop?: true}, st)}
  end

  defp stmt(%{k: :return, expr: e} = s, ctx, st) do
    st = if ctx.in_fn?, do: st, else: err(st, "return can only be used inside a fn", s)
    st = if e, do: e |> expr(ctx, st) |> elem(1), else: st
    {ctx, st}
  end

  defp stmt(%{k: kind} = s, ctx, st) when kind in [:break, :continue] do
    {ctx, if(ctx.in_loop?, do: st, else: err(st, "#{kind} can only be used inside a loop", s))}
  end

  defp stmt(%{k: :expr, expr: e} = s, ctx, st) do
    {_type, st} = expr(e, ctx, st)

    st =
      case e do
        %{k: :call} -> st
        %{k: :hole} -> st
        _ -> warn(st, "this value isn't used (did you mean to call an action, or to set a variable with =?)", s)
      end

    {ctx, st}
  end

  defp condition(c, ctx, st, word) do
    {type, st} = expr(c, ctx, st)

    if known?(type) and type != :bool,
      do: err(st, "#{word} needs true or false, but this is #{type_word(type)}", c),
      else: st
  end

  defp index_parts(%{k: :index, obj: obj, index: i}, ctx, st) do
    {_, st} = expr(i, ctx, st)
    index_parts(obj, ctx, st)
  end

  defp index_parts(%{k: :field, obj: obj}, ctx, st), do: index_parts(obj, ctx, st)
  defp index_parts(_, _ctx, st), do: st

  # --- expressions ----------------------------------------------------------------------

  # Returns {type, st}. Types: :number :text :bool :nil :fn :any
  # {:list, t} {:record, fields} {:enum, values}
  defp expr(%{k: :num}, _ctx, st), do: {:number, st}
  defp expr(%{k: :str}, _ctx, st), do: {:text, st}
  defp expr(%{k: :bool}, _ctx, st), do: {:bool, st}
  defp expr(%{k: :nil_lit}, _ctx, st), do: {nil, st}
  defp expr(%{k: :hole} = e, _ctx, st), do: {:any, err(st, "a value is missing here", e)}

  defp expr(%{k: :tmpl, parts: parts}, ctx, st) do
    st = Enum.reduce(parts, st, fn p, st -> if is_map(p), do: p |> expr(ctx, st) |> elem(1), else: st end)
    {:text, st}
  end

  defp expr(%{k: :ident, name: name} = e, ctx, st) do
    cond do
      (t = local_type(ctx, name)) != nil ->
        {t, st}

      Map.has_key?(st.vars, name) ->
        {:any, st}

      Map.has_key?(st.fns, name) or Catalog.builtin(name) != nil ->
        {:fn, st}

      name in Catalog.world_roots() ->
        if ctx.world?,
          do: {conv(Catalog.world_type([name])), st},
          else:
            {:any,
             err(st, "#{name} can't be read here: setup, vars and schedules are worked out before the game starts", e)}

      Catalog.action(name) != nil ->
        {:any, err(st, "#{name} is an action: call it with #{name}(…)", e)}

      true ->
        candidates = names_in_scope(ctx, st)

        {:any,
         err(st, "unknown name #{name}#{suggest(name, candidates)}", e, fix(e, "name", best_match(name, candidates)))}
    end
  end

  defp expr(%{k: :field, obj: obj, name: name} = e, ctx, st) do
    {type, st} = expr(obj, ctx, st)

    case type do
      {:record, fields} ->
        case Map.fetch(fields, name) do
          {:ok, t} ->
            {t, st}

          :error ->
            best = best_match(name, Map.keys(fields))

            {:any,
             err(
               st,
               "#{describe_record(obj)} has no field #{name}#{suggest(name, Map.keys(fields))}",
               e,
               fix(e, "name", best)
             )}
        end

      {:open_record, fields} ->
        {Map.get(fields, name, :any), st}

      {:list, _} ->
        {:any,
         err(st, "a list has no .#{name}#{if name in ["length", "size", "count"], do: "; use len(…)", else: ""}", e)}

      t when t in [:number, :text, :bool, :fn] ->
        {:any, err(st, "#{type_word(t)} has no .#{name}", e)}

      _ ->
        {:any, st}
    end
  end

  defp expr(%{k: :index, obj: obj, index: i}, ctx, st) do
    {type, st} = expr(obj, ctx, st)
    {_, st} = expr(i, ctx, st)

    case type do
      {:list, t} -> {t, st}
      _ -> {:any, st}
    end
  end

  defp expr(%{k: :call} = e, ctx, st), do: call(e, ctx, st)

  defp expr(%{k: :bin, op: op, l: l, r: r} = e, ctx, st) do
    {a, st} = expr(l, ctx, st)
    {b, st} = expr(r, ctx, st)

    cond do
      op in ["and", "or"] ->
        st =
          if known?(a) and a != :bool,
            do: err(st, "#{op} joins true/false values, but the left side is #{type_word(a)}", l),
            else: st

        st =
          if known?(b) and b != :bool,
            do: err(st, "#{op} joins true/false values, but the right side is #{type_word(b)}", r),
            else: st

        {:bool, st}

      op in ["==", "!="] ->
        {:bool, enum_compare(a, r, enum_compare(b, l, st))}

      op in ["<", "<=", ">", ">="] ->
        bad =
          Enum.find([{a, l}, {b, r}], fn {t, _} ->
            known?(t) and t not in [:number, :text] and not match?({:enum, _}, t)
          end)

        st =
          if bad,
            do: err(st, "#{op} compares numbers (or texts), not #{type_word(elem(bad, 0))}", elem(bad, 1)),
            else: st

        {:bool, st}

      op == "in" ->
        {:bool, st}

      op == "+" and (text?(a) or text?(b)) ->
        {:text, st}

      op == "+" and match?({:list, _}, a) and match?({:list, _}, b) ->
        {a, st}

      # a list and something not known until the script runs (a fn's
      # parameter): it may well be a list too
      op == "+" and ((match?({:list, _}, a) and not known?(b)) or (match?({:list, _}, b) and not known?(a))) ->
        {if(match?({:list, _}, a), do: a, else: b), st}

      true ->
        bad = Enum.find([{a, l}, {b, r}], fn {t, _} -> known?(t) and t != :number end)
        st = if bad, do: err(st, "#{op} works on numbers, not #{type_word(elem(bad, 0))}", e), else: st
        {:number, st}
    end
  end

  defp expr(%{k: :un, op: "not", e: x}, ctx, st) do
    {t, st} = expr(x, ctx, st)
    st = if known?(t) and t != :bool, do: err(st, "not needs true or false, but this is #{type_word(t)}", x), else: st
    {:bool, st}
  end

  defp expr(%{k: :un, op: "-", e: x}, ctx, st) do
    {t, st} = expr(x, ctx, st)
    st = if known?(t) and t != :number, do: err(st, "only a number can be negated, not #{type_word(t)}", x), else: st
    {:number, st}
  end

  defp expr(%{k: :list, items: items}, ctx, st) do
    {types, st} = Enum.map_reduce(items, st, &expr(&1, ctx, &2))
    {{:list, unify(types)}, st}
  end

  defp expr(%{k: :map, entries: entries}, ctx, st) do
    {fields, st} =
      Enum.map_reduce(entries, st, fn %{key: k, value: v}, st -> with {t, st} <- expr(v, ctx, st), do: {{k, t}, st} end)

    {{:open_record, Map.new(fields)}, st}
  end

  defp expr(%{k: :lambda} = e, ctx, st), do: lambda(e, [], ctx, st)

  defp expr(%{k: :cond, cond: c, then: a, else: b}, ctx, st) do
    st = condition(c, ctx, st, "if")
    {ta, st} = expr(a, ctx, st)
    {tb, st} = expr(b, ctx, st)
    {unify([ta, tb]), st}
  end

  defp expr(_, _ctx, st), do: {:any, st}

  defp lambda(%{params: params, body: body}, param_types, ctx, st) do
    scope = params |> Enum.with_index() |> Map.new(fn {p, i} -> {p, Enum.at(param_types, i, :any)} end)
    {type, st} = expr(body, %{ctx | scopes: [scope | ctx.scopes]}, st)
    {{:fn_returning, type}, st}
  end

  # --- calls -----------------------------------------------------------------------------

  defp call(%{fn: %{k: :ident, name: name}, args: args, named: named} = e, ctx, st) do
    cond do
      local_type(ctx, name) != nil ->
        {_, st} = args_types(args, named, ctx, st)
        {:any, st}

      Map.has_key?(st.fns, name) ->
        user_call(name, args, named, e, ctx, st)

      Catalog.builtin(name) != nil ->
        builtin_call(name, args, named, e, ctx, st)

      Catalog.action(name) != nil ->
        action_call(name, args, named, e, ctx, st)

      Map.has_key?(st.vars, name) ->
        {_, st} = args_types(args, named, ctx, st)
        {:any, st}

      true ->
        {_, st} = args_types(args, named, ctx, st)
        names = Map.keys(st.fns) ++ Catalog.builtin_names() ++ Catalog.action_names()

        {:any,
         err(st, "unknown function #{name}#{suggest(name, names)}", e, fix(e.fn, "name", best_match(name, names)))}
    end
  end

  defp call(%{fn: callee, args: args, named: named}, ctx, st) do
    {_, st} = expr(callee, ctx, st)
    {_, st} = args_types(args, named, ctx, st)
    {:any, st}
  end

  defp args_types(args, named, ctx, st) do
    {types, st} = Enum.map_reduce(args, st, &expr(&1, ctx, &2))
    {_named, st} = Enum.map_reduce(named, st, fn %{expr: x}, st -> expr(x, ctx, st) end)
    {types, st}
  end

  defp user_call(name, args, named, e, ctx, st) do
    %{params: params} = Map.fetch!(st.fns, name)
    {_, st} = args_types(args, named, ctx, st)
    given = length(args) + length(named)

    st =
      cond do
        length(args) > length(params) ->
          err(st, "#{name} takes #{length(params)} value(s) but got #{length(args)}", e)

        (bad = Enum.find(named, &(&1.name not in params))) != nil ->
          err(st, "#{name} has no parameter #{bad.name}#{suggest(bad.name, params)}", e)

        given < length(params) ->
          err(st, "#{name} needs #{Enum.join(params, ", ")} (got #{given} value(s))", e)

        true ->
          st
      end

    st =
      if MapSet.member?(st.effectful, name) and ctx.mode in [:pure, :setup],
        do:
          err(
            st,
            "#{name} changes the game (it calls an action or sets a var), so it can't be used in a #{place(ctx)}",
            e
          ),
        else: st

    {:any, st}
  end

  defp builtin_call(name, args, named, e, ctx, st) do
    sig = Catalog.builtin(name)
    st = if named != [], do: err(st, "#{name} doesn't take name: values", e), else: st

    # a lambda handed to a list function gets the list's item type for its parameter
    {types, st} =
      case args do
        [list_arg, %{k: :lambda} = lam | rest]
        when name in ~w(map filter find any all sort_by max_by min_by sum count) ->
          {lt, st} = expr(list_arg, ctx, st)
          item = with {:list, t} <- lt, do: t, else: (_ -> :any)
          {ft, st} = lambda(lam, [item], ctx, st)
          {rest_types, st} = Enum.map_reduce(rest, st, &expr(&1, ctx, &2))
          {[lt, ft | rest_types], st}

        _ ->
          Enum.map_reduce(args, st, &expr(&1, ctx, &2))
      end

    st = arity(name, sig.params, length(args), e, st)

    st =
      sig.params
      |> Enum.zip(Enum.zip(args, types))
      |> Enum.reduce(st, fn {param, {arg, type}}, st -> param_type(name, param, arg, type, st) end)

    {builtin_result(name, types, sig.returns), st}
  end

  defp builtin_result(name, [{:list, t} | _], _) when name in ~w(first last find max_by min_by pick), do: t

  defp builtin_result(name, [{:list, _} = l | _], _)
       when name in ~w(filter sort sort_by reverse slice unique push concat),
       do: l

  defp builtin_result("map", [_, {:fn_returning, t} | _], _), do: {:list, t}
  defp builtin_result("get", _, _), do: :any
  defp builtin_result(_name, _types, "number"), do: :number
  defp builtin_result(_name, _types, "text"), do: :text
  defp builtin_result(_name, _types, "bool"), do: :bool
  defp builtin_result(_name, _types, "list"), do: {:list, :any}
  defp builtin_result(_name, _types, "record"), do: {:open_record, %{}}
  defp builtin_result(_name, _types, _), do: :any

  defp action_call(name, args, named, e, ctx, st) do
    sig = Catalog.action(name)
    {types, st} = args_types(args, named, ctx, st)

    st =
      if ctx.mode in [:pure, :setup],
        do: err(st, "#{name}() changes the game, so it can't be used in a #{place(ctx)}", e),
        else: st

    st = arity(name, sig.params, length(args), e, st)

    st =
      sig.params
      |> Enum.zip(Enum.zip(args, types))
      |> Enum.reduce(st, fn {param, {arg, type}}, st -> param_type(name, param, arg, type, st) end)

    st =
      Enum.reduce(named, st, fn %{name: key, expr: x}, st ->
        case Enum.find(sig.named, &(&1.name == key)) do
          nil ->
            takes =
              if sig.named == [],
                do: " (it takes none)",
                else: " (it takes #{Enum.map_join(sig.named, ", ", &(&1.name <> ":"))})"

            err(st, "#{name} has no #{key}:#{takes}", x)

          param ->
            {t, st} = expr(x, ctx, st)
            param_type(name, param, x, t, st)
        end
      end)

    st =
      if name == "send_agent" and not st.rival?,
        do: warn(st, "send_agent needs a rival court: add rival = true to setup", e),
        else: st

    {nil, st}
  end

  defp arity(name, params, given, e, st) do
    required = Enum.count(params, &(not &1.optional))
    rest? = Enum.any?(params, & &1.rest)

    cond do
      given < required ->
        err(
          st,
          "#{name} needs #{required} value(s) (#{Enum.map_join(Enum.reject(params, & &1.optional), ", ", & &1.name)}) but got #{given}",
          e
        )

      not rest? and given > length(params) ->
        err(st, "#{name} takes at most #{length(params)} value(s) but got #{given}", e)

      true ->
        st
    end
  end

  defp param_type(fname, %{name: pname, type: {:enum, values}}, %{k: :str, v: v} = arg, _type, st) do
    if v in values,
      do: st,
      else:
        err(
          st,
          "#{fname}'s #{pname} #{choices(values)}#{suggest(v, values)}",
          arg,
          fix(arg, "v", best_match(v, values))
        )
  end

  defp param_type(fname, %{name: pname, type: expected}, arg, type, st) do
    if known?(type) and not fits?(type, expected),
      do:
        err(
          st,
          "#{fname}'s #{pname} should be #{type_word(expected_type(expected))}, but this is #{type_word(type)}",
          arg
        ),
      else: st
  end

  defp fits?(_type, "any"), do: true
  defp fits?(:number, "number"), do: true
  defp fits?(t, "text") when t in [:text], do: true
  defp fits?({:enum, _}, "text"), do: true
  defp fits?({:enum, _}, {:enum, _}), do: true
  defp fits?(:text, {:enum, _}), do: true
  defp fits?(:bool, "bool"), do: true
  defp fits?({:list, _}, "list"), do: true
  defp fits?({:record, _}, "record"), do: true
  defp fits?({:open_record, _}, "record"), do: true
  defp fits?({:fn_returning, _}, "fn"), do: true
  defp fits?(:fn, "fn"), do: true
  defp fits?(nil, _), do: true
  defp fits?(_, _), do: false

  defp expected_type("number"), do: :number
  defp expected_type("text"), do: :text
  defp expected_type("bool"), do: :bool
  defp expected_type("list"), do: {:list, :any}
  defp expected_type("record"), do: {:open_record, %{}}
  defp expected_type("fn"), do: :fn
  defp expected_type({:enum, v}), do: {:enum, v}
  defp expected_type(_), do: :any

  # "x == \"navarchh\"" against an enum can never be true: say so.
  defp enum_compare({:enum, values}, %{k: :str, v: v} = lit, st) do
    if v in values,
      do: st,
      else:
        warn(
          st,
          "this is never equal: the value is one of #{Enum.map_join(values, ", ", &inspect/1)}#{suggest(v, values)}",
          lit,
          fix(lit, "v", best_match(v, values))
        )
  end

  defp enum_compare(_type, _other, st), do: st

  # --- helpers ---------------------------------------------------------------------------

  # The catalog writes types as strings and tagged tuples; the checker's own
  # are atoms.
  defp conv("number"), do: :number
  defp conv("text"), do: :text
  defp conv("bool"), do: :bool
  defp conv({:list, t}), do: {:list, conv(t)}
  defp conv({:record, fields}), do: {:record, Map.new(fields, fn {k, t} -> {k, conv(t)} end)}
  defp conv({:enum, values}), do: {:enum, values}
  defp conv(_), do: :any

  defp local_type(ctx, name), do: Enum.find_value(ctx.scopes, &Map.get(&1, name))

  defp names_in_scope(ctx, st) do
    Enum.flat_map(ctx.scopes, &Map.keys/1) ++
      Map.keys(st.vars) ++ Map.keys(st.fns) ++ Catalog.builtin_names() ++ Catalog.world_roots()
  end

  defp known?(:any), do: false
  defp known?(nil), do: false
  defp known?(_), do: true

  defp text?(:text), do: true
  defp text?({:enum, _}), do: true
  defp text?(_), do: false

  defp unify([]), do: :any

  defp unify(types) do
    case Enum.uniq(types) do
      [t] -> t
      _ -> :any
    end
  end

  defp place(%{mode: :setup}), do: "setup"
  defp place(_), do: "score, a when condition, a var's starting value or a schedule"

  defp describe_record(%{k: :ident, name: name}), do: name
  defp describe_record(%{k: :field, obj: obj, name: name}), do: describe_record(obj) <> "." <> name
  defp describe_record(_), do: "this record"

  defp type_word(:number), do: "a number"
  defp type_word(:text), do: "text"
  defp type_word(:bool), do: "true/false"
  defp type_word(nil), do: "nil"
  defp type_word(:fn), do: "a function"
  defp type_word({:fn_returning, _}), do: "a function"
  defp type_word({:list, _}), do: "a list"
  defp type_word({:record, _}), do: "a record"
  defp type_word({:open_record, _}), do: "a record"
  defp type_word({:enum, _}), do: "text"
  defp type_word(_), do: "a value"

  defp choices([only]), do: "must be #{inspect(only)}"
  defp choices(values), do: "must be one of #{Enum.map_join(values, ", ", &inspect/1)}"

  @doc false
  def best_match(name, candidates) do
    candidates
    |> Enum.uniq()
    |> Enum.map(&{&1, String.jaro_distance(String.downcase(name), String.downcase(&1))})
    |> Enum.filter(fn {c, d} -> d >= 0.82 and c != name end)
    |> Enum.max_by(&elem(&1, 1), fn -> nil end)
    |> case do
      nil -> nil
      {best, _} -> best
    end
  end

  @doc false
  def suggest(name, candidates) do
    candidates
    |> Enum.uniq()
    |> Enum.map(&{&1, String.jaro_distance(String.downcase(name), String.downcase(&1))})
    |> Enum.filter(fn {c, d} -> d >= 0.82 and c != name end)
    |> Enum.max_by(&elem(&1, 1), fn -> nil end)
    |> case do
      nil -> ""
      {best, _} -> " (did you mean #{best}?)"
    end
  end
end
