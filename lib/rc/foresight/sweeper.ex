defmodule RC.Foresight.Sweeper do
  @moduledoc """
  Safety-net settlement sweep for Foresight (docs/foresight.md).

  The fast path is the inline hook in `Instance.Victory.Agent` — this
  GenServer catches everything that path can miss: a node restart between
  victory and settlement, and every winner-less ending (admin Finish,
  LiveView force_end, bot-only retirement, instance deletion).

  Every tick, for each instance that still has active predictions:

    * a `victories` row exists but no settlement → `settle/2`
    * the `instances` row is gone → void (`void_instance_deleted`)
    * state is `ended`/`maintenance` with no `victories` row → void
      (`void_no_winner`)

  Everything else (open, running, paused, not_running) is left alone —
  a crashed `not_running` instance can be resumed, and its predictions
  stay live until it either concludes or is retired.

  The `foresight_settlements` unique index makes racing the inline hook
  harmless. Failures are logged, never raised.
  """

  use GenServer

  import Ecto.Query, warn: false

  require Logger

  alias RC.Foresight
  alias RC.Foresight.Prediction
  alias RC.Instances.Instance
  alias RC.Instances.Victory
  alias RC.Repo

  @tick_ms 60_000
  # Let boot-time DB activity (instance resurrection etc.) settle first.
  @initial_delay_ms 45_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Operator/debug helper: run one sweep now."
  def run_now, do: GenServer.cast(__MODULE__, :sweep)

  @impl true
  def init(opts) do
    if Application.get_env(:rc, :environment) == :test do
      :ignore
    else
      schedule(Keyword.get(opts, :initial_delay_ms, @initial_delay_ms))
      {:ok, %{tick_ms: Keyword.get(opts, :tick_ms, @tick_ms)}}
    end
  end

  @impl true
  def handle_cast(:sweep, state) do
    safe_sweep()
    {:noreply, state}
  end

  @impl true
  def handle_info(:sweep, state) do
    safe_sweep()
    schedule(state.tick_ms)
    {:noreply, state}
  end

  defp safe_sweep do
    sweep()
  rescue
    error -> Logger.warning("[foresight] sweep failed: #{Exception.message(error)}")
  end

  @doc false
  def sweep do
    from(p in Prediction,
      where: p.status == "active",
      distinct: true,
      select: p.instance_id
    )
    |> Repo.all()
    |> Enum.each(&sweep_instance/1)
  end

  defp sweep_instance(instance_id) do
    decided = Repo.exists?(from(v in Victory, where: v.instance_id == ^instance_id))

    state =
      from(i in Instance, where: i.id == ^instance_id, select: i.state)
      |> Repo.one()

    result =
      cond do
        decided -> Foresight.settle(instance_id)
        is_nil(state) -> Foresight.void(instance_id, "void_instance_deleted")
        state in ["ended", "maintenance"] -> Foresight.void(instance_id, "void_no_winner")
        true -> :pending
      end

    case result do
      {:ok, plan} -> Logger.info("[foresight] swept instance #{instance_id}: #{plan.outcome}")
      {:error, reason} -> Logger.warning("[foresight] sweep of instance #{instance_id} failed: #{inspect(reason)}")
      _noop_or_pending -> :ok
    end
  end

  defp schedule(ms), do: Process.send_after(self(), :sweep, ms)
end
