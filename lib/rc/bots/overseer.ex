defmodule RC.Bots.Overseer do
  @moduledoc """
  Keeps bot DRIVERS alive for every running bot-opponent instance.

  Reconciles every #{div(30_000, 1000)}s (and once shortly after boot):
  for each instance with `bot_faction` set and state "running" whose
  supervision tree exists on this node, ensure one `Headless.Bot` process
  per bot registration — each running the Tunable policy with its
  personality genome (RC.Bots.personality_for/3, stable across restarts).
  Drivers for instances that stopped are shut down.

  Reconciliation (rather than supervision-tree membership) is deliberate:
  bot drivers are stateless outside their policy memory, instance restore
  order at boot doesn't matter (we just pick the bots up on a later pass),
  and a driver crash costs at most one 30s beat.
  """

  use GenServer

  import Ecto.Query

  alias RC.Instances.Instance
  alias RC.Instances.Registration
  alias RC.Repo

  require Logger

  @beat 30_000
  # Live decide cadence. At Fast speed a full game runs ~2h, so 10s between
  # decisions ≈ 700 decisions/game — the same order as headless training.
  @interval_ms 10_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    # bots: %{{instance_id, profile_id} => pid}
    Process.send_after(self(), :reconcile, 5_000)
    {:ok, %{bots: %{}}}
  end

  @impl true
  def handle_info(:reconcile, state) do
    state =
      try do
        reconcile(state)
      rescue
        e ->
          Logger.error("bots overseer: reconcile failed: #{Exception.message(e)}")
          state
      end

    Process.send_after(self(), :reconcile, @beat)
    {:noreply, state}
  end

  defp reconcile(state) do
    active =
      Repo.all(
        from(i in Instance,
          where: not is_nil(i.bot_faction) and i.state == "running",
          select: {i.id, i.bot_faction}
        )
      )
      # Elixir.-prefixed: `alias RC.Instances.Instance` above would otherwise
      # capture the bare `Instance.` prefix and resolve to a nonexistent
      # RC.Instances.Instance.Manager.
      |> Enum.filter(fn {id, _} -> Elixir.Instance.Manager.created?(id) end)

    wanted =
      Enum.flat_map(active, fn {instance_id, bot_faction} ->
        Repo.all(
          from(r in Registration,
            join: f in assoc(r, :faction),
            join: p in assoc(r, :profile),
            where: f.instance_id == ^instance_id and f.faction_ref == ^bot_faction and r.state == "playing",
            select: {p.id, f.faction_ref}
          )
        )
        |> Enum.map(fn {profile_id, faction_ref} -> {{instance_id, profile_id}, faction_ref} end)
      end)
      |> Map.new()

    # Stop drivers whose instance is no longer running (or bot resigned/died).
    bots =
      state.bots
      |> Enum.filter(fn {key, pid} ->
        cond do
          not Process.alive?(pid) -> false
          Map.has_key?(wanted, key) -> true
          true ->
            GenServer.stop(pid, :normal, 1_000)
            false
        end
      end)
      |> Map.new()

    # Start missing drivers with their (stable) personalities.
    bots =
      Enum.reduce(wanted, bots, fn {{instance_id, profile_id} = key, faction_ref}, acc ->
        if Map.has_key?(acc, key) do
          acc
        else
          personality = RC.Bots.personality_for(instance_id, faction_ref, profile_id)

          case Headless.Bot.start_link(
                 instance_id: instance_id,
                 player_id: profile_id,
                 policy: {Headless.Policies.Tunable, personality["genome"]},
                 interval_ms: @interval_ms
               ) do
            {:ok, pid} ->
              # start_link inside a GenServer links to the overseer; a bot
              # crash must not kill the reconciler (or its siblings).
              Process.unlink(pid)

              Logger.info(
                "bots overseer: started #{personality["name"]} for profile #{profile_id} " <>
                  "in instance #{instance_id} (#{faction_ref})"
              )

              Map.put(acc, key, pid)

            error ->
              Logger.error("bots overseer: failed to start bot #{inspect(key)}: #{inspect(error)}")
              acc
          end
        end
      end)

    %{state | bots: bots}
  end
end
