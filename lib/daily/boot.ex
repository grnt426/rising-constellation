defmodule Daily.Boot do
  @moduledoc """
  MVP live boot for a daily challenge.

  Builds an in-memory instance — the same shape the tutorial uses
  (`Portal.GameController.tutorial_data/2`), so no scenario/instance DB rows
  are needed — from a generated `Daily` definition and a reusable demo
  profile, then stands up the live supervision tree with
  `Instance.Manager.create_from_model/2` followed by `:start`. The economy
  begins ticking immediately at the daily's fast clock.

  This is a developer / MVP trigger, reached via the harness-secret endpoint
  `POST /api/harness/daily/start`. The real per-player flow — persisted
  instance + registration, lobby hiding, leaderboard — is a later milestone
  (see docs/daily-challenge.md).

  Player stats are intentionally not persisted here: the in-memory instance /
  registration ids aren't real rows, so the periodic `PlayerStat` insert fails
  its FK constraint and is discarded (the player agent ignores the result).
  Fine for the MVP — the economy still ticks. The moment we move to real
  per-player instances, stats persist for free.
  """

  require Logger

  alias RC.Accounts
  alias RC.Accounts.Profile

  @demo_email "daily-demo@tetrarchyfalls.local"
  @demo_name "DailyDemo"

  @doc "Boot today's daily (UTC). Returns `{:ok, summary}` | `{:error, reason}`."
  def boot_today, do: boot_for(Date.utc_today())

  @doc "Boot the daily for `date` (a `Date` or ISO-8601 string)."
  def boot_for(date) do
    definition = Daily.definition_for(date)
    profile = ensure_demo_profile()
    instance_id = gen_instance_id()
    instance = in_memory_instance(instance_id, definition.game_data, profile)

    with {:ok, :instantiated} <- Instance.Manager.create_from_model(instance, nil),
         {:ok, :started, _} <- Instance.Manager.call(instance_id, :start) do
      Logger.info("[daily] booted instance #{instance_id} for #{definition.date}")

      {:ok,
       %{
         instance_id: instance_id,
         player_id: profile.id,
         date: definition.date,
         objective: definition.objective,
         mutators: definition.mutators
       }}
    else
      error ->
        Logger.error("[daily] boot failed: #{inspect(error)}")
        {:error, error}
    end
  end

  @doc """
  Read a live daily instance's current economy state — for confirming it's
  ticking. Returns a plain (JSON-encodable) map; missing/unreachable agents
  come back as nil rather than raising.
  """
  def status(instance_id, player_id) do
    time = call(instance_id, :time, :master, :get_state)
    player = call(instance_id, :player, player_id, :get_state)
    galaxy = call(instance_id, :galaxy, :master, :get_state)

    %{
      instance_id: instance_id,
      running: match?(%{is_running: true}, time),
      date: time && (Map.get(time, :current_date) || Map.get(time, :date)),
      player: player_summary(player),
      systems: galaxy && Enum.map(galaxy.stellar_systems, &system_summary(instance_id, &1))
    }
  end

  # --- internals -----------------------------------------------------------

  defp gen_instance_id, do: :os.system_time(:second) * 1000 + :rand.uniform(999)

  defp in_memory_instance(instance_id, game_data, profile) do
    %{
      id: instance_id,
      factions: [
        %{
          id: 1,
          capacity: 1,
          faction_ref: "tetrarchy",
          registrations: [%{id: 1, profile: profile}]
        }
      ],
      game_data: game_data
    }
  end

  # Idempotent: one shared demo account+profile, reused across boots.
  defp ensure_demo_profile do
    account =
      case Accounts.get_account_by_email(@demo_email) do
        {:ok, account} ->
          account

        {:error, _} ->
          {:ok, account} =
            Accounts.create_account(%{
              email: @demo_email,
              password: random_password(),
              name: @demo_name,
              role: :user,
              status: :active
            })

          account
      end

    case RC.Repo.get_by(Profile, account_id: account.id) do
      nil ->
        {:ok, profile} =
          Accounts.create_profile(%{account_id: account.id, name: @demo_name, avatar: "todo"})

        profile

      profile ->
        profile
    end
  end

  defp random_password, do: "daily-" <> Base.url_encode64(:crypto.strong_rand_bytes(12))

  defp call(instance_id, type, id, action) do
    case Game.call(instance_id, type, id, action, 3, 2_000) do
      {:ok, state} -> state
      _ -> nil
    end
  end

  defp player_summary(nil), do: nil

  defp player_summary(p) do
    %{
      name: p.name,
      owned_systems: length(p.stellar_systems),
      credit: dynamic_value(p.credit),
      technology: dynamic_value(p.technology),
      ideology: dynamic_value(p.ideology)
    }
  end

  # The galaxy holds a lightweight system summary (no economy/bodies); the
  # per-system agent holds production and the bodies (with their factors/tiles
  # — i.e. what the world-gen mutators changed). Read both and merge.
  defp system_summary(instance_id, gs) do
    full = call(instance_id, :stellar_system, gs.id, :get_state)

    %{
      name: gs.name,
      type: gs.type,
      status: gs.status,
      owner: gs.owner,
      population: round1(gs.population),
      production: full && value(full.production),
      credit: full && value(full.credit),
      technology: full && value(full.technology),
      ideology: full && value(full.ideology),
      bodies: full && Enum.map(full.bodies, &body_summary/1)
    }
  end

  defp body_summary(b) do
    %{
      type: b.type,
      factors: "#{b.industrial_factor}/#{b.technological_factor}/#{b.activity_factor}",
      tiles: length(b.tiles),
      moons: length(b.bodies)
    }
  end

  defp dynamic_value(%Core.DynamicValue{value: v, change: c}),
    do: %{value: round1(v), per_day: round1(c)}

  defp dynamic_value(_), do: nil

  defp value(%Core.Value{value: v}), do: round1(v)
  defp value(_), do: nil

  defp round1(n) when is_number(n), do: Float.round(n / 1, 1)
  defp round1(_), do: nil
end
