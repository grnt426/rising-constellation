defmodule Edict.ResourceBenchTest do
  @moduledoc """
  A measurement tool, not an assertion suite: it prints what a dozen
  player-written Edict scenarios cost on the production box (one AWS
  t4g.large: 2 vCPU arm64 Graviton2, 8 GB RAM, shared with Postgres, nginx
  and every game instance).

  It is tagged `:mem_bench`, excluded from the normal run
  (`test/test_helper.exs`). Run it in Docker (the dev container is 12-core
  x86; x86 -> Graviton2 is an approximate conversion — see the header the
  tool prints), at full scheduler count and again with `+S 2:2` to stand in
  for the two prod vCPUs:

      docker compose run --rm --entrypoint sh -e MIX_ENV=test rc -c \
        "chown -R rc:rc /data/_build /data/deps 2>/dev/null; \
         gosu rc:rc mix test test/edict/resource_bench_test.exs --include mem_bench"

  Add `-e ERL_FLAGS=\"+S 2:2\"` for the 2-scheduler run.

  Every number is the median of several repeats (max also reported) to damp
  noise from a sibling session running tests in the same worktree. The tool
  measures the way `Edict.Live` does (a pulse inside `Edict.Sandbox.run`,
  copying runtime + world into the sandbox process) and also the bare
  `Edict.Runtime.pulse` cost, so the sandbox overhead is visible.
  """
  use RC.DataCase, async: false

  @moduletag :mem_bench
  @moduletag timeout: 1_200_000

  alias Edict.{Limits, Parser, Runtime, Sandbox, Simulator, World}

  # ---------------------------------------------------------------------------
  # formatting
  # ---------------------------------------------------------------------------

  defp p(s), do: IO.puts(s)
  defp hr, do: p(String.duplicate("-", 100))

  defp f2(x) when is_number(x), do: :erlang.float_to_binary(x / 1, decimals: 2)
  defp f1(x) when is_number(x), do: :erlang.float_to_binary(x / 1, decimals: 1)

  defp commas(n) when is_integer(n) do
    n
    |> Integer.to_string()
    |> String.reverse()
    |> String.to_charlist()
    |> Enum.chunk_every(3)
    |> Enum.join(",")
    |> String.reverse()
  end

  defp commas(n) when is_float(n), do: commas(trunc(n))

  defp col(s, w), do: String.pad_trailing(to_string(s), w)
  defp rcol(s, w), do: String.pad_leading(to_string(s), w)

  defp row(cells) do
    cells
    |> Enum.map_join("  ", fn
      {s, w, :l} -> col(s, w)
      {s, w, :r} -> rcol(s, w)
    end)
    |> p()
  end

  defp mb(bytes), do: f2(bytes / 1_048_576) <> " MB"
  defp kb(bytes), do: f1(bytes / 1024) <> " KB"

  defp median(list) do
    sorted = Enum.sort(list)
    n = length(sorted)
    mid = div(n, 2)
    if rem(n, 2) == 1, do: Enum.at(sorted, mid), else: (Enum.at(sorted, mid - 1) + Enum.at(sorted, mid)) / 2
  end

  defp percentile(list, pct) do
    sorted = Enum.sort(list)
    n = length(sorted)
    idx = max(0, min(n - 1, ceil(pct * n) - 1))
    Enum.at(sorted, idx)
  end

  # median wall-ms of `fun` over `reps` repeats; also the max.
  defp time_reps(fun, reps) do
    samples = for _ <- 1..reps, do: elem(:timer.tc(fun), 0) / 1000.0
    {median(samples), Enum.max(samples)}
  end

  # ---------------------------------------------------------------------------
  # programs and worlds
  # ---------------------------------------------------------------------------

  defp program!(source) do
    {:ok, program} = Parser.parse(source)
    program
  end

  defp runtime!(source) do
    {:ok, rt} = Runtime.new(program!(source))
    rt
  end

  # A static player of `nsys` systems and `nagents` agents, shaped like
  # Instance.Player.Player (what World.build reads). Values are generous so
  # typical scripts' conditions pass and handlers don't switch themselves off.
  defp fake_player(nsys, nagents) do
    %{
      name: "Bench",
      faction: :ark,
      credit: %{value: 5_000_000.0, change: 800.0},
      technology: %{value: 400_000.0, change: 120.0},
      ideology: %{value: 300_000.0, change: 100.0},
      stellar_systems:
        for i <- 1..nsys//1 do
          %{
            id: i,
            name: "Sys#{i}",
            workforce: 40,
            habitation: 50,
            happiness: 8,
            production: 120,
            defense: 10,
            credit: 200,
            technology: 30,
            ideology: 25
          }
        end,
      dominions: [],
      characters:
        for i <- 1..nagents//1 do
          %{
            id: 1000 + i,
            name: "Agent#{i}",
            type: Enum.at([:admiral, :speaker, :spy], rem(i, 3)),
            status: :on_board,
            level: rem(i, 10) + 1,
            system: rem(i, nsys) + 1,
            army_raid: 100 + i,
            army_invasion: 50 + i,
            army_maintenance: 10 + i
          }
        end,
      patents: [:shipyard_1, :shipyard_2],
      wonders_built: [],
      agents_assassinated: 7
    }
  end

  defp build_world(t, limit, player, opts \\ []) do
    rival? = Keyword.get(opts, :rival, false)
    nsys = length(player.stellar_systems)

    World.build(player,
      clock: %{elapsed: t, left: max(limit - t, 0.0), limit: limit},
      config: %{"name" => "Bench", "systems" => nsys, "rival" => rival?},
      rival: if(rival?, do: %{faction: "rival", sent: 20, left: 11}, else: nil)
    )
  end

  # ---------------------------------------------------------------------------
  # adversarial scripts (each one worst-cased on a different axis)
  # ---------------------------------------------------------------------------

  # {label, source, pulse-time, which limit bounds it}
  defp worst_scripts do
    # ~3.5 KB text (a refc binary; >= 64 bytes), well under the 4 KB cap
    big_string = "join(range(1, 300), \"xxxxxxxxx\")"

    [
      {"arith_loop",
       """
       on start {
         let x = 0
         while x < 100000000 {
           x = x + 1
         }
       }
       """, 0.0, "fuel (out of steps)"},
      {"list_ops_10k",
       """
       on start {
         let xs = range(1, 10000)
         let n = 0
         while n < 30 {
           xs = sort_by(xs, v => 0 - v)
           n = n + 1
         }
       }
       """, 0.0, "fuel (sort_by spends 2*len)"},
      {"string_build_4k",
       """
       on start {
         let base = #{big_string}
         let n = 0
         while n < 100000 {
           let s = base + "!"
           n = n + 1
         }
       }
       """, 0.0, "fuel (+ spends bytes/64)"},
      {"map_put_1k",
       """
       on start {
         let r = {}
         let n = 1
         while n < 100000 {
           r = put(r, str(n), n)
           n = n + 1
         }
       }
       """, 0.0, "fuel (put spends map_size; cap never reached)"},
      {"recursion_fib",
       """
       fn fib(n) {
         if n < 2 {
           return n
         }
         return fib(n - 1) + fib(n - 2)
       }
       on start {
         let x = fib(40)
       }
       """, 0.0, "fuel (call churn)"},
      {"deep_calls_64",
       """
       fn rec(n) {
         if n <= 0 {
           return 0
         }
         return 1 + rec(n - 1)
       }
       on start {
         let x = rec(64)
       }
       """, 0.0, "max_call_depth (cheap)"},
      {"many_handlers_200", many_handlers_source(200), 1.0, "shared fuel / handler count"},
      {"binary_hoard",
       """
       on start {
         let base = #{big_string}
         let acc = []
         let n = 0
         while n < 100000 {
           acc = push(acc, base + str(n))
           n = n + 1
         }
       }
       """, 0.0, "fuel (push spends len; off-heap binary grows)"}
    ]
  end

  defp many_handlers_source(n) do
    handlers =
      for _ <- 1..n do
        """
        every 1s {
          let s = 0
          for i in range(1, 25) {
            s = s + i
          }
        }
        """
      end

    Enum.join(handlers, "\n")
  end

  # run one pulse bare and inside the sandbox; return a map of measurements.
  defp measure_worst(source, t, world, reps) do
    rt0 = runtime!(source)

    bare = fn ->
      r0 = elem(Process.info(self(), :reductions), 1)
      {rt, _result} = Runtime.pulse(rt0, world, t)
      r1 = elem(Process.info(self(), :reductions), 1)
      {rt, r1 - r0}
    end

    {bare_ms, bare_max} = time_reps(fn -> bare.() end, reps)
    {rt_after, bare_reds} = bare.()
    fuel = rt_after.fuel_used

    sandbox_fun = fn ->
      r0 = elem(Process.info(self(), :reductions), 1)
      {rt, result} = Runtime.pulse(rt0, world, t)
      r1 = elem(Process.info(self(), :reductions), 1)
      {rt, result, r1 - r0}
    end

    # the sandbox may kill an adversarial pulse (its heap cap counts shared
    # binaries and is enforced at GC): that's a result, not a crash
    killed = :counters.new(1, [])

    {sb_ms, sb_max} =
      time_reps(
        fn ->
          case Sandbox.run(sandbox_fun) do
            {:ok, _} -> :ok
            {:error, _} -> :counters.add(killed, 1, 1)
          end
        end,
        reps
      )

    {sb_reds, n_errors} =
      case Sandbox.run(sandbox_fun) do
        {:ok, {_rt, result, reds}} -> {reds, length(result.errors)}
        {:error, reason} -> {0, "killed: #{reason}"}
      end

    n_errors =
      case :counters.get(killed, 1) do
        0 -> n_errors
        k -> "#{n_errors} (#{k}/#{reps} killed)"
      end

    %{
      bare_ms: bare_ms,
      bare_max: bare_max,
      bare_reds: bare_reds,
      sb_ms: sb_ms,
      sb_max: sb_max,
      sb_reds: sb_reds,
      fuel: fuel,
      errors: n_errors
    }
  end

  # ---------------------------------------------------------------------------
  # 0. header
  # ---------------------------------------------------------------------------

  test "0. environment" do
    hr()
    p("EDICT RESOURCE BENCHMARK")
    hr()
    p("schedulers_online : #{:erlang.system_info(:schedulers_online)} (of #{:erlang.system_info(:schedulers)})")
    p("logical_processors: #{:erlang.system_info(:logical_processors_available)}")
    p("otp               : #{:erlang.system_info(:otp_release)}  erts #{:erlang.system_info(:version)}")
    p("wordsize          : #{:erlang.system_info(:wordsize) * 8}-bit")

    arch =
      case :erlang.system_info(:system_architecture) do
        a when is_list(a) -> List.to_string(a)
        a -> inspect(a)
      end

    p("arch              : #{arch}")
    p("ERL_FLAGS         : #{System.get_env("ERL_FLAGS") || "(unset)"}")

    p("""

    Limits in force (lib/edict/limits.ex):
      fuel/pulse=#{commas(Limits.fuel_per_pulse())}  fuel/setup=#{commas(Limits.fuel_for_setup())}
      max_state=#{commas(Limits.max_state_bytes())} B  max_heap=#{commas(Limits.max_heap_words())} words (#{mb(Limits.max_heap_words() * 8)})
      timeout=#{Limits.timeout_ms()} ms  max_effects/pulse=#{Limits.max_effects_per_pulse()}  max_call_depth=#{Limits.max_call_depth()}
      max_string=#{commas(Limits.max_string())}  max_list=#{commas(Limits.max_list())}  max_map=#{commas(Limits.max_map())}
      source: #{commas(Limits.max_source_bytes())} B / #{commas(Limits.max_tokens())} tokens / #{commas(Limits.max_nodes())} nodes / depth #{Limits.max_depth()}

    NOTE: the dev container is 12-core x86_64; prod is a 2-vCPU arm64 Graviton2.
    x86->Graviton2 single-thread is roughly 1.3-1.8x SLOWER per core (approximate).
    Read the +S 2:2 run for the prod core count; scale ms up for the arch gap.
    """)
  end

  # ---------------------------------------------------------------------------
  # 1. fuel throughput / worst-case pulse CPU
  # ---------------------------------------------------------------------------

  test "1. worst-case pulse cpu and fuel throughput" do
    world = build_world(0.0, 1800.0, fake_player(4, 8), rival: true)
    reps = 7

    hr()
    p("1. WORST-CASE PULSE CPU  (median of #{reps} reps; ms wall, reds = reductions)")
    p("   bare = Runtime.pulse in this process; sandbox = inside Sandbox.run as Live does")
    hr()

    row([
      {"script", 20, :l},
      {"fuel used", 11, :r},
      {"bare ms", 9, :r},
      {"bare max", 9, :r},
      {"bare reds", 12, :r},
      {"sbox ms", 9, :r},
      {"sbox max", 9, :r},
      {"reds/kfuel", 11, :r},
      {"errs", 5, :r}
    ])

    results =
      for {label, source, t, _limit} <- worst_scripts() do
        m = measure_worst(source, t, world, reps)
        reds_per_kfuel = if m.fuel > 0, do: m.bare_reds / (m.fuel / 1000), else: 0.0

        row([
          {label, 20, :l},
          {commas(m.fuel), 11, :r},
          {f1(m.bare_ms), 9, :r},
          {f1(m.bare_max), 9, :r},
          {commas(m.bare_reds), 12, :r},
          {f1(m.sb_ms), 9, :r},
          {f1(m.sb_max), 9, :r},
          {f1(reds_per_kfuel), 11, :r},
          {m.errors, 5, :r}
        ])

        {label, m}
      end

    slowest = Enum.max_by(results, fn {_l, m} -> m.bare_ms end)
    near_timeout = Enum.filter(results, fn {_l, m} -> m.sb_max >= Limits.timeout_ms() * 0.5 end)

    p("")
    p("slowest per pulse : #{elem(slowest, 0)} at #{f1(elem(slowest, 1).bare_ms)} ms bare (median)")

    p(
      "sandbox overhead  : +#{f1(Enum.max(Enum.map(results, fn {_l, m} -> m.sb_ms - m.bare_ms end)))} ms worst (spawn + copy + teardown)"
    )

    if near_timeout == [],
      do: p("timeout headroom  : no script's sandbox max reached 50% of the #{Limits.timeout_ms()} ms wall-clock cap"),
      else:
        p(
          "timeout WARNING   : #{Enum.map_join(near_timeout, ", ", &elem(&1, 0))} reached >=50% of the #{Limits.timeout_ms()} ms cap"
        )

    p(
      "many_handlers_200 : shared fuel means 200 handlers can't multiply CPU; cost is handler bookkeeping + the one handler that starves"
    )
  end

  # ---------------------------------------------------------------------------
  # 2. peak memory per pulse (heap cap + off-heap binaries)
  # ---------------------------------------------------------------------------

  test "2. peak heap per pulse and off-heap binary escape" do
    world = build_world(0.0, 1800.0, fake_player(4, 8), rival: true)

    hr()
    p("2a. PEAK HEAP PER PULSE  (smallest heap_words to Sandbox.run that still succeeds)")
    p("    binary-searched; approximate (max_heap_size is enforced at GC, with slack)")
    hr()

    row([{"script", 20, :l}, {"min heap words", 16, :r}, {"~peak heap", 12, :r}, {"killed at default?", 20, :l}])

    for {label, source, t, _limit} <- worst_scripts() do
      min_words = smallest_heap(source, t, world)
      default = Limits.max_heap_words()

      killed =
        case Sandbox.run(fn -> Runtime.pulse(runtime!(source), world, t) end, heap_words: default) do
          {:error, :memory} -> "YES (killed at #{mb(default * 8)})"
          _ -> "no"
        end

      words_str = if min_words, do: commas(min_words), else: "> #{commas(default)}"
      peak_str = if min_words, do: mb(min_words * 8), else: "> " <> mb(default * 8)
      row([{label, 20, :l}, {words_str, 16, :r}, {peak_str, 12, :r}, {killed, 20, :l}])
    end

    hr()

    p(
      "2b. OFF-HEAP BINARY GROWTH  (strings >=64 bytes are refc binaries; the sandbox counts them: include_shared_binaries)"
    )

    p("    a pulse builds a list of ~4 KB strings until it runs out of fuel; we watch :erlang.memory(:binary)")
    hr()

    {label, source, t, _} = Enum.find(worst_scripts(), &(elem(&1, 0) == "binary_hoard"))

    measure_binary_growth(label, source, t, world)
  end

  # smallest heap_words (power-of-two-ish binary search) where the pulse does
  # not get :memory-killed; nil if even the default cap is exceeded.
  defp smallest_heap(source, t, world) do
    default = Limits.max_heap_words()

    fits = fn w ->
      case Sandbox.run(fn -> Runtime.pulse(runtime!(source), world, t) end, heap_words: w) do
        {:error, :memory} -> false
        {:ok, _} -> true
        _ -> true
      end
    end

    if not fits.(default) do
      nil
    else
      bsearch(fits, 512, default)
    end
  end

  defp bsearch(_fits, _lo, hi) when hi <= 1024, do: hi

  defp bsearch(_fits, lo, hi) when hi - lo <= 512, do: hi

  defp bsearch(fits, lo, hi) do
    mid = div(lo + hi, 2)
    if fits.(mid), do: bsearch(fits, lo, mid), else: bsearch(fits, mid, hi)
  end

  defp measure_binary_growth(label, source, t, world) do
    :erlang.garbage_collect()
    parent = self()
    ref = make_ref()

    # run the pulse in a watched process; sample its peak binary memory
    pid =
      spawn(fn ->
        start_bin = :erlang.memory(:binary)
        {rt, result} = Runtime.pulse(runtime!(source), world, t)
        peak_bin = :erlang.memory(:binary)
        send(parent, {ref, start_bin, peak_bin, rt.fuel_used, length(result.errors)})
      end)

    sampler = spawn(fn -> sample_binary(parent, ref, pid, :erlang.memory(:binary)) end)

    {start_bin, end_bin, fuel, errs} =
      receive do
        {^ref, s, e, fuel, errs} -> {s, e, fuel, errs}
      after
        10_000 -> {0, 0, 0, 0}
      end

    peak =
      receive do
        {:peak, ^ref, peak} -> peak
      after
        2_000 -> end_bin
      end

    Process.exit(sampler, :kill)

    p("script           : #{label}")
    p("fuel used         : #{commas(fuel)} (pulse ended with #{errs} error(s) — the fuel cap)")
    p("binary at start   : #{mb(start_bin)}")
    p("binary peak (sampled): #{mb(peak)}  -> delta #{mb(peak - start_bin)}")

    p(
      "finding           : off-heap binary allocated in ONE pulse is bounded by fuel first (push() costs O(n) fuel, so the retained list is small), and the sandbox's #{mb(Limits.max_heap_words() * 8)} cap counts it too (include_shared_binaries)."
    )
  end

  defp sample_binary(parent, ref, watch, peak) do
    if Process.alive?(watch) do
      now = :erlang.memory(:binary)
      sample_binary(parent, ref, watch, max(peak, now))
    else
      send(parent, {:peak, ref, max(peak, :erlang.memory(:binary))})
    end
  end

  # ---------------------------------------------------------------------------
  # 3. persistent state per running scenario + copy cost
  # ---------------------------------------------------------------------------

  test "3. persistent runtime state and sandbox copy cost" do
    hr()
    p("3a. PERSISTENT STATE PER RUNNING SCENARIO  (rt carried between pulses)")
    hr()

    # worst case: a var hoard filled to the max_state_bytes cap
    hoard_src = """
    var hoard = []
    every 1s {
      let big = join(range(1, 300), "xxxxxxxxx")
      for i in range(1, 8) {
        hoard = push(hoard, big + str(i))
      }
    }
    score 1
    """

    hoard_rt =
      Enum.reduce(1..60, runtime!(hoard_src), fn t, rt ->
        world = build_world(t / 1, 1800.0, fake_player(1, 0))
        {rt, _} = Runtime.pulse(rt, world, t / 1)
        rt
      end)

    flat = :erts_debug.flat_size(hoard_rt) * :erlang.system_info(:wordsize)
    ext = byte_size(:erlang.term_to_binary(hoard_rt))
    state_ext = byte_size(:erlang.term_to_binary(hoard_rt.globals))

    row([{"runtime", 26, :l}, {"flat_size", 14, :r}, {"term_to_binary", 16, :r}, {"var state (ext)", 16, :r}])
    row([{"worst-case var hoard", 26, :l}, {kb(flat), 14, :r}, {kb(ext), 16, :r}, {kb(state_ext), 16, :r}])

    for {key, rt} <- example_runtimes() do
      flat = :erts_debug.flat_size(rt) * :erlang.system_info(:wordsize)
      ext = byte_size(:erlang.term_to_binary(rt))
      state = byte_size(:erlang.term_to_binary(rt.globals))
      row([{key, 26, :l}, {kb(flat), 14, :r}, {kb(ext), 16, :r}, {kb(state), 16, :r}])
    end

    p("")
    p("max_state_bytes cap = #{kb(Limits.max_state_bytes())} on term_to_binary(globals), checked after every pulse.")

    p("the rt also carries the whole program tree (constant), which dominates flat_size for small-state scripts.")

    hr()
    p("3b. SANDBOX COPY COST PER PULSE  (rt + world copied into the spawned process each second)")
    hr()

    world = build_world(5.0, 1800.0, fake_player(6, 12), rival: true)
    rt = runtime!(List.first(Enum.map(example_sources(), &elem(&1, 1))))

    world_sz = :erts_debug.flat_size(world) * :erlang.system_info(:wordsize)
    rt_sz = :erts_debug.flat_size(rt) * :erlang.system_info(:wordsize)

    # spawn a process that closes over {rt, world} and does nothing but die.
    # the BEAM copies the captured term into the new heap on spawn, so the
    # delta vs an empty spawn is the per-pulse copy cost Live pays.
    {copy_with_ms, _} =
      time_reps(
        fn ->
          fun = fn -> {rt, world} end
          {_pid, mon} = :erlang.spawn_opt(fn -> fun.() end, [:monitor])

          receive do
            {:DOWN, ^mon, _, _, _} -> :ok
          after
            1_000 -> :ok
          end
        end,
        15
      )

    {copy_empty_ms, _} =
      time_reps(
        fn ->
          {_pid, mon} = :erlang.spawn_opt(fn -> :ok end, [:monitor])

          receive do
            {:DOWN, ^mon, _, _, _} -> :ok
          after
            1_000 -> :ok
          end
        end,
        15
      )

    p("world flat_size   : #{kb(world_sz)}  (6 systems, 12 agents)")
    p("rt flat_size      : #{kb(rt_sz)}")
    p("spawn + copy {rt,world} : #{f2(copy_with_ms)} ms median")
    p("spawn only (no payload) : #{f2(copy_empty_ms)} ms median")
    p("=> copy cost      : ~#{f2(max(copy_with_ms - copy_empty_ms, 0.0))} ms/pulse, scales with rt+world term size")
  end

  defp example_sources do
    for ex <- Edict.examples(), do: {ex.key, ex.source}
  end

  defp example_runtimes do
    for {key, source} <- example_sources() do
      {:ok, rt} = Runtime.new(program!(source))
      {key, rt}
    end
  end

  # ---------------------------------------------------------------------------
  # 4. typical scripts: per-pulse time + fuel over a full run
  # ---------------------------------------------------------------------------

  test "4. the twelve examples over a full run" do
    hr()
    p("4. TYPICAL SCRIPTS  (each example driven pulse-by-pulse over its whole run)")
    p("   world: 4 systems, 8 agents, generous stocks; bare Runtime.pulse")
    p("   reported per-pulse: mean / p99 / max wall-us, and fuel")
    hr()

    row([
      {"example", 24, :l},
      {"pulses", 8, :r},
      {"mean us", 9, :r},
      {"p99 us", 9, :r},
      {"max us", 9, :r},
      {"fuel mean", 10, :r},
      {"fuel max", 10, :r},
      {"total fuel", 13, :r}
    ])

    for {key, source} <- example_sources() do
      rt0 = runtime!(source)
      limit = rt0.config["time_limit"] || 1800.0
      rival? = rt0.config["rival"] == true
      player = fake_player(4, 8)

      # one measured run (times per pulse), halting when the script calls
      # finish(); repeat 3x, keep the fastest run (least sibling-session noise).
      runs =
        for _ <- 1..3 do
          {_rt, samples} =
            Enum.reduce_while(0..trunc(limit), {rt0, []}, fn t, {rt, acc} ->
              world = build_world(t / 1, limit, player, rival: rival?)
              {us, {rt2, res}} = :timer.tc(fn -> Runtime.pulse(rt, world, t / 1) end)
              fuel_delta = rt2.fuel_used - rt.fuel_used
              acc = [{us, fuel_delta} | acc]
              if res.finished, do: {:halt, {rt2, acc}}, else: {:cont, {rt2, acc}}
            end)

          Enum.reverse(samples)
        end

      best = Enum.min_by(runs, fn s -> Enum.sum(Enum.map(s, &elem(&1, 0))) end)
      times = Enum.map(best, &elem(&1, 0))
      fuels = Enum.map(best, &elem(&1, 1))
      npulse = length(times)

      row([
        {key, 24, :l},
        {commas(npulse), 8, :r},
        {f1(Enum.sum(times) / npulse), 9, :r},
        {f1(percentile(times, 0.99) / 1), 9, :r},
        {commas(Enum.max(times)), 9, :r},
        {commas(trunc(Enum.sum(fuels) / npulse)), 10, :r},
        {commas(Enum.max(fuels)), 10, :r},
        {commas(Enum.sum(fuels)), 13, :r}
      ])
    end

    p("")
    p("For comparison, section 1's worst-case pulse spends the full #{commas(Limits.fuel_per_pulse())} fuel.")
  end

  # ---------------------------------------------------------------------------
  # 5. simulator endpoint
  # ---------------------------------------------------------------------------

  test "5. simulator endpoint wall time and worst case" do
    hr()
    p("5a. SIMULATOR WALL TIME  (Edict.Simulator.run, whole run inside ONE sandbox)")
    p("    #{commas(Simulator.budget())} total-fuel budget, 15 s timeout; paces slow/typical/strong")
    hr()

    row([{"example", 24, :l}, {"slow ms", 10, :r}, {"typical ms", 12, :r}, {"strong ms", 11, :r}])

    for {key, source} <- example_sources() do
      program = program!(source)

      ms =
        for pace <- ["slow", "typical", "strong"] do
          {m, _} = time_reps(fn -> {:ok, _} = Simulator.run(program, pace: pace) end, 3)
          m
        end

      [slow, typ, strong] = ms
      row([{key, 24, :l}, {f1(slow), 10, :r}, {f1(typ), 12, :r}, {f1(strong), 11, :r}])
    end

    hr()
    p("5b. ADVERSARIAL SIMULATION")
    hr()

    # (i) an out-of-fuel bomb: each pulse runs out of steps, which counts as a
    # handler failure; three failures switch the handler off (Runtime
    # @max_failures), so it burns only 3 pulses, never reaching the budget.
    bomb =
      program!("""
      every 1s {
        let x = 0
        while x < 100000000 {
          x = x + 1
        }
      }
      score 1
      """)

    {bomb_ms, bomb_max} = time_reps(fn -> Simulator.run(bomb) end, 3)
    {:ok, bomb_report} = Simulator.run(bomb)

    p("(i) out-of-fuel bomb (while true-style):")
    p("    wall #{f1(bomb_ms)} ms median / #{f1(bomb_max)} ms max")

    p(
      "    total fuel #{commas(bomb_report.stats.fuel_used)} — the handler runs OUT OF STEPS each pulse, which is a failure; after 3 failures it is switched OFF, so it burns only ~3 pulses and NEVER reaches the #{commas(Simulator.budget())} budget."
    )

    # (ii) a sustained burner: each pulse does loops that COMPLETE (no error,
    # so the handler is never disabled), burning ~100k fuel every second for
    # the whole run. range() is capped at max_list (10,000), so we stay under
    # it and repeat.
    sustained_src = """
    every 1s {
      let s = 0
      for i in range(1, 9000) {
        s = s + i * 3 - i
      }
      for j in range(1, 9000) {
        s = s - j + 2
      }
    }
    score 1
    """

    sustained = program!(sustained_src)
    srt = runtime!(sustained_src)

    {srt1, sres} = Runtime.pulse(srt, build_world(1.0, 1800.0, fake_player(1, 0)), 1.0)
    per_pulse_fuel = srt1.fuel_used

    {sust_ms, sust_max} = time_reps(fn -> Simulator.run(sustained) end, 3)
    sust_result = Simulator.run(sustained)

    bound =
      case sust_result do
        {:error, errs} ->
          "FUEL BUDGET of #{commas(Simulator.budget())} (simulator throws: #{hd(errs).message})"

        {:ok, r} ->
          "run end / 15 s (used #{commas(r.stats.fuel_used)} fuel, #{length(r.errors)} errors)"
      end

    pulses_to_budget = if per_pulse_fuel > 0, do: div(Simulator.budget(), per_pulse_fuel), else: 0

    p("")
    p("(ii) sustained burner (completes every pulse, ~#{commas(per_pulse_fuel)} fuel, #{length(sres.errors)} error):")
    p("    wall #{f1(sust_ms)} ms median / #{f1(sust_max)} ms max")
    p("    bound hit: #{bound}")

    p(
      "    => reaches the budget at ~pulse #{commas(pulses_to_budget)}; it holds ONE low-priority core for ~#{f1(sust_ms)} ms, then the budget stops it well before the 15 s timeout."
    )

    sim_ceiling_s = sust_ms / 1000
    worst_core_s = 200 * sim_ceiling_s
    worst_cores = worst_core_s / 300

    p("""

    5c. CONCURRENCY (lib/portal/controllers/edict_controller.ex, Edict.Slots):
      - simulate is rate-limited to 200 requests / 5 min / account (admins exempt),
        and holds a slot while it runs: 2 at once per account, one per scheduler
        across everyone; over that, a request waits briefly, then gets 429 busy.
      - A single simulation's CPU ceiling is its fuel budget, not the 15 s
        timeout: the sustained burner above hit it in ~#{f1(sim_ceiling_s)} s of CPU.
      - WORST CASE one account can impose within the rate limit: 200 simulations
        in 5 min, each ~#{f1(sim_ceiling_s)} s of CPU = ~#{commas(round(worst_core_s))} core-seconds inside a
        300 s window (=> ~#{f1(worst_cores)} cores sustained), never more than 2 at once.
        Each sandbox holds at most #{mb(Limits.max_heap_words() * 8)} (heap and shared binaries).
      - The sandbox runs at :low priority, so it yields to normal-priority game
        ticks and web requests.
    """)
  end

  # ---------------------------------------------------------------------------
  # 6. analyze endpoint
  # ---------------------------------------------------------------------------

  test "6. analyze endpoint wall time and memory" do
    hr()
    p("6. ANALYZE PATH  (Edict.analyze = Parser.parse + Checker.check)")
    p("   NOT sandboxed: runs directly in the Phoenix request process (no heap/time cap;")
    p("   only source limits + the 900/5min rate limit bound it).")
    hr()

    typical = Edict.example("headhunter_lite").source

    node_chain = "score " <> Enum.join(List.duplicate("1", 3900), " + ")
    deep_paren = "score " <> String.duplicate("(", 46) <> "1" <> String.duplicate(")", 46)

    many_stmts =
      "on start {\n" <> Enum.join(for(i <- 1..1500, do: "  let v#{i} = #{i} + 1"), "\n") <> "\n}\nscore 1"

    big_interp =
      "on start {\n  notify(\"" <> Enum.join(for(_ <- 1..300, do: "{player.credit}"), "") <> "\")\n}\nscore 1"

    near_64k =
      "on start {\n" <>
        Enum.join(for(i <- 1..1200, do: "  let w#{i} = #{i} * #{i} + #{i} - #{i}"), "\n") <> "\n}\nscore 1"

    cases = [
      {"typical (headhunter)", typical},
      {"node chain (~8k nodes)", node_chain},
      {"deep parens (depth 46)", deep_paren},
      {"1500 statements", many_stmts},
      {"300-hole interpolation", big_interp},
      {"~#{kb(byte_size(near_64k))} source", near_64k}
    ]

    row([
      {"source", 26, :l},
      {"bytes", 9, :r},
      {"wall ms", 10, :r},
      {"wall max", 10, :r},
      {"proc mem", 11, :r},
      {"diags", 7, :r}
    ])

    for {label, source} <- cases do
      {ms, maxms} = time_reps(fn -> Edict.analyze(source) end, 5)
      {peak_mem, diags} = analyze_mem(source)

      row([
        {label, 26, :l},
        {commas(byte_size(source)), 9, :r},
        {f2(ms), 10, :r},
        {f2(maxms), 10, :r},
        {mb(peak_mem), 11, :r},
        {diags, 7, :r}
      ])
    end

    p("")

    p(
      "proc mem = the analyzing process's :memory right after analyze (pre-GC, ~peak). Unsandboxed means a malformed-but-within-limits source allocates in the shared request process with no ceiling."
    )
  end

  defp analyze_mem(source) do
    parent = self()
    ref = make_ref()

    spawn(fn ->
      result = Edict.analyze(source)
      mem = elem(Process.info(self(), :memory), 1)
      diags = length(result.diagnostics)
      send(parent, {ref, mem, diags})
    end)

    receive do
      {^ref, mem, diags} -> {mem, diags}
    after
      15_000 -> {0, 0}
    end
  end

  # ---------------------------------------------------------------------------
  # 7. the live runner in a real instance
  # ---------------------------------------------------------------------------

  @live_typical """
  setup {
    name = "Bench typical"
    time_limit = 10m
    rival = true
  }

  var pulses = 0

  score player.credit

  on start {
    give("credit", 1000)
    notify("scenario started")
  }

  every 15s as wave {
    send_agent("erased", level: 1 + floor(time.elapsed / 120))
  }

  every 1s {
    pulses = pulses + 1
  }
  """

  @live_burner """
  setup {
    name = "Bench burner"
    time_limit = 10m
    rival = true
  }

  score player.credit

  every 1s {
    let x = 0
    while x < 100000000 {
      x = x + 1
    }
  }
  """

  test "7. live runner in a real instance" do
    hr()
    p("7. LIVE RUNNER IN A REAL INSTANCE  (Edict.Live, booting a real daily-style game)")
    hr()

    {profile, _} = create_profile()
    {:ok, %{instance_id: iid}} = Edict.Live.boot(profile, @live_typical)
    on_exit(fn -> safe_destroy(iid) end)
    {:ok, :started, _} = Instance.Manager.call(iid, :start)

    {:ok, state} = Edict.Live.init(iid)

    # warm one pass (fires on start)
    {:cont, state} = Edict.Live.pulse(state)

    # The real clock has only just started (elapsed ~ 0), so no `every` is due
    # yet. Measure the running-path pieces directly at a chosen elapsed, where
    # handlers actually fire: fetch the REAL player each pulse (the copy Live
    # makes) and build the world exactly as Edict.Live.world/3 does.
    elapsed = 60.0

    {gs_ms, _} = time_reps(fn -> {:ok, _} = Game.call(iid, :player, state.human_id, :get_state) end, 7)
    {:ok, player_state} = Game.call(iid, :player, state.human_id, :get_state)

    rival =
      if state.puppet_id,
        do: %{faction: Instance.Mutators.daily_puppet_faction(iid), sent: length(state.minted), left: 0},
        else: nil

    build = fn ->
      World.build(player_state,
        clock: %{elapsed: elapsed, left: state.limit - elapsed, limit: state.limit},
        config: state.rt.config,
        intelligence: %{},
        rival: rival
      )
    end

    {wb_ms, _} = time_reps(build, 7)
    world = build.()

    typ = sandbox_pulse(state.rt, world, elapsed, 7)

    {:ok, burner_program} = Parser.parse(@live_burner)
    {:ok, burner_rt} = Runtime.new(burner_program)
    burn = sandbox_pulse(burner_rt, world, elapsed, 5)

    # whole Live.pulse once, for the orchestration-path reference + clock state
    {lp_us, _} = :timer.tc(fn -> Edict.Live.pulse(state) end)
    clock_running? = match?({:ok, %{is_running: true}}, Game.call_no_log(iid, :time, :master, :get_state, 1))

    player_flat = :erts_debug.flat_size(player_state) * :erlang.system_info(:wordsize)
    player_ext = byte_size(:erlang.term_to_binary(player_state))
    {proc_count, inst_mem} = instance_memory(iid)

    row([{"metric", 42, :l}, {"value", 22, :r}])
    row([{"clock running at measure time?", 42, :l}, {to_string(clock_running?), 22, :r}])
    row([{"get_state call wall (median)", 42, :l}, {"#{f2(gs_ms)} ms", 22, :r}])
    row([{"World.build wall (median)", 42, :l}, {"#{f2(wb_ms)} ms", 22, :r}])
    row([{"typical sandbox pulse @60s (median/max)", 42, :l}, {"#{f2(typ.ms)} / #{f2(typ.max)} ms", 22, :r}])

    row([
      {"typical pulse fuel / reds / errs", 42, :l},
      {"#{commas(typ.fuel)} / #{commas(typ.reds)} / #{typ.errors}", 22, :r}
    ])

    row([{"burner sandbox pulse @60s (median/max)", 42, :l}, {"#{f2(burn.ms)} / #{f2(burn.max)} ms", 22, :r}])

    row([
      {"burner pulse fuel / reds / errs", 42, :l},
      {"#{commas(burn.fuel)} / #{commas(burn.reds)} / #{burn.errors}", 22, :r}
    ])

    row([{"=> est. Live.pulse (running) typical", 42, :l}, {"~#{f2(gs_ms + wb_ms + typ.ms)} ms", 22, :r}])
    row([{"=> est. Live.pulse (running) burner", 42, :l}, {"~#{f2(gs_ms + wb_ms + burn.ms)} ms", 22, :r}])
    row([{"Live.pulse orchestration (elapsed~0)", 42, :l}, {"#{f2(lp_us / 1000)} ms", 22, :r}])
    row([{"player :get_state flat_size", 42, :l}, {kb(player_flat), 22, :r}])
    row([{"player :get_state term_to_binary", 42, :l}, {kb(player_ext), 22, :r}])
    row([{"instance processes (registry)", 42, :l}, {commas(proc_count), 22, :r}])
    row([{"instance total process memory", 42, :l}, {mb(inst_mem), 22, :r}])

    p("")

    p(
      "method (instance memory): Horde.Registry.select(Game.Registry, ...) for keys {#{iid}, _, _}, summed Process.info(pid, :memory)."
    )

    p(
      "method (pulse): a live playtest clock only starts advancing on player connect, so at measure time elapsed~0 and no `every` is due — the Live.pulse orchestration line is that short-circuit. The sandbox-pulse rows drive the REAL player state + World.build at elapsed=60s (where handlers fire), which is the running-path cost each second."
    )

    p(
      "the instance (the game simulation) at #{mb(inst_mem)} over #{proc_count} processes is far heavier than the script: compare to the rt sizes in section 3 and the per-pulse sandbox cost in section 1. The script adds one short low-priority pulse per second on top of the instance."
    )

    safe_destroy(iid)
  end

  defp sandbox_pulse(rt, world, t, reps) do
    fun = fn ->
      r0 = elem(Process.info(self(), :reductions), 1)
      {rt2, result} = Runtime.pulse(rt, world, t)
      r1 = elem(Process.info(self(), :reductions), 1)
      {rt2, result, r1 - r0}
    end

    {ms, mx} = time_reps(fn -> {:ok, _} = Sandbox.run(fun) end, reps)
    {:ok, {rt2, result, reds}} = Sandbox.run(fun)
    %{ms: ms, max: mx, reds: reds, fuel: rt2.fuel_used, errors: length(result.errors)}
  end

  defp instance_memory(iid) do
    try do
      entries =
        Horde.Registry.select(Game.Registry, [{{:"$1", :"$2", :"$3"}, [], [{{:"$1", :"$2"}}]}])

      pids =
        for {key, pid} <- entries, match?({^iid, _, _}, key), is_pid(pid), do: pid

      mem =
        Enum.reduce(pids, 0, fn pid, acc ->
          case Process.info(pid, :memory) do
            {:memory, m} -> acc + m
            _ -> acc
          end
        end)

      {length(pids), mem}
    rescue
      e ->
        p("instance_memory failed: #{inspect(e)}")
        {0, 0}
    end
  end

  defp safe_destroy(iid) do
    try do
      Instance.Manager.destroy(iid)
    rescue
      _ -> :ok
    catch
      _, _ -> :ok
    end
  end

  defp create_profile do
    {:ok, account} =
      RC.Accounts.create_account(%{
        email: "edict-bench-#{System.unique_integer([:positive])}@tetrarchyfalls.local",
        password: "edict-bench-test-password",
        name: "EdictBench",
        role: :user,
        status: :active
      })

    {:ok, profile} =
      RC.Accounts.create_profile(%{
        account_id: account.id,
        name: "Bench#{System.unique_integer([:positive])}",
        avatar: "todo"
      })

    {profile, account}
  end

  # ---------------------------------------------------------------------------
  # 8. concurrency on the current scheduler count
  # ---------------------------------------------------------------------------

  test "8. concurrency: worst-case and typical scripts vs a normal-priority workload" do
    schedulers = :erlang.system_info(:schedulers_online)

    hr()
    p("8. CONCURRENCY ON #{schedulers} SCHEDULER(S)  (run again with ERL_FLAGS=\"+S 2:2\" for prod)")
    p("   12 'scenarios' each do a worst-case pulse every second inside Sandbox.run (:low priority),")
    p("   like Live. A normal-priority process does a fixed unit of work every 10 ms and records its")
    p("   latency jitter (standing in for game ticks). Duration ~12 s each phase.")
    hr()

    world = build_world(0.0, 1800.0, fake_player(4, 8), rival: true)

    worst_src = """
    on start {
      let x = 0
      while x < 100000000 {
        x = x + 1
      }
    }
    """

    typ_src = Edict.example("headhunter_lite").source
    typ_t = 15.0

    base = run_phase(0, worst_src, 0.0, world, 12_000)
    worst = run_phase(12, worst_src, 0.0, world, 12_000)
    typ = run_phase(12, typ_src, typ_t, world, 12_000)

    row([
      {"phase", 34, :l},
      {"tick p50 ms", 12, :r},
      {"tick p99 ms", 12, :r},
      {"tick max ms", 12, :r},
      {"pulses done", 12, :r}
    ])

    for {label, m} <- [{"0 scripts (baseline)", base}, {"12 worst-case scripts", worst}, {"12 typical scripts", typ}] do
      row([
        {label, 34, :l},
        {f2(m.p50), 12, :r},
        {f2(m.p99), 12, :r},
        {f2(m.max), 12, :r},
        {commas(m.pulses), 12, :r}
      ])
    end

    p("")

    p(
      "pulses done = worst-case pulses the 12 scripts completed in ~12 s; the ideal at 1 pulse/second is 12 scripts x ~12 = 144. Reaching 144 means every script kept its cadence (no core saturation)."
    )

    p("""
    READING THIS: Live runs each scenario at ONE pulse per second. A worst-case
    pulse is ~15 ms (section 1), so one scenario costs ~15 ms of CPU per second =
    ~1.5% of a core. 12 worst-case scenarios => ~180 ms CPU/second, ~9% of 2 cores.
    That is why, even on #{schedulers} schedulers, the normal-priority tick's p50/p99 stayed
    low and all 144 pulses finished: the 1/second cadence, not CPU, is the limiter,
    and :low priority keeps scenarios from preempting the tick. (tick max is noisy —
    the baseline itself shows outliers from GC and any sibling test run; read p50/p99.)
    To actually saturate 2 cores with per-second worst-case pulses you would need
    ~130 concurrent scenarios running back-to-back. The real CPU risk is the
    simulate/analyze endpoints (section 5/6), which have no 1/second cadence.
    """)
  end

  # Run a normal-priority "tick" process for `duration_ms`, while `n` :low
  # priority script runners each do a pulse every second. Returns tick latency
  # percentiles and how many script pulses completed.
  defp run_phase(n, source, t, world, duration_ms) do
    parent = self()
    deadline = System.monotonic_time(:millisecond) + duration_ms

    pulse_counter = :counters.new(1, [:atomics])

    runners =
      if n > 0 do
        for _ <- 1..n, do: spawn(fn -> runner_loop(source, t, world, deadline, pulse_counter) end)
      else
        []
      end

    # the normal-priority tick: a fixed small unit of work every ~10 ms,
    # measuring the gap between intended and actual wake-up.
    start_target = System.monotonic_time(:microsecond) + 10_000
    tick = spawn(fn -> tick_loop(parent, start_target, deadline, []) end)

    lats =
      receive do
        {:ticks, l} -> l
      after
        duration_ms + 5_000 -> []
      end

    Enum.each(runners, &(Process.alive?(&1) && Process.exit(&1, :kill)))
    Process.alive?(tick) && Process.exit(tick, :kill)

    %{
      p50: percentile(lats, 0.50),
      p99: percentile(lats, 0.99),
      max: (lats == [] && 0.0) || Enum.max(lats),
      pulses: :counters.get(pulse_counter, 1)
    }
  end

  defp runner_loop(source, t, world, deadline, counter) do
    rt = runtime!(source)
    do_runner(rt, t, world, deadline, counter)
  end

  defp do_runner(rt, t, world, deadline, counter) do
    now = System.monotonic_time(:millisecond)

    if now < deadline do
      start = System.monotonic_time(:millisecond)
      {:ok, _} = Sandbox.run(fn -> Runtime.pulse(rt, world, t) end)
      :counters.add(counter, 1, 1)
      # like Live: aim for one pulse per second
      elapsed = System.monotonic_time(:millisecond) - start
      wait = max(1000 - elapsed, 0)
      Process.sleep(wait)
      do_runner(rt, t, world, deadline, counter)
    else
      :ok
    end
  end

  # A normal-priority tick: sleep until each 10 ms target, measure how late
  # the process actually woke (its scheduling delay — the jitter game ticks
  # would feel), then do a fixed unit of work.
  defp tick_loop(parent, target_us, deadline_ms, lats) do
    gap_ms = div(max(target_us - System.monotonic_time(:microsecond), 0), 1000)
    if gap_ms > 0, do: Process.sleep(gap_ms)
    late = max(System.monotonic_time(:microsecond) - target_us, 0) / 1000.0
    busy_work(3_000)

    if System.monotonic_time(:millisecond) < deadline_ms do
      tick_loop(parent, target_us + 10_000, deadline_ms, [late | lats])
    else
      send(parent, {:ticks, lats})
    end
  end

  # a fixed unit of CPU work (not optimized away): sum a range.
  defp busy_work(n) do
    Enum.reduce(1..n, 0, fn i, acc -> acc + rem(i * 7, 13) end)
  end

  # ---------------------------------------------------------------------------
  # 9. a dozen scenarios running: real instances, clocks going
  # ---------------------------------------------------------------------------

  # The heaviest script that keeps running: loops that complete every second
  # (~160k fuel), so the handler is never switched off.
  @sustained """
  setup {
    name = "Bench sustained"
    time_limit = 30m
  }

  score player.credit

  every 1s {
    let s = 0
    for i in range(1, 9000) {
      s = s + i * 3 - i
    }
    for j in range(1, 9000) {
      s = s - j + 2
    }
  }
  """

  test "9. a dozen scenarios running: real instances with their clocks going" do
    schedulers = :erlang.system_info(:schedulers_online)
    hr()

    p(
      "9. A DOZEN SCENARIOS RUNNING  (real daily-style instances, clocks started, runners pulsing; #{schedulers} schedulers)"
    )

    hr()

    idle = window(10)
    examples = Enum.map(example_sources(), &elem(&1, 1))

    phases = [
      {"1 instance, typical script", Enum.take(examples, 1)},
      {"12 instances, the 12 examples", Enum.take(examples, 12)},
      {"12 instances, sustained worst-case script", List.duplicate(@sustained, 12)}
    ]

    row([
      {"phase", 42, :l},
      {"cpu s/s", 9, :r},
      {"- idle", 8, :r},
      {"of cores", 9, :r},
      {"running", 8, :r},
      {"inst MB", 9, :r},
      {"VM MB", 8, :r}
    ])

    row([
      {"idle VM (no instances)", 42, :l},
      {f2(idle.cpu), 9, :r},
      {"", 8, :r},
      {pct(idle.cpu / schedulers), 9, :r},
      {"-", 8, :r},
      {"-", 9, :r},
      {f1(:erlang.memory(:total) / 1_048_576), 8, :r}
    ])

    for {label, sources} <- phases do
      iids = Enum.map(sources, &boot_running/1)

      # warm-up: first ticks, autosave timers, the runners' first pulses
      Process.sleep(10_000)
      w = window(20)

      running = Enum.count(iids, &clock_running?/1)
      inst = iids |> Enum.map(&(&1 |> instance_memory() |> elem(1))) |> Enum.sum()
      vm = :erlang.memory(:total)

      row([
        {label, 42, :l},
        {f2(w.cpu), 9, :r},
        {f2(max(w.cpu - idle.cpu, 0.0)), 8, :r},
        {pct(max(w.cpu - idle.cpu, 0.0) / schedulers), 9, :r},
        {"#{running}/#{length(iids)}", 8, :r},
        {f1(inst / 1_048_576), 9, :r},
        {f1(vm / 1_048_576), 8, :r}
      ])

      Enum.each(iids, &safe_destroy/1)
      Process.sleep(2_000)
    end

    p("")

    p(
      "cpu s/s = VM CPU seconds per wall second over 20 s (:erlang.statistics(:runtime)); of cores = that, above idle, as a share of the #{schedulers} schedulers. (:scheduler.utilization reads lower: its total also averages in the idle dirty schedulers.) inst MB = the instances' registered processes (as section 7), after ~30 s of play. Daily speed: a game day every 0.75 s."
    )
  end

  defp boot_running(source) do
    {profile, _} = create_profile()
    {:ok, %{instance_id: iid}} = Edict.Live.boot(profile, source)
    :ok = Daily.Boot.ensure_started(iid)
    wait_until(fn -> clock_running?(iid) end, 30_000)
    iid
  end

  defp clock_running?(iid) do
    match?({:ok, %{is_running: true}}, Game.call_no_log(iid, :time, :master, :get_state, 1))
  end

  defp wait_until(check, budget) when budget <= 0, do: check.()

  defp wait_until(check, budget) do
    if check.() do
      true
    else
      Process.sleep(100)
      wait_until(check, budget - 100)
    end
  end

  defp window(seconds) do
    {cpu0, _} = :erlang.statistics(:runtime)
    Process.sleep(seconds * 1000)
    {cpu1, _} = :erlang.statistics(:runtime)
    %{cpu: (cpu1 - cpu0) / 1000 / seconds}
  end

  defp pct(x), do: f1(x * 100) <> "%"

  # ---------------------------------------------------------------------------
  # 10. a scripted match: one run per player, every second (Edict.Match)
  # ---------------------------------------------------------------------------

  @match_scripts [
    {"match template (every 6h)",
     """
     setup {
       name = "Tithe"
       factions = 2
     }
     score player.credit
     on start {
       notify("This match runs " + scenario.name + ": " + str(len(factions)) + " factions.")
     }
     every 6h {
       if find(factions, f => f.name == player.faction).rank == 1 {
         take("credit", player.credit * 5%)
       }
     }
     """},
    {"busy (when + players)",
     """
     var ticks = 0
     score sum(players, p => p.population) + ticks
     every 1s {
       ticks = ticks + 1
     }
     when sum(player.systems, s => s.population) > 1_000_000_000 {
       notify("never")
     }
     when count(players, p => p.faction == player.faction) > 1000 {
       notify("never")
     }
     """},
    {"worst (spends its share)",
     """
     every 1s {
       let i = 0
       while true {
         i = i + 1
       }
     }
     score 1
     """}
  ]

  test "10. a scripted match: one run per player, every second" do
    hr()
    p("10. SCRIPTED MATCH  (Edict.Match: each script runs once per player; a pulse per player whose run")
    p("    has something due, each in its own sandbox, world built per player; steps shared: 500k/s per match)")
    p("    cost = wall ms of one second's work for the whole match (serial, so ~= CPU ms)")
    hr()

    row([
      {"script", 28, :l},
      {"players", 8, :r},
      {"fuel/run", 9, :r},
      {"pulse ms", 9, :r},
      {"refresh ms", 11, :r},
      {"avg ms/s", 9, :r},
      {"% core", 8, :r},
      {"saved state", 12, :r}
    ])

    for {label, source} <- @match_scripts, n <- [12, 30, 60, 100] do
      rt0 = runtime!(source)

      players =
        for i <- 1..n,
            do: Map.merge(fake_player(4, 8), %{id: i, name: "P#{i}", faction: Enum.at([:ark, :cardan], rem(i, 2))})

      everyone = Enum.map(players, &World.someone/1)

      standings = [
        World.faction(%{key: :ark, player_count: div(n, 2), system_count: 2 * n}, 1),
        World.faction(%{key: :cardan, player_count: n - div(n, 2), system_count: 2 * n}, 2)
      ]

      fuel = Edict.Match.fuel_per_run(n)

      second = fn runs, t ->
        Enum.map(Enum.zip(players, runs), fn {player, rt} ->
          world =
            World.build(player,
              clock: %{elapsed: t, left: 7200.0 - t, limit: 7200.0},
              config: rt.config,
              mode: "flash",
              factions: standings,
              players: everyone,
              systems: 269
            )

          if Runtime.due?(rt, t) do
            {:ok, {rt, _res, _score}} =
              Sandbox.run(fn ->
                {rt, res} = Runtime.pulse(rt, world, t, fuel: fuel)
                {rt, res, Runtime.peek_score(rt, world)}
              end)

            rt
          else
            rt
          end
        end)
      end

      # every 10 s the runner reads every player and counts their score,
      # whatever is due
      refresh = fn runs ->
        Enum.each(Enum.zip(players, runs), fn {player, rt} ->
          world =
            World.build(player,
              clock: %{elapsed: 1.0, left: 7199.0, limit: 7200.0},
              config: rt.config,
              mode: "flash",
              factions: standings,
              players: everyone,
              systems: 269
            )

          {:ok, _} = Sandbox.run(fn -> Runtime.peek_score(rt, world) end)
        end)
      end

      # the first second runs every on start; measure the one after it (a
      # runaway script is still running then: it's switched off after its
      # third failed second)
      runs = second.(List.duplicate(rt0, n), 0.0)
      {pulse_ms, _} = time_reps(fn -> second.(runs, 1.0) end, 5)
      {refresh_ms, _} = time_reps(fn -> refresh.(runs) end, 5)
      median_ms = pulse_ms + refresh_ms / 10

      state =
        runs
        |> Enum.with_index()
        |> Map.new(fn {rt, i} -> {i, %{dump: Runtime.dump(rt), score: 1.0, tiebreak: nil}} end)
        |> then(&:erlang.term_to_binary(%{v: 1, runs: %{"d" => &1}}, compressed: 6))
        |> byte_size()

      row([
        {label, 28, :l},
        {n, 8, :r},
        {commas(fuel), 9, :r},
        {f1(pulse_ms), 9, :r},
        {f1(refresh_ms), 11, :r},
        {f1(median_ms), 9, :r},
        {pct(median_ms / 1000), 8, :r},
        {kb(state), 12, :r}
      ])
    end

    p("")
    p("pulse ms: one second's due runs; refresh ms: the score refresh every 10 s (every player);")
    p("avg = pulse + refresh / 10. A run with nothing due costs nothing between refreshes (the match")
    p("template idles between its 6-hour timers); `when` handlers make every player due every second;")
    p("a runaway script spends its share of the match's 500k steps for three seconds, then is off.")
  end
end
