defmodule Wave.Profile do
  @moduledoc """
  Dev-only CPU attribution for a running node: samples every process's
  reduction count across a window and reports where the work went, grouped by
  instance agent type (`:stellar_system`, `:character`, `:player`, `:wave`, …).

  Reductions are the BEAM's unit of scheduled work, so the deltas are a direct
  measure of which processes consumed scheduler time during the window. Reached
  through `GET /api/harness/wave/profile`; never exposed outside dev/test.
  """

  @max_ms 15_000

  def sample(ms) when is_integer(ms) do
    ms = ms |> max(200) |> min(@max_ms)
    before = snapshot()
    utilization = scheduler_utilization(ms)
    later = snapshot()

    deltas =
      later
      |> Enum.map(fn {pid, reductions} -> {pid, reductions - Map.get(before, pid, 0)} end)
      |> Enum.filter(fn {_pid, delta} -> delta > 0 end)

    total = deltas |> Enum.map(&elem(&1, 1)) |> Enum.sum()
    labelled = Enum.map(deltas, fn {pid, delta} -> {label(pid), delta} end)

    by_group =
      labelled
      |> Enum.group_by(fn {label, _} -> group(label) end, fn {_, delta} -> delta end)
      |> Enum.map(fn {group, list} ->
        %{group: group, processes: length(list), reductions: Enum.sum(list), share: share(Enum.sum(list), total)}
      end)
      |> Enum.sort_by(& &1.reductions, :desc)

    top =
      labelled
      |> Enum.sort_by(&elem(&1, 1), :desc)
      |> Enum.take(20)
      |> Enum.map(fn {label, delta} -> %{process: inspect(label), reductions: delta, share: share(delta, total)} end)

    %{window_ms: ms, scheduler_utilization: utilization, total_reductions: total, by_group: by_group, top: top}
  end

  @doc """
  Stack-sample one busy process: `samples` reads of its current stacktrace and
  mailbox depth over `ms`. Frames are aggregated two ways — the innermost
  application frame (what it is doing right now) and the full top-3 frame path
  (why) — so a hot handler shows up by name. Pass the process's registry key
  (`{instance_id, :player, player_id}`), or omit it to sample the process with
  the most reductions over a short pre-window.
  """
  def stacks(key \\ nil, ms \\ 5_000, samples \\ 250) do
    pid = if key, do: registry_pid(key), else: busiest_pid(500)

    case pid do
      nil ->
        %{error: "process not found"}

      pid ->
        interval = max(div(min(ms, @max_ms), max(samples, 1)), 1)

        reads =
          Enum.flat_map(1..samples, fn _ ->
            Process.sleep(interval)

            case Process.info(pid, [:current_stacktrace, :message_queue_len]) do
              [current_stacktrace: stack, message_queue_len: queue] -> [{app_frames(stack), queue}]
              _ -> []
            end
          end)

        count = length(reads)
        queues = Enum.map(reads, &elem(&1, 1))

        %{
          process: inspect(label(pid)),
          samples: count,
          mailbox: %{max: Enum.max(queues, fn -> 0 end), avg: if(count > 0, do: div(Enum.sum(queues), count), else: 0)},
          innermost: frequencies(reads, fn {frames, _} -> List.first(frames) || "idle" end, count),
          paths: frequencies(reads, fn {frames, _} -> frames |> Enum.take(3) |> Enum.join(" <- ") end, count)
        }
    end
  end

  defp registry_pid(key) do
    case Horde.Registry.lookup(Game.Registry, key) do
      [{pid, _} | _] -> pid
      _ -> nil
    end
  end

  defp busiest_pid(ms) do
    before = snapshot()
    Process.sleep(ms)

    snapshot()
    |> Enum.max_by(fn {pid, r} -> r - Map.get(before, pid, 0) end, fn -> {nil, 0} end)
    |> elem(0)
  end

  # Keep the frames that belong to the game, not the GenServer/stdlib plumbing.
  defp app_frames(stack) do
    stack
    |> Enum.map(fn {module, fun, arity, location} ->
      arity = if is_list(arity), do: length(arity), else: arity
      {module, "#{inspect(module)}.#{fun}/#{arity}:#{Keyword.get(location, :line, 0)}"}
    end)
    |> Enum.reject(fn {module, _} ->
      name = Atom.to_string(module)
      String.starts_with?(name, ["Elixir.GenServer", "Elixir.Enum", "Elixir.Map", "Elixir.List", "Elixir.Keyword"]) or
        not String.starts_with?(name, "Elixir.")
    end)
    |> Enum.map(&elem(&1, 1))
  end

  defp frequencies(reads, key_fun, count) do
    reads
    |> Enum.frequencies_by(key_fun)
    |> Enum.sort_by(&elem(&1, 1), :desc)
    |> Enum.take(12)
    |> Enum.map(fn {key, n} -> %{frame: key, share: share(n, count)} end)
  end

  defp snapshot do
    for pid <- Process.list(), {:reductions, r} <- [Process.info(pid, :reductions)], into: %{}, do: {pid, r}
  end

  # Instance agents register in Game.Registry as {instance_id, type, agent_id}.
  defp label(pid) do
    case safe_registry_keys(pid) do
      [key | _] ->
        key

      [] ->
        case Process.info(pid, [:registered_name, :dictionary]) do
          [registered_name: name, dictionary: _] when is_atom(name) and name != [] -> name
          [registered_name: _, dictionary: dict] -> Keyword.get(dict, :"$initial_call", :unknown)
          _ -> :exited
        end
    end
  end

  defp safe_registry_keys(pid) do
    Horde.Registry.keys(Game.Registry, pid)
  rescue
    _ -> []
  catch
    _, _ -> []
  end

  defp group({_instance_id, type, _agent_id}) when is_atom(type), do: type
  defp group({module, _fun, _arity}) when is_atom(module), do: module
  defp group(name) when is_atom(name), do: name
  defp group(other), do: inspect(other)

  # Busy fraction per scheduler over the window, when runtime_tools is present;
  # otherwise just wait out the window so the reduction deltas still line up.
  defp scheduler_utilization(ms) do
    case :scheduler.utilization(div(ms, 1000) |> max(1)) do
      [{:total, total, _} | _] -> Float.round(total * 100, 1)
      _ -> nil
    end
  rescue
    _ ->
      Process.sleep(ms)
      nil
  catch
    _, _ ->
      Process.sleep(ms)
      nil
  end

  defp share(_part, 0), do: 0.0
  defp share(part, total), do: Float.round(part * 100 / total, 1)
end
