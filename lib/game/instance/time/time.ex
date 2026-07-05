defmodule Instance.Time.Time do
  use TypedStruct

  require Logger

  alias Instance.Time.Time
  alias Instance.Manager
  alias RC.InstanceSnapshots
  alias RC.Instances.InstanceSnapshot

  # Autosave threshold is expressed in game-time units (see Core.Tick.delta —
  # `elapsed_time = wall_ms * speed.factor / 180_000`). Per-speed values keep
  # cadence at ~15 wall-clock minutes regardless of speed:
  #   slow   factor=1   →  5
  #   medium factor=20  →  100
  #   fast   factor=120 →  600
  # Previously this only fired for :slow at threshold 20 (~60 min wall-clock),
  # leaving fast/flash games with no autosave history at all.
  @max_autosaves 10

  defp autosave_threshold(:slow), do: 5
  defp autosave_threshold(:medium), do: 100
  defp autosave_threshold(:fast), do: 600
  # Daily challenges are short, ephemeral sessions running at a fast factor
  # (240). Each autosave stops→snapshots→starts the instance, which surfaces as
  # a "Paused" flicker; at factor 240 the default threshold (5) would fire that
  # every ~3.75s. There's nothing worth recovering in a daily, so set the
  # threshold beyond any daily's lifetime — effectively no autosave.
  defp autosave_threshold(:daily), do: 1_000_000
  defp autosave_threshold(_), do: 5

  def jason(), do: [except: [:instance_id, :next_autosave]]

  typedstruct enforce: true do
    field(:is_running, boolean())
    field(:speed, atom())
    field(:now, %Core.DynamicValue{})
    field(:last_stop, integer() | nil)
    field(:cumulated_pauses, integer())
    field(:now_monotonic, integer() | nil)
    field(:next_autosave, %Core.DynamicValue{})
    field(:instance_id, integer())
  end

  def new(initial_date, day_factor, speed, instance_id) do
    now =
      Core.DynamicValue.new(initial_date)
      |> Core.DynamicValue.add(:misc, Core.ValuePart.new(:time, day_factor))

    %Instance.Time.Time{
      is_running: false,
      speed: speed,
      now: now,
      last_stop: nil,
      cumulated_pauses: 0,
      now_monotonic: nil,
      next_autosave: Core.DynamicValue.new(0, :misc, Core.ValuePart.new(:default, 1)),
      instance_id: instance_id
    }
  end

  def compute_next_tick_interval(_state) do
    5
  end

  def start(%Time{} = state) do
    %{state | is_running: true, cumulated_pauses: compute_cumulated_pauses(state)}
  end

  def stop(%Time{} = state) do
    %{state | is_running: false, last_stop: now()}
  end

  # Tick handling

  def next_tick(%Time{} = state, elapsed_time) do
    {MapSet.new(), state}
    |> update_now(elapsed_time)
    |> update_next_autosave(elapsed_time)
  end

  # Core functions

  defp update_now({change, state}, elapsed_time) do
    {change, %{state | now: Core.DynamicValue.next_tick(state.now, elapsed_time)}}
  end

  defp update_next_autosave({change, %{is_running: true} = state}, elapsed_time) do
    threshold = autosave_threshold(state.speed)
    next_autosave = Core.DynamicValue.next_tick(state.next_autosave, elapsed_time)

    next_autosave =
      cond do
        next_autosave.value < threshold ->
          next_autosave

        # Headless runs have no DB instance row: the autosave's
        # stop→snapshot→start cycle can only fail (and perturbs the sim while
        # failing). Reset the counter and move on.
        Instance.Mutators.headless?(state.instance_id) ->
          Core.DynamicValue.change_value(next_autosave, 0.0)

        true ->
        # Stage 7 F25 + autosave fail-open. Supervised under
        # RC.TaskSupervisor so an autosave failure is observable, and
        # wrapped in a fail-open block: if the snapshot or start step
        # dies, we still issue a Manager.call(:start) so the instance
        # is not left stuck in :stopped from an interrupted autosave.
        instance_id = state.instance_id

        Task.Supervisor.start_child(
          RC.TaskSupervisor,
          fn ->
            try do
              with {:ok, :stopped, _} <- Manager.call(instance_id, :stop, 180_000),
                   {:ok, _snapshot} <- Manager.call(instance_id, :make_snapshot, 300_000),
                   {:ok, :started, _} <- Manager.call(instance_id, :start, 180_000) do
                # only keep @max_autosaves most recent snapshots
                InstanceSnapshots.list(instance_id)
                |> Enum.drop(@max_autosaves)
                |> Enum.each(fn snapshot ->
                  with :ok <- Util.Storage.delete(snapshot.name),
                       {:ok, %InstanceSnapshot{}} <- InstanceSnapshots.delete(snapshot) do
                    nil
                  else
                    _ -> Logger.error("Error during autosave cleaning")
                  end
                end)
              else
                {:error, err} ->
                  Logger.error("Error during autosave '#{inspect(err)}'")
                  # fail-open: ensure instance is restarted even if
                  # snapshot or start failed mid-flight
                  Manager.call(instance_id, :start, 180_000)

                other ->
                  Logger.error("Unexpected autosave result: #{inspect(other)}")
                  Manager.call(instance_id, :start, 180_000)
              end
            rescue
              e ->
                Logger.error("Autosave crashed: #{Exception.message(e)}",
                  instance_id: instance_id,
                  stacktrace: Exception.format_stacktrace(__STACKTRACE__)
                )

                # fail-open: best-effort restart of the instance
                try do
                  Manager.call(instance_id, :start, 180_000)
                rescue
                  _ -> :ok
                catch
                  _, _ -> :ok
                end
            catch
              kind, reason ->
                Logger.error("Autosave exited #{kind}: #{inspect(reason)}", instance_id: instance_id)

                try do
                  Manager.call(instance_id, :start, 180_000)
                rescue
                  _ -> :ok
                catch
                  _, _ -> :ok
                end
            end
          end,
          restart: :temporary
        )

        Core.DynamicValue.change_value(next_autosave, 0.0)
      end

    {change, %{state | next_autosave: next_autosave}}
  end

  defp update_next_autosave({change, state}, _elapsed_time) do
    {change, state}
  end

  # Helper functions

  def compute_cumulated_pauses(%Time{last_stop: nil} = _state), do: 0
  def compute_cumulated_pauses(%Time{} = state), do: state.cumulated_pauses + (Time.now() - state.last_stop)

  def now(cumulated_pauses), do: System.monotonic_time(:millisecond) - cumulated_pauses
  def now(), do: System.monotonic_time(:millisecond)
end
