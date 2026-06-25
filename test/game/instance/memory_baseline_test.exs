defmodule Game.Instance.MemoryBaselineTest do
  @moduledoc """
  Memory baseline harness for the system-process-clustering investigation.

  NOT part of the normal suite (tagged `:mem_bench`, excluded in
  test_helper.exs). Run it explicitly:

      MIX_ENV=test mix test --only mem_bench test/game/instance/memory_baseline_test.exs

  ## What it answers

  The load-bearing question before we invest in any clustering algorithm:
  is the per-system memory a **reclaimable heap watermark** (→ cheap fixes:
  share game-data via persistent_term / slice the Querier lookup / hibernate
  idle systems) or **genuinely retained live data** (→ shrink the struct or
  batch processes)?

  It measures, for a freshly-created-and-started galaxy:

    1. The size of the game-data blob copied onto a process heap on *every*
       cached `Data.Querier` lookup (`Data.Data.get/2` returns the whole
       content map — see lib/data/data.ex / lib/data/querier.ex).
    2. Global `:erlang.memory/0` at four checkpoints (base → after create →
       after start+settle → after a forced GC of every system process).
    3. Per-system process memory (`Process.info/2 :memory`) vs. the *flat
       size* of the retained `StellarSystem` struct (`:erts_debug.flat_size`),
       broken down by system status, before and after a forced GC.

  The headline number is the **GC-reclaimable fraction**: (mem_before_gc -
  mem_after_gc) / mem_before_gc across all system processes. High → the cost
  is transient watermark (cheap fixes win). Low → the cost is retained
  (clustering / struct-shrink territory).

  Status is read via `:sys.get_state/2` (the OTP sys protocol) rather than
  `GenServer.call(pid, :get_state)` on purpose: the agent's `:get_state`
  handler is wrapped by `@decorate tick()` (lib/.../stellar_system/agent.ex),
  so calling it would advance a tick and copy the blob — perturbing the very
  heap we are trying to measure. `:sys.get_state` returns the current state
  without invoking the handler.
  """
  use RC.DataCase, async: false

  require Logger

  alias Instance.Manager

  @moduletag :mem_bench
  # Spin-up of a few hundred systems plus a ~10s graceful teardown.
  @moduletag timeout: 600_000

  @wordsize :erlang.system_info(:wordsize)
  # Project measured per-system numbers up to a hypothetical large galaxy.
  @projection_target 5_000

  test "memory baseline of a freshly-started galaxy" do
    # A/B profiler: pick the content-memory model under test. Run twice to
    # compare — `RC_DATA_MEMORY_MODE=legacy` (copy-per-lookup) vs `=shared`
    # (persistent_term). The instance bakes in whatever the global is at
    # create time. Defaults to :shared.
    mode = (System.get_env("RC_DATA_MEMORY_MODE") || "shared") |> String.to_atom()
    Data.Data.set_memory_mode(mode)

    # Deterministic generation so legacy/shared A/B runs profile the IDENTICAL
    # galaxy (same neutral systems, positions) — an apples-to-apples comparison.
    Application.put_env(:rc, :deterministic_generation, true)

    :erlang.garbage_collect()
    base = mem_snapshot()

    # ---- create the instance (spawns one process per system) ----
    %{instance: instance} = RC.ScenarioFixtures.valid_instance_fixture()
    instance = RC.Instances.get_instance_with_registration(instance.id)
    iid = instance.id

    declared =
      (instance.game_data["sectors"] || [])
      |> Enum.flat_map(fn s -> s["systems"] || [] end)
      |> length()

    assert declared > 0, "fixture galaxy declares no systems — cannot measure"

    # ---- peak sampler across the whole create + start burst ----
    # A high-priority process polling :erlang.memory every ~1ms, so we catch
    # the transient high-water (which the discrete post-settle snapshots miss).
    # This is the number that sizes the server: a 16GB peak that settles to
    # 200MB still needs a 16GB box.
    sampler = start_peak_sampler()

    {:ok, :instantiated} = Manager.create_from_model(instance, nil)
    after_create = mem_snapshot()

    # ---- start ticking; let the initial (delay-0) :tick land everywhere ----
    {:ok, :started, _count} = Manager.call(iid, :start)
    Process.sleep(3_000)
    after_start = mem_snapshot()
    peak = stop_peak_sampler(sampler)

    # ---- size the game-data blob copied per Querier lookup ----
    blob = blob_sizing(iid)

    # ---- per-system: watermark memory + retained struct size + status ----
    pids = system_pids(iid)
    pre = Enum.map(pids, &sys_probe/1)

    # drop the structs we just copied out of the *test* heap so they don't
    # pollute the post-GC global snapshot.
    :erlang.garbage_collect()

    # ---- force an explicit MAJOR (fullsweep) GC on every system ----
    # Explicit {:type, :major} so we know old-heap garbage (a blob copy
    # promoted out of the young generation by an earlier collection) is
    # reclaimed — a plain garbage_collect/1 can do a generational sweep
    # that leaves it behind.
    Enum.each(pids, fn pid -> :erlang.garbage_collect(pid, [{:type, :major}]) end)
    :erlang.garbage_collect()
    after_gc = mem_snapshot()
    post = Map.new(pids, fn pid -> {pid, proc_mem(pid)} end)

    # ---- floor diagnostic ----
    # For the heaviest idle (uninhabited) systems post-GC, compare process
    # memory against (a) total_heap_size and (b) the flat size of the WHOLE
    # gen_state. If memory ≈ flat_size(full state) → the floor is genuine
    # live data; if memory >> flat_size → it's heap slack the allocator
    # hasn't returned (which clustering would amortise away).
    floor_diag =
      pre
      |> Enum.filter(&(&1.status == :uninhabited))
      |> Enum.sort_by(&(-Map.get(post, &1.pid, 0)))
      |> Enum.take(5)
      |> Enum.map(fn e ->
        info = Process.info(e.pid, [:memory, :total_heap_size, :heap_size, :message_queue_len])

        full_state_bytes =
          try do
            :erts_debug.flat_size(:sys.get_state(e.pid, 5_000)) * @wordsize
          catch
            _, _ -> 0
          end

        %{pid: e.pid, info: info, full_state_bytes: full_state_bytes}
      end)

    report =
      build_report(%{
        mode: mode,
        peak: peak,
        iid: iid,
        declared: declared,
        base: base,
        after_create: after_create,
        after_start: after_start,
        after_gc: after_gc,
        blob: blob,
        pre: pre,
        post: post,
        floor_diag: floor_diag
      })

    IO.puts("\n" <> report)
    write_report(report, "#{mode}_#{length(pids)}")

    # Teardown can take ~5-10s (each TickServer sleeps in graceful_terminate);
    # the report is already emitted, so we don't lose results if this is slow.
    safe_destroy(iid)

    assert length(pids) > 0
  end

  # ---------------------------------------------------------------------------
  # Probes
  # ---------------------------------------------------------------------------

  # ---- peak sampler -----------------------------------------------------
  # High-priority process polling :erlang.memory every ~1ms; tracks the max
  # total/processes across the startup window so we capture the transient
  # high-water the discrete snapshots miss.
  defp start_peak_sampler do
    spawn(fn ->
      Process.flag(:priority, :high)
      peak_loop(%{total: 0, processes: 0, binary: 0})
    end)
  end

  defp peak_loop(peak) do
    receive do
      {:stop, from} -> send(from, {:peak, peak})
    after
      1 ->
        m = :erlang.memory()

        peak_loop(%{
          total: max(peak.total, m[:total]),
          processes: max(peak.processes, m[:processes]),
          binary: max(peak.binary, m[:binary])
        })
    end
  end

  defp stop_peak_sampler(pid) do
    send(pid, {:stop, self()})

    receive do
      {:peak, peak} -> peak
    after
      5_000 -> %{total: 0, processes: 0, binary: 0}
    end
  end

  defp mem_snapshot do
    m = :erlang.memory()

    %{
      total: m[:total],
      processes: m[:processes],
      binary: m[:binary],
      ets: m[:ets],
      proc_count: :erlang.system_info(:process_count)
    }
  end

  defp proc_mem(pid) do
    case Process.info(pid, :memory) do
      {:memory, bytes} -> bytes
      nil -> 0
    end
  end

  # Read memory FIRST (cheap, no message), then status/struct-size via the
  # sys protocol (does not trigger the tick decorator).
  defp sys_probe(pid) do
    mem = proc_mem(pid)

    try do
      gs = :sys.get_state(pid, 5_000)
      %{pid: pid, mem: mem, status: gs.data.status, struct_bytes: :erts_debug.flat_size(gs.data) * @wordsize}
    rescue
      _ -> %{pid: pid, mem: mem, status: :error, struct_bytes: 0}
    catch
      _, _ -> %{pid: pid, mem: mem, status: :error, struct_bytes: 0}
    end
  end

  defp system_pids(iid) do
    case Instance.Supervisor.get_pid(iid) do
      {:ok, sup} ->
        sup
        |> DynamicSupervisor.which_children()
        |> Enum.filter(fn {_, _pid, _, mods} -> mods == [Instance.StellarSystem.Agent] end)
        |> Enum.map(fn {_, pid, _, _} -> pid end)
        |> Enum.filter(&is_pid/1)

      _ ->
        []
    end
  end

  # The whole content map (`%{Data.Game.Building => [...], ...}`) is what
  # `Data.Data.get(iid, :data)` returns and copies to the caller's heap on
  # every `Data.Querier.one/all` call. flat_size = the actual per-copy cost.
  defp blob_sizing(iid) do
    data = Data.Data.get(iid, :data)
    full_words = :erts_debug.flat_size(data)

    per_module =
      data
      |> Enum.map(fn {mod, content} -> {mod, :erts_debug.flat_size(content) * @wordsize} end)
      |> Enum.sort_by(fn {_, b} -> -b end)

    %{full_bytes: full_words * @wordsize, per_module: per_module}
  end

  defp safe_destroy(iid) do
    Manager.destroy(iid)
  rescue
    e -> Logger.warning("mem_bench teardown raised: #{Exception.message(e)}")
  catch
    kind, reason -> Logger.warning("mem_bench teardown #{kind}: #{inspect(reason)}")
  end

  # ---------------------------------------------------------------------------
  # Reporting
  # ---------------------------------------------------------------------------

  defp build_report(d) do
    n = length(d.pre)
    total_pre = d.pre |> Enum.map(& &1.mem) |> Enum.sum()
    total_post = d.post |> Map.values() |> Enum.sum()
    total_struct = d.pre |> Enum.map(& &1.struct_bytes) |> Enum.sum()
    reclaimed = total_pre - total_post
    reclaim_pct = if total_pre > 0, do: reclaimed / total_pre * 100, else: 0.0
    scale = @projection_target / max(n, 1)

    by_status =
      d.pre
      |> Enum.group_by(& &1.status)
      |> Enum.map(fn {status, es} ->
        c = length(es)
        pre_sum = es |> Enum.map(& &1.mem) |> Enum.sum()
        post_sum = es |> Enum.map(fn e -> Map.get(d.post, e.pid, 0) end) |> Enum.sum()
        struct_sum = es |> Enum.map(& &1.struct_bytes) |> Enum.sum()
        %{status: status, count: c, pre: pre_sum, post: post_sum, struct: struct_sum}
      end)
      |> Enum.sort_by(& -&1.pre)

    top = d.pre |> Enum.sort_by(& -&1.mem) |> Enum.take(8)

    [
      "================ SYSTEM-PROCESS MEMORY BASELINE ================",
      "content-memory MODE=#{d.mode}  instance=#{d.iid}  systems(declared)=#{d.declared}  systems(measured)=#{n}",
      "schedulers=#{System.schedulers_online()}  wordsize=#{@wordsize}B  proc_count=#{d.after_start.proc_count}",
      "",
      "---- game-data content map (size of the per-(speed,mode) blob) ----",
      "  content map size: #{human(d.blob.full_bytes)}  (pre-fix: copied to heap on EVERY Querier lookup; post-fix: shared via persistent_term)",
      "  largest modules:",
      d.blob.per_module
      |> Enum.take(8)
      |> Enum.map_join("\n", fn {mod, b} -> "    #{String.pad_trailing(short_mod(mod), 26)} #{human(b)}" end),
      "",
      "---- global :erlang.memory (total / processes / binary / ets) ----",
      mem_row("base                ", d.base),
      mem_row("after create        ", d.after_create),
      mem_row("after start+settle  ", d.after_start),
      mem_row("after system GC     ", d.after_gc),
      "  >>> STARTUP PEAK (1ms sampling): total=#{human(d.peak.total)}  processes=#{human(d.peak.processes)} <<<",
      "  delta create->start (processes): #{human(d.after_start.processes - d.after_create.processes)}",
      "  delta start->GC     (processes): #{human(d.after_gc.processes - d.after_start.processes)}  (negative = reclaimed)",
      "",
      "---- per-system aggregate (#{n} processes) ----",
      "  process memory  before GC: #{human(total_pre)}   (avg #{human(div(total_pre, max(n, 1)))}/system)",
      "  process memory  after  GC: #{human(total_post)}   (avg #{human(div(total_post, max(n, 1)))}/system)",
      "  retained struct (flat_size): #{human(total_struct)}   (avg #{human(div(total_struct, max(n, 1)))}/system)",
      "  >>> GC-reclaimable fraction: #{fmt(reclaim_pct)}%  (#{human(reclaimed)}) <<<",
      "",
      "---- by status (sorted by pre-GC memory) ----",
      "  status                 count   preGC      postGC     struct(retained)  avg postGC/sys",
      by_status
      |> Enum.map_join("\n", fn s ->
        "  #{String.pad_trailing(to_string(s.status), 20)} #{String.pad_leading(to_string(s.count), 6)}  " <>
          "#{pad(human(s.pre), 10)} #{pad(human(s.post), 10)} #{pad(human(s.struct), 16)} #{human(div(s.post, max(s.count, 1)))}"
      end),
      "",
      "---- top 8 heaviest system processes ----",
      top
      |> Enum.map_join("\n", fn e ->
        "  #{inspect(e.pid)}  #{String.pad_trailing(to_string(e.status), 20)} mem=#{pad(human(e.mem), 10)} struct=#{human(e.struct_bytes)}"
      end),
      "",
      "---- floor diagnostic: heaviest idle (uninhabited) systems, post major-GC ----",
      "  (memory vs total_heap vs flat_size(full state) — gap = unreturned heap slack)",
      d.floor_diag
      |> Enum.map_join("\n", fn f ->
        mem = f.info[:memory] || 0
        heap = (f.info[:total_heap_size] || 0) * @wordsize
        "  #{inspect(f.pid)}  mem=#{pad(human(mem), 10)} total_heap=#{pad(human(heap), 10)} " <>
          "flat_size(state)=#{pad(human(f.full_state_bytes), 10)} mqueue=#{f.info[:message_queue_len]}"
      end),
      "",
      "---- projection to #{@projection_target} systems (LINEAR extrapolation; current mix is player-free) ----",
      "  projected watermark (pre-GC):  #{human(round(total_pre * scale))}",
      "  projected retained  (post-GC): #{human(round(total_post * scale))}",
      "  projected struct only:         #{human(round(total_struct * scale))}",
      "  NOTE: no players registered, so no inhabited_player/dominion systems — the",
      "        heaviest (production queues, governors, characters) are absent here.",
      "==============================================================="
    ]
    |> Enum.join("\n")
  end

  defp mem_row(label, s) do
    "  #{label} total=#{pad(human(s.total), 10)} processes=#{pad(human(s.processes), 10)} binary=#{pad(human(s.binary), 10)} ets=#{human(s.ets)}"
  end

  defp write_report(report, n) do
    dir = Path.join(File.cwd!(), "tmp")
    File.mkdir_p!(dir)
    path = Path.join(dir, "mem_baseline_#{n}.txt")
    File.write!(path, report)
    IO.puts("\n[report written to #{path}]")
  rescue
    _ -> :ok
  end

  defp short_mod(mod), do: mod |> inspect() |> String.replace_prefix("Data.Game.", "")

  defp human(bytes) when is_integer(bytes) and bytes < 0, do: "-" <> human(-bytes)

  defp human(bytes) when is_integer(bytes) do
    cond do
      bytes >= 1_073_741_824 -> fmt(bytes / 1_073_741_824) <> " GB"
      bytes >= 1_048_576 -> fmt(bytes / 1_048_576) <> " MB"
      bytes >= 1024 -> fmt(bytes / 1024) <> " KB"
      true -> "#{bytes} B"
    end
  end

  defp fmt(f), do: :erlang.float_to_binary(f / 1, decimals: 2)
  defp pad(s, n), do: String.pad_trailing(s, n)
end
