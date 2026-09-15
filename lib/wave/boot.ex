defmodule Wave.Boot do
  @moduledoc """
  Stand up a Wave Defense instance.

  Mirrors the persisted daily/dev-fixture recipe — real scenario, instance,
  faction and registration rows, then the live supervision tree — with the
  wave-specific parts:

    * the map is forced to Legacy speed and `game_mode_type: "wave"`;
    * one of the scenario's faction start sectors is handed to the Rebellion
      and every other non-human faction's sectors become unowned, so the galaxy
      has exactly one human start and one rebel start;
    * the Rebellion faction row gets capacity 1 and is filled by a dedicated
      bot profile before humans can reach the lobby;
    * faction government is forced off (the Rebellion has no election system);
    * the instance is public and late-registration, so humans join a running
      game from the normal lobby.

  The MVP entry point is `start/1`, reached through the dev harness endpoint
  `POST /api/harness/wave/start` (see `Portal.WaveController`).
  """

  require Logger

  alias RC.Accounts
  alias RC.Accounts.Profile

  @rebellion_email "wave-rebellion@tetrarchyfalls.local"
  @rebellion_name "The Rebellion"
  @fixture_game_data "test/support/scenario_game_data.json"
  @fixture_game_metadata "test/support/scenario_game_metadata.json"
  # Legacy default match length, in real minutes (30 days).
  @legacy_time_limit 43_200

  @doc """
  Create, publish, register and start a wave instance.

  Options (all optional):

    * `:owner_email` — account that owns the instance (default `user1@abc`, the seeded dev admin)
    * `:human_email` — also register this account's profile in the human faction
    * `:human_faction` — faction key humans play (default: the first faction in the scenario)
    * `:scenario_id` — a Forge scenario to use instead of the bundled two-sector test map
    * `:knobs` — map merged over `Wave.defaults/0` (e.g. `%{"hire_interval_ut" => 5}`)

  Returns `{:ok, summary}` or `{:error, reason}`.
  """
  def start(opts \\ []) do
    # Everything that can fail on bad input is resolved BEFORE the first row is
    # written, so a rejected request never leaves a half-built instance behind.
    with {:ok, owner} <- fetch_account(Keyword.get(opts, :owner_email, "user1@abc")),
         {:ok, human} <- resolve_human(Keyword.get(opts, :human_email)),
         {:ok, {game_data, game_metadata}} <- load_scenario(opts),
         {:ok, human_faction} <- pick_human_faction(game_data, Keyword.get(opts, :human_faction)),
         {:ok, game_data} <- prepare_game_data(game_data, human_faction, Keyword.get(opts, :knobs, %{})),
         game_data = put_win_target(game_data, Keyword.get(opts, :win_points_target)),
         {:ok, scenario} <- insert_scenario(game_data, game_metadata),
         {:ok, instance} <- create_instance(scenario, owner, human_faction),
         {:ok, _} <- RC.Instances.publish_instance(instance, owner.id),
         {:ok, rebel_profile} <- register_rebellion(instance),
         {:ok, human_profile} <- register_human(instance, human_faction, human),
         loaded = RC.Instances.get_instance_with_registration(instance.id),
         {:ok, :instantiated} <- Instance.Manager.create_from_model(loaded, nil),
         {:ok, _} <- RC.Instances.start_instance(loaded, owner.id),
         {:ok, :started, _} <- Instance.Manager.call(instance.id, :start) do
      Logger.info("[wave] started instance #{instance.id} (humans: #{human_faction}, bot profile #{rebel_profile.id})")

      {:ok,
       %{
         instance_id: instance.id,
         human_faction: human_faction,
         bot_faction: "rebellion",
         rebellion_profile_id: rebel_profile.id,
         human_profile_id: human_profile && human_profile.id
       }}
    else
      {:error, reason} ->
        Logger.error("[wave] boot failed: #{inspect(reason)}")
        {:error, reason}

      other ->
        Logger.error("[wave] boot failed: #{inspect(other)}")
        {:error, other}
    end
  end

  @doc """
  Rewrite a scenario's `game_data` for wave play. Pure — exposed for tests.

  The Rebellion takes the rival start sector farthest from the human start
  sectors (by sector centroid), so the two sides begin on opposite sides of the
  galaxy. Every other non-human sector becomes unowned.
  """
  def prepare_game_data(game_data, human_faction, knobs \\ %{}) do
    sectors = game_data["sectors"] || []
    human_sectors = Enum.filter(sectors, &(&1["faction"] == human_faction))

    rebel_source =
      sectors
      |> Enum.filter(&(&1["faction"] not in [nil, human_faction]))
      |> Enum.max_by(&distance_to_nearest(&1, human_sectors), fn -> nil end)

    cond do
      human_sectors == [] ->
        {:error, {:no_sector_for_human_faction, human_faction}}

      rebel_source == nil ->
        {:error, :no_sector_for_rebellion}

      true ->
        rebel_key = rebel_source["key"]

        sectors =
          Enum.map(sectors, fn sector ->
            cond do
              sector["key"] == rebel_key -> Map.put(sector, "faction", "rebellion")
              sector["faction"] in [nil, human_faction] -> sector
              true -> Map.put(sector, "faction", nil)
            end
          end)

        factions = [
          %{"key" => human_faction, "sector_number" => length(human_sectors)},
          %{"key" => "rebellion", "sector_number" => 1}
        ]

        wave =
          Wave.defaults()
          |> Map.merge(stringify_keys(knobs))
          |> Map.merge(%{"bot_faction" => "rebellion", "human_faction" => human_faction})

        {:ok,
         game_data
         |> Map.put("sectors", sectors)
         |> Map.put("factions", factions)
         |> Map.put("speed", "slow")
         |> Map.put("time_limit", @legacy_time_limit)
         |> Map.put("game_mode_type", Wave.mode_type())
         |> Map.put("wave", wave)}
    end
  end

  @doc "The shared Rebellion bot profile (created on first use, flagged `is_bot`)."
  def rebellion_profile do
    account =
      case Accounts.get_account_by_email(@rebellion_email) do
        {:ok, account} ->
          account

        {:error, _} ->
          {:ok, account} =
            Accounts.create_account(%{
              email: @rebellion_email,
              password: "wave-" <> Base.url_encode64(:crypto.strong_rand_bytes(12)),
              name: @rebellion_name,
              role: :user,
              status: :active
            })

          account
      end

    account = mark_bot(account)

    profile =
      case RC.Repo.get_by(Profile, account_id: account.id) do
        nil ->
          {:ok, profile} = Accounts.create_profile(%{account_id: account.id, name: @rebellion_name, avatar: "bot"})
          profile

        profile ->
          profile
      end

    mark_bot(profile)
  end

  # --- steps -----------------------------------------------------------------

  defp fetch_account(email) do
    case Accounts.get_account_by_email(email) do
      {:ok, account} -> {:ok, account}
      _ -> {:error, {:unknown_account, email}}
    end
  end

  # Scenario source, in priority order: inline game_data (e.g. a scenario copied
  # from production), a local scenario row, or the bundled two-sector test map.
  defp load_scenario(opts) do
    cond do
      is_map(opts[:game_data]) ->
        {:ok, {opts[:game_data], opts[:game_metadata] || %{}}}

      opts[:scenario_id] != nil ->
        case RC.Scenarios.get_scenario(opts[:scenario_id]) do
          nil -> {:error, {:unknown_scenario, opts[:scenario_id]}}
          scenario -> {:ok, {scenario.game_data, scenario.game_metadata || %{}}}
        end

      true ->
        game_data = @fixture_game_data |> File.read!() |> Jason.decode!()
        game_metadata = @fixture_game_metadata |> File.read!() |> Jason.decode!()
        {:ok, {game_data, game_metadata}}
    end
  end

  # Victory-point target override. A test run that should play on after the
  # Rebellion dominates the map needs a target it can't reach, or the engine
  # declares a winner and tears the instance down.
  defp put_win_target(game_data, target) when is_integer(target) and target > 0,
    do: Map.put(game_data, "win_points_target", target)

  defp put_win_target(game_data, _target), do: game_data

  # Distance from a sector's centroid to the nearest human start sector.
  defp distance_to_nearest(_sector, []), do: 0

  defp distance_to_nearest(sector, human_sectors) do
    human_sectors
    |> Enum.map(&centroid_distance(sector, &1))
    |> Enum.min()
  end

  defp centroid_distance(%{"centroid" => [ax, ay]}, %{"centroid" => [bx, by]})
       when is_number(ax) and is_number(ay) and is_number(bx) and is_number(by),
       do: :math.sqrt((ax - bx) * (ax - bx) + (ay - by) * (ay - by))

  defp centroid_distance(_a, _b), do: 0

  defp pick_human_faction(game_data, nil) do
    case Enum.find(game_data["sectors"] || [], &(&1["faction"] != nil)) do
      nil -> {:error, :scenario_has_no_faction_sectors}
      sector -> {:ok, sector["faction"]}
    end
  end

  defp pick_human_faction(_game_data, "rebellion"), do: {:error, :rebellion_is_not_playable}
  defp pick_human_faction(_game_data, faction) when is_binary(faction), do: {:ok, faction}

  defp insert_scenario(game_data, game_metadata) do
    %RC.Scenarios.Scenario{}
    |> RC.Scenarios.Scenario.changeset(%{
      game_data: game_data,
      game_metadata: Map.merge(game_metadata, %{"speed" => "slow"}),
      is_map: false
    })
    |> RC.Repo.insert()
  end

  defp create_instance(scenario, owner, human_faction) do
    stamp = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_string()

    attrs = %{
      "name" => "Wave Defense — #{stamp}",
      "description" => "Wave Defense MVP: humans (#{human_faction}) vs the Rebellion.",
      "opening_date" => DateTime.to_iso8601(DateTime.utc_now()),
      "registration_type" => "late_registration",
      "game_type" => "public",
      "public" => true,
      "start_setting" => "manual",
      "game_mode_type" => Wave.mode_type(),
      # The Rebellion has no government rules; an absent key would grandfather
      # government ON at Legacy speed.
      "faction_gov_enabled" => false,
      # Lets the creator use the speed cheat to fast-forward a Legacy test game.
      "cheats_enabled" => true,
      "factions" => [
        %{"key" => human_faction, "capacity" => 20},
        %{"key" => "rebellion", "capacity" => 1}
      ]
    }

    case RC.Instances.create_instance(attrs, scenario, owner.id) do
      {:ok, %{instance: instance}} -> {:ok, instance}
      {:error, step, reason, _} -> {:error, {step, reason}}
      other -> {:error, other}
    end
  end

  defp register_rebellion(instance) do
    profile = rebellion_profile()
    faction = Enum.find(instance.factions, &(&1.faction_ref == "rebellion"))

    case RC.Registrations.register_profile(faction, profile) do
      {:ok, _} -> {:ok, profile}
      {:error, step, reason, _} -> {:error, {:register_rebellion, step, reason}}
      other -> {:error, {:register_rebellion, other}}
    end
  end

  # The human to pre-register, with a profile guaranteed. Seeded dev accounts
  # have no profile on a fresh database, so one is created on first use.
  defp resolve_human(nil), do: {:ok, nil}

  defp resolve_human(email) do
    with {:ok, account} <- fetch_account(email) do
      case RC.Repo.get_by(Profile, account_id: account.id) do
        %Profile{} = profile ->
          {:ok, profile}

        nil ->
          case Accounts.create_profile(%{account_id: account.id, name: account.name, avatar: "todo"}) do
            {:ok, profile} -> {:ok, profile}
            {:error, changeset} -> {:error, {:profile_create_failed, email, inspect(changeset.errors)}}
          end
      end
    end
  end

  defp register_human(_instance, _faction, nil), do: {:ok, nil}

  defp register_human(instance, human_faction, %Profile{} = profile) do
    faction = Enum.find(instance.factions, &(&1.faction_ref == human_faction))

    case RC.Registrations.register_profile(faction, profile) do
      {:ok, _} -> {:ok, profile}
      {:error, step, reason, _} -> {:error, {:register_human, step, reason}}
      other -> {:error, {:register_human, other}}
    end
  end

  # is_bot is admin-changeset-only by design; set it directly so the Rebellion
  # is excluded from rankings and profile search like other bot accounts.
  defp mark_bot(%{is_bot: true} = record), do: record

  defp mark_bot(record) do
    case record |> Ecto.Changeset.change(is_bot: true) |> RC.Repo.update() do
      {:ok, updated} -> updated
      _ -> record
    end
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {to_string(k), v}
    end)
  end

  defp stringify_keys(_), do: %{}
end
