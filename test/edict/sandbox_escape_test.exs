defmodule Edict.SandboxEscapeTest do
  @moduledoc """
  Adversarial tests: a hostile author trying to get out of the scripting
  sandbox, take the server down, or reach someone else.

  The suite is organized by attack class (see docs/scenario-scripting.md,
  "Security model"). Each test names the defense it relies on.
  """
  use ExUnit.Case, async: false

  alias Edict.{AST, Effects, Interpreter, Limits, Parser, Runtime, Sandbox, Simulator, World}

  @world %{
    "time" => %{"elapsed" => 1.0, "left" => 1799.0, "limit" => 1800.0},
    "player" => %{
      "credit" => 100.0,
      "systems" => [%{"id" => 11.0, "name" => "Home"}, %{"id" => 12.0, "name" => "Second"}]
    }
  }

  # Run `body` as an on start handler, sandboxed like the live runner does.
  defp attack(body, decls \\ "") do
    source = decls <> "\non start {\n" <> body <> "\n}\n"

    case Parser.parse(source) do
      {:error, error} ->
        {:rejected_at_parse, error.message}

      {:ok, program} ->
        case Runtime.new(program) do
          {:error, [error | _]} ->
            {:rejected_at_start, error.message}

          {:ok, rt} ->
            {:ok, {_rt, result}} = Sandbox.run(fn -> Runtime.pulse(rt, @world, 1.0) end)
            result
        end
    end
  end

  # Contained: refused outright, or ran without producing a single effect.
  defp assert_contained(result) do
    case result do
      {:rejected_at_parse, _} -> :ok
      {:rejected_at_start, _} -> :ok
      %{effects: effects} -> assert effects == []
    end
  end

  defp assert_refused(result) do
    case result do
      {:rejected_at_parse, _} -> :ok
      {:rejected_at_start, _} -> :ok
      %{effects: effects, errors: errors} -> assert effects == [] and errors != []
    end
  end

  # --- 1. No path to the host --------------------------------------------------

  describe "no path to the host (closed world: only catalog names resolve)" do
    test "Elixir and Erlang modules are not names a script can reach" do
      marker = Path.join(System.tmp_dir!(), "edict-escape-#{System.unique_integer([:positive])}")

      for body <- [
            ~s|File.write("#{marker}", "pwned")|,
            ~s|System.cmd("touch", ["#{marker}"])|,
            ~s|Code.eval_string("File.write(\\"#{marker}\\", \\"x\\")")|,
            ~s|Kernel.apply(File, "write", ["#{marker}", "x"])|,
            ~s|apply("File", "write", ["#{marker}"])|,
            ~s|spawn(x => x)|,
            ~s|send(self(), "hi")|,
            ~s|Port.open("ls")|,
            ~s|Elixir.File.rm_rf("/")|,
            ~s|eval("1 + 1")|,
            ~s|load("x")|,
            ~s|require("os")|,
            ~s|import("fs")|,
            ~s|__MODULE__|,
            ~s|player.__struct__|,
            ~s|player["__proto__"]["constructor"]("x")|
          ] do
        result = attack(body)
        assert_contained(result)

        # anything that names the host is refused, not silently nil
        unless body =~ "__struct__", do: assert_refused(result)
      end

      refute File.exists?(marker)
    end

    test "Erlang syntax for atoms and remote calls doesn't even lex" do
      for body <- [~s|:os.cmd('id')|, ~s|:erlang.halt()|, ~s|&File.read/1|, ~s|@attr|, ~s|`ls`|, ~s|$HOME|] do
        assert {:rejected_at_parse, _} = attack(body)
      end
    end

    test "the catalog is an allowlist: any new name must be reviewed here" do
      assert Enum.sort(Edict.Catalog.builtin_names()) ==
               Enum.sort(~w(abs floor ceil trunc round sqrt pow min max clamp mod lerp str upper lower join fmt_time
                 fmt_number len first last range push concat reverse slice contains unique sort sum count map
                 filter find any all sort_by max_by min_by keys values get put has random random_int chance pick))

      assert Enum.sort(Edict.Catalog.action_names()) ==
               Enum.sort(~w(give take notify finish end_match destabilize send_agent log))
    end

    test "the evaluator modules don't call anything that touches the system" do
      # Remote calls a module makes are listed in its BEAM's import table. A
      # call to any of these from the language core would be an escape hatch.
      forbidden_modules =
        [
          File,
          System,
          Port,
          Code,
          Node,
          Module,
          IO,
          :os,
          :file,
          :prim_file,
          :rpc,
          :erpc,
          :gen_tcp,
          :gen_udp,
          :ssl,
          :httpc,
          :inet,
          :net_kernel,
          :code,
          :ets,
          :dets,
          :mnesia,
          :application,
          Task,
          GenServer,
          Agent,
          Process,
          Registry,
          Game,
          Instance.Manager,
          RC.Repo,
          Ecto.Repo
        ]

      forbidden_functions = [
        {:erlang, :apply},
        {:erlang, :spawn},
        {:erlang, :spawn_link},
        {:erlang, :send},
        {:erlang, :binary_to_term},
        {:erlang, :binary_to_atom},
        {:erlang, :list_to_atom},
        {:erlang, :list_to_existing_atom},
        {:erlang, :binary_to_existing_atom},
        {:erlang, :open_port},
        {:erlang, :halt},
        {:erlang, :exit},
        {:erlang, :put},
        {String, :to_atom},
        {String, :to_existing_atom},
        {Kernel, :apply}
      ]

      for module <- [
            Edict.Lexer,
            Edict.Parser,
            Edict.AST,
            Edict.Printer,
            Edict.Checker,
            Edict.Interpreter,
            Edict.Runtime,
            Edict.Scenario,
            Edict.World,
            Edict.Effects
          ] do
        {:ok, {_, [imports: imports]}} = :beam_lib.chunks(:code.which(module), [:imports])

        for {m, f, _a} <- imports do
          refute m in forbidden_modules, "#{inspect(module)} calls #{inspect(m)}.#{f}"
          refute {m, f} in forbidden_functions, "#{inspect(module)} calls #{inspect(m)}.#{f}"
        end
      end
    end

    test "the world can't be written to" do
      for body <- [~s|player.credit = 1_000_000|, ~s|time.left = 99999|, ~s|player = {credit: 1}|] do
        assert_refused(attack(body))
      end
    end

    test "an effect can only come from an action call, never be forged as data" do
      result =
        attack("""
        let fake = {action: "give", args: {resource: "credit", amount: 1_000_000_000}}
        log(fake)
        """)

      assert result.effects == []
    end
  end

  # --- 2. Denial of service --------------------------------------------------------

  describe "resource exhaustion (fuel, caps, process limits)" do
    defp timed(fun) do
      {micros, value} = :timer.tc(fun)
      {micros / 1000, value}
    end

    test "infinite loops run out of fuel, fast" do
      {ms, result} = timed(fn -> attack("while true {\n}") end)
      assert [%{message: m}] = result.errors
      assert m =~ "ran out of steps"
      assert ms < 3_000
    end

    test "many looping handlers can't multiply the step budget" do
      loops = Enum.map_join(1..60, "
", fn _ -> "every 1s {
  while true {
  }
}" end)
      {:ok, program} = Parser.parse(loops)
      {:ok, rt} = Runtime.new(program)

      {ms, {rt, result}} = timed(fn -> Runtime.pulse(rt, @world, 1.0) end)
      assert ms < 2_000, "one pulse took #{ms} ms"
      assert rt.fuel_used <= Limits.fuel_per_pulse()
      messages = Enum.map(result.errors, & &1.message)
      assert Enum.any?(messages, &(&1 =~ "ran out of steps"))
      assert Enum.any?(messages, &(&1 =~ "59 handler(s) didn't run"))

      # only the culprit is blamed: the others still have their three lives
      assert Enum.count(rt.handlers, &(&1.failures > 0)) == 1
    end

    test "unbounded and mutual recursion stop at the call depth" do
      assert_refused(attack("f(1)", "fn f(n) {\n  return f(n + 1)\n}"))
      assert_refused(attack("ping(1)", "fn ping(n) {\n  return pong(n)\n}\nfn pong(n) {\n  return ping(n)\n}"))
    end

    test "exponential work is cut off by fuel" do
      {ms, result} =
        timed(fn ->
          attack("let x = fib(40)", "fn fib(n) {\n  if n < 2 {\n    return n\n  }\n  return fib(n - 1) + fib(n - 2)\n}")
        end)

      assert_contained(result)
      assert ms < 3_000
    end

    test "lists, text and records can't grow without bound" do
      for body <- [
            "let xs = [1]\nwhile true {\n  xs = xs + xs\n}",
            "let s = \"ab\"\nwhile true {\n  s = s + s\n}",
            "let r = range(1, 1_000_000_000)",
            "let r = {}\nfor i in range(1, 5000) {\n  r = put(r, str(i), i)\n}",
            "let s = join(range(1, 10000), \"xxxxxxxxxx\")"
          ] do
        assert_contained(attack(body))
      end
    end

    test "state kept between pulses has a size cap" do
      # ~35 KB more state every second, cheap in steps: only the size cap stops it
      {:ok, program} =
        Parser.parse("""
        var hoard = []
        every 1s {
          let big = join(range(1, 300), "xxxxxxxxx")
          for i in range(1, 10) {
            hoard = push(hoard, big + str(i))
          }
        }
        """)

      {:ok, rt} = Runtime.new(program)

      {rt, errors} =
        Enum.reduce(1..20, {rt, []}, fn t, {rt, errs} ->
          {rt, result} = Runtime.pulse(rt, @world, t / 1)
          {rt, errs ++ result.errors}
        end)

      assert :erlang.external_size(rt.globals) <= Limits.max_state_bytes()
      assert Enum.any?(errors, &(&1.message =~ "vars grew too large"))
    end

    test "numbers can't explode into bignums or infinities" do
      for body <- [
            "let x = pow(10, 400)",
            "let x = 1\nwhile true {\n  x = x * 1000\n}",
            "let x = sqrt(-1)",
            "let x = 1 / 0"
          ] do
        assert_contained(attack(body))
      end

      assert {:error, _} = Parser.parse("score 1" <> String.duplicate("0", 40))
      assert {:error, _} = Parser.parse("score 1e400")
    end

    test "a flood of actions is capped per pulse" do
      result = attack("for i in range(1, 1000) {\n  notify(\"spam\")\n}")
      assert result.effects == []
      assert [%{message: m}] = result.errors
      assert m =~ "too many actions"
    end

    test "parser bombs are rejected quickly and without crashing" do
      bombs = [
        "score " <> String.duplicate("(", 5_000) <> "1" <> String.duplicate(")", 5_000),
        "score " <> String.duplicate("[", 5_000),
        "score " <> Enum.join(List.duplicate("1", 9_000), " + "),
        "score " <> String.duplicate("-", 10_000) <> "1",
        "score " <> String.duplicate("not ", 10_000) <> "true",
        String.duplicate("on start {\n", 3_000),
        String.duplicate("x", Limits.max_source_bytes() + 1),
        "score \"" <> String.duplicate("a", 10_000) <> "\""
      ]

      for bomb <- bombs do
        {ms, result} = timed(fn -> Parser.parse(bomb) end)
        assert {:error, %{message: _}} = result
        assert ms < 2_000, "parsing took #{ms} ms"
      end
    end

    test "the process backstop kills runaway memory and time without touching the caller" do
      Process.flag(:trap_exit, true)

      assert {:error, :memory} =
               Sandbox.run(fn -> Enum.reduce(1..100_000_000, [], &[{&1, &1, &1} | &2]) end, heap_words: 200_000)

      assert {:error, :timeout} = Sandbox.run(fn -> Process.sleep(:infinity) end, timeout: 100)
      assert {:error, {:crash, _}} = Sandbox.run(fn -> raise "interpreter bug" end)
      assert {:error, {:crash, _}} = Sandbox.run(fn -> exit(:boom) end)

      refute_receive {:EXIT, _, _}, 50
      assert Process.alive?(self())
    end

    test "a whole simulation is bounded too" do
      {:ok, program} = Parser.parse("every 1s {\n  let x = 0\n  while x < 1_000_000 {\n    x = x + 1\n  }\n}\nscore 1")
      {ms, result} = timed(fn -> Simulator.run(program) end)
      assert {:ok, report} = result
      assert report.errors != []
      assert ms < 20_000
    end
  end

  # --- 3. The atom table ------------------------------------------------------------

  describe "nothing a script contains becomes an atom" do
    test "parsing, checking, running and decoding never grow the atom table" do
      # warm up: load every module the pipeline touches
      warm = "var a1 = 1\nfn b1(c1) {\n  return c1.d1\n}\non start {\n  notify(\"x\")\n}\nscore len(\"y\")"
      %{program: program} = Edict.analyze(warm)
      Edict.AST.from_json(program |> Jason.encode!() |> Jason.decode!())
      {:ok, rt} = Runtime.new(program)
      Runtime.pulse(rt, @world, 1.0)

      before = :erlang.system_info(:atom_count)

      for i <- 1..300 do
        name = "zz_never_an_atom_#{i}_#{System.unique_integer([:positive])}"

        source = """
        var #{name} = {#{name}_key: "#{name}_text"}
        fn #{name}_fn(#{name}_p) {
          return #{name}_p.#{name}_field
        }
        on start {
          let #{name}_l = #{name}.#{name}_key
          #{name}_unknown(#{name}_l, #{name}_named: 1)
        }
        score #{name}_fn(player)
        """

        %{program: program} = Edict.analyze(source)
        json = program |> Jason.encode!() |> Jason.decode!()
        {:ok, _} = AST.from_json(json)
        {:ok, rt} = Runtime.new(program)
        Runtime.pulse(rt, @world, 1.0)

        # hostile JSON: unknown kinds, fields and enum values
        AST.from_json(%{"decls" => [%{"k" => name, "id" => "x"}]})

        AST.from_json(%{"decls" => [%{"k" => "score", "expr" => %{"k" => "bin", "op" => name, "l" => %{}, "r" => %{}}}]})

        AST.from_json(%{"decls" => [%{"k" => "on", "event" => name, "body" => []}]})
      end

      assert :erlang.system_info(:atom_count) - before < 5
    end
  end

  # --- 4. The JSON trust boundary ---------------------------------------------------

  describe "trees from the editor are rebuilt, not trusted" do
    defp decl(expr), do: %{"decls" => [%{"k" => "score", "expr" => expr}]}

    test "unknown kinds and kinds out of place are rejected" do
      assert {:error, _} = AST.from_json(%{"decls" => [%{"k" => "Elixir.File"}]})
      assert {:error, _} = AST.from_json(decl(%{"k" => "score", "expr" => %{"k" => "num", "v" => 1}}))
      assert {:error, _} = AST.from_json(%{"decls" => [%{"k" => "num", "v" => 1}]})
      assert {:error, _} = AST.from_json(%{"decls" => "not a list"})
      assert {:error, _} = AST.from_json(%{"nope" => []})
    end

    test "names must be identifiers, not keywords or paths" do
      for bad <- ["__proto__x.y", "File.write", "a b", "", "if", "1abc", String.duplicate("a", 65), "a\u202Eb"] do
        assert {:error, _} = AST.from_json(decl(%{"k" => "ident", "name" => bad})), "accepted #{inspect(bad)}"
      end
    end

    test "numbers, text and enums are checked" do
      assert {:error, _} = AST.from_json(decl(%{"k" => "num", "v" => 1.0e300}))
      assert {:error, _} = AST.from_json(decl(%{"k" => "num", "v" => "12"}))
      assert {:error, _} = AST.from_json(decl(%{"k" => "str", "v" => "bad \u0000 byte"}))
      assert {:error, _} = AST.from_json(decl(%{"k" => "str", "v" => "evil \u202E txt"}))
      assert {:error, _} = AST.from_json(decl(%{"k" => "str", "v" => String.duplicate("x", Limits.max_string() + 1)}))

      assert {:error, _} =
               AST.from_json(
                 decl(%{"k" => "bin", "op" => "<>", "l" => %{"k" => "nil_lit"}, "r" => %{"k" => "nil_lit"}})
               )
    end

    test "deep or huge trees are refused" do
      deep = Enum.reduce(1..500, %{"k" => "num", "v" => 1}, fn _, e -> %{"k" => "un", "op" => "-", "e" => e} end)
      assert {:error, _} = AST.from_json(decl(deep))

      wide = %{"k" => "list", "items" => List.duplicate(%{"k" => "num", "v" => 1}, Limits.max_nodes() + 1)}
      assert {:error, _} = AST.from_json(decl(wide))
    end

    test "ids are sanitized, never trusted" do
      {:ok, program} =
        AST.from_json(%{
          "decls" => [
            %{"k" => "score", "id" => "<script>", "expr" => %{"k" => "num", "id" => "dup", "v" => 1}},
            %{"k" => "tiebreak", "id" => "dup", "expr" => %{"k" => "num", "v" => 2}}
          ]
        })

      ids = Enum.map(AST.nodes(program), & &1.id)
      assert Enum.all?(ids, &Regex.match?(~r/^[A-Za-z0-9_-]+$/, &1))
      assert length(Enum.uniq(ids)) == length(ids)
    end
  end

  # --- 5. Effects reaching the game ---------------------------------------------------

  describe "the effect gate" do
    defp gate(effects, config \\ %{"rival" => true}) do
      {ok, refused, _} = Effects.prepare(effects, @world, config, Effects.new(), 1.0)
      {ok, refused}
    end

    test "a target must be one of the player's own systems" do
      {ok, refused} =
        gate([
          %{"action" => "destabilize", "args" => %{"amount" => 5.0, "system" => 12.0}},
          %{"action" => "destabilize", "args" => %{"amount" => 5.0, "system" => 999.0}},
          %{"action" => "send_agent", "args" => %{"type" => "erased", "level" => 3.0, "system" => 4242.0}},
          %{"action" => "destabilize", "args" => %{"amount" => 5.0}}
        ])

      assert [%{"args" => %{"system" => 12.0}}, %{"args" => %{"system" => 11.0}}] = ok
      assert length(refused) == 2
    end

    test "end_match can only name a faction in play, and its message is cleaned" do
      factions = [%{"name" => "cardan"}, %{"name" => "myrmezir"}]
      world = Map.put(@world, "factions", factions)
      rlo = <<0x202E::utf8>>

      {ok, refused, _} =
        Effects.prepare(
          [
            %{"action" => "end_match", "args" => %{"message" => "Over" <> rlo <> ".", "winner" => "cardan"}},
            %{"action" => "end_match", "args" => %{"winner" => "<b>elves</b>"}},
            %{"action" => "end_match", "args" => %{"winner" => 3}},
            %{"action" => "end_match", "args" => %{}}
          ],
          world,
          %{},
          Effects.new(),
          1.0
        )

      assert [%{"args" => %{"message" => "Over.", "winner" => "cardan"}}, %{"args" => %{"winner" => nil}}] = ok
      assert [%{reason: not_in_play}, %{reason: not_a_name}] = refused
      assert not_in_play == "this text isn't a faction in this match"
      assert not_a_name =~ "faction's name"
    end

    test "unknown or malformed effects never pass" do
      {ok, refused} =
        gate([
          %{"action" => "delete_account", "args" => %{}},
          %{"action" => "give", "args" => %{"resource" => "credit", "amount" => 1.0e12}},
          %{"action" => "give", "args" => %{"resource" => "gold", "amount" => 1.0}},
          %{"action" => "give"},
          "give"
        ])

      assert ok == []
      assert length(refused) == 5
    end

    test "send_agent needs a rival court" do
      {ok, _} = gate([%{"action" => "send_agent", "args" => %{"type" => "erased", "level" => 3.0}}], %{})
      assert ok == []
    end

    test "message text is cleaned and capped; markup is left inert for plain-text rendering" do
      {[%{"args" => %{"message" => m}}], []} =
        gate([
          %{
            "action" => "notify",
            "args" => %{"message" => "hi\u202E\u0007 <b>x</b> [a](javascript:alert(1))" <> String.duplicate("!", 500)}
          }
        ])

      refute m =~ "\u202E"
      refute m =~ "\u0007"
      assert String.length(m) <= 280
    end

    test "messages are rate-limited across pulses" do
      notes = for _ <- 1..30, do: %{"action" => "notify", "args" => %{"message" => "spam"}}
      {ok, refused, _} = Effects.prepare(notes, @world, %{}, Effects.new(), 1.0)
      assert length(ok) == 20
      assert length(refused) == 10
    end

    test "scenario messages render as plain text in the game client" do
      # $tmd() and v-html run text through markdown, which turns
      # [x](javascript:...) into a live link. Script text must never go there.
      source = File.read!(Path.join(File.cwd!(), "front/src/game/components/ScenarioFeed.vue"))
      refute source =~ "v-html"
      refute source =~ "$tmd"
    end
  end

  # --- 6. Information and isolation -------------------------------------------------------

  describe "what a script can see" do
    test "the world holds exactly the catalog's fields: nothing private leaks" do
      player = %{
        id: 7,
        account_id: 99,
        registration_id: 5,
        instance_id: 123,
        name: "P",
        faction: :ark,
        credit: %{value: 10, change: 2},
        technology: %{value: 1, change: 1},
        ideology: %{value: 1, change: 1},
        stellar_systems: [
          %{
            id: 1,
            name: "S",
            workforce: 3,
            habitation: 4,
            happiness: 5,
            production: 6,
            defense: 0,
            credit: 1,
            technology: 1,
            ideology: 1,
            queue: 3,
            governor: 9
          }
        ],
        dominions: [],
        characters: [
          %{id: 3, name: "C", type: :spy, status: :on_board, level: 2, system: 1, owner: %{id: 7}, actions: [:secret]}
        ],
        patents: [:citadel],
        wonders_built: [],
        agents_assassinated: 0,
        pending_notifications: [:private]
      }

      world = World.build(player, clock: %{elapsed: 1, left: 2, limit: 3}, config: %{})
      assert_shape(world, {:record, Edict.Catalog.world()})
    end

    defp assert_shape(value, {:record, fields}) do
      assert is_map(value)
      assert Enum.sort(Map.keys(value)) == Enum.sort(Map.keys(fields))
      Enum.each(fields, fn {k, t} -> assert_shape(Map.fetch!(value, k), t) end)
    end

    defp assert_shape(value, {:list, t}) do
      assert is_list(value)
      Enum.each(value, &assert_shape(&1, t))
    end

    defp assert_shape(value, _scalar), do: refute(is_map(value) or is_tuple(value))

    test "the same script against the same world does the same thing" do
      %{program: program} =
        Edict.analyze(File.read!(Path.join(:code.priv_dir(:rc), "edict/examples/headhunter_lite.edict")))

      assert Simulator.run(program) == Simulator.run(program)
    end

    test "an interpreter error never carries a host stack trace or term" do
      assert {:error, error, _} =
               Interpreter.eval_expr(
                 %{k: :call, id: "x", fn: %{k: :ident, id: "y", name: "nope"}, args: [], named: []},
                 Interpreter.new_ctx()
               )

      assert error.message == "unknown function nope"
    end
  end

  describe "the sandbox's own cap doesn't switch off honest scripts" do
    # The runners copy the runtime into the sandbox every pulse (a playtest's
    # one run, a match's run per player), and the heap cap counts the copy.
    # A runtime that carried its whole tree twice made a 200-handler script
    # need a 32 MB heap; it must fit the default cap.
    test "a big script's runtime fits when copied in, as the runners pass it" do
      handler = """
      every 1s {
        let s = 0
        for i in range(1, 25) {
          s = s + i
        }
      }
      """

      source = Enum.map_join(1..200, "\n", fn _ -> handler end)

      {:ok, program} = Parser.parse(source)
      {:ok, rt} = Runtime.new(program)
      world = %{"time" => %{"elapsed" => 1.0, "left" => 100.0, "limit" => 101.0}, "player" => %{}}

      for _ <- 1..3 do
        assert {:ok, {_rt, %{errors: errors}}} = Sandbox.run(fn -> Runtime.pulse(rt, world, 1.0) end)
        assert Enum.all?(errors, &(&1.message =~ "steps")), inspect(errors)
      end
    end
  end
end
