defmodule Portal.Controllers.CheatChannel do
  @moduledoc """
  Out-of-band channel that short-circuits normal game economics.

  Two authorized caller classes, each re-asserted by every handler so a
  config slip can't accidentally expose cheats to real players:

    * stress-test bots (`account.is_bot`) — the original consumer, allowed
      on any instance;
    * the game creator (`instances.account_id`) — but only on an instance
      created with cheat access (`Instance.Cheats.enabled?/1`). This powers
      the in-game Cheats tab used to test faction governments, game modes,
      and "game DM" scenarios. Cheat-enabled games announce themselves in
      every faction's chat at genesis.

  Topic format: `cheat:player:{instance_id}:{player_id}`. Caller must
  already be authorised to act AS that player — same registration check the
  normal PlayerChannel does.
  """

  use Phoenix.Channel
  use Portal.ReplayRecorder

  require Logger

  # Runtime speed multipliers the set_speed cheat accepts (× the instance's
  # base speed factor). Whitelisted so a typo can't retime an instance to
  # something absurd.
  @allowed_speed_multipliers [0.25, 0.5, 1, 2, 5, 10, 20, 50]

  @resources ["credit", "technology", "ideology"]

  # Hard cap per grant — enough for any test scenario, small enough that a
  # slipped extra zero doesn't overflow client-side number formatting.
  @max_grant 1_000_000_000

  def join("cheat:player:" <> channel_data, _params, socket) do
    [instance_id, player_id] =
      channel_data
      |> String.split(":")
      |> Enum.map(&String.to_integer/1)

    cond do
      not Instance.Manager.created?(instance_id) ->
        {:error, %{reason: "instance_not_instantiated"}}

      not cheat_access?(socket, instance_id) ->
        {:error, %{reason: "cheat_access_denied"}}

      not own_player?(socket, instance_id, player_id) ->
        {:error, %{reason: "not_authorised_for_player"}}

      true ->
        socket =
          socket
          |> assign(:instance_id, instance_id)
          |> assign(:player_id, player_id)
          |> assign(:channel_name, "cheat")
          # `has_replay` gates Portal.ReplayRecorder's per-action replay
          # persistence. Cheats are out-of-band stress-test/debug glue; we
          # don't want them mixed into game replays. Bot monitoring still
          # fires — it has its own gate (account.is_bot).
          |> assign(:has_replay, false)

        {:ok, socket}
    end
  end

  # Original bot cheat: grant resources to the topic's own player.
  record("grant_resources", payload, socket) do
    with :ok <- assert_cheat_access(socket) do
      amounts = %{
        credit: Map.get(payload, "credit", 0),
        technology: Map.get(payload, "technology", 0),
        ideology: Map.get(payload, "ideology", 0)
      }

      case Game.call(iid(socket), :player, pid(socket), {:cheat, :grant_resources, amounts}) do
        {:error, reason} -> {:error, %{reason: reason}}
        _ -> :ok
      end
    else
      {:error, reason} -> {:error, %{reason: reason}}
    end
  end

  # Cheats tab: give one resource to one player, or to every player in the
  # instance ("target": "all").
  record("give_resources", %{"target" => target, "resource" => resource, "amount" => amount}, socket) do
    with :ok <- assert_cheat_access(socket),
         :ok <- assert_cheats_enabled(socket),
         true <- resource in @resources or {:error, "unknown_resource"},
         true <- (is_number(amount) and amount > 0 and amount <= @max_grant) or {:error, "invalid_amount"},
         {:ok, player_ids} <- resolve_targets(socket, target) do
      {credit, technology, ideology} =
        case resource do
          "credit" -> {amount, 0, 0}
          "technology" -> {0, amount, 0}
          "ideology" -> {0, 0, amount}
        end

      results =
        Enum.map(player_ids, fn player_id ->
          Game.call(iid(socket), :player, player_id, {:add_resources, credit, technology, ideology})
        end)

      granted = Enum.count(results, &(&1 == :ok))
      {:ok, %{granted: granted, targets: length(player_ids)}}
    else
      {:error, reason} -> {:error, %{reason: reason}}
    end
  end

  # Cheats tab: instantly settle a system for the target player. Refused
  # when a player already owns the system — a forced transfer would run the
  # loser through {:lose_system, _}, and losing a last system kills that
  # player. Settling is for neutral/uninhabited/uninhabitable systems.
  record("settle_system", %{"target" => target, "system_id" => system_id}, socket) do
    with :ok <- assert_cheat_access(socket),
         :ok <- assert_cheats_enabled(socket),
         true <- (is_integer(target) and is_integer(system_id)) or {:error, "invalid_payload"},
         {:ok, player_ids} <- resolve_targets(socket, "all"),
         true <- target in player_ids or {:error, "unknown_player"},
         {:ok, system} <- Game.call(iid(socket), :stellar_system, system_id, :get_state),
         true <- is_nil(system.owner) or {:error, "system_already_owned"} do
      case Game.call(iid(socket), :player, target, {:cheat_claim_system, system_id}) do
        :ok -> {:ok, %{settled: system_id, player: target}}
        {:error, reason} -> {:error, %{reason: reason}}
      end
    else
      {:error, reason} -> {:error, %{reason: reason}}
      :process_not_found -> {:error, %{reason: "system_not_found"}}
    end
  end

  # Cheats tab: end the pre-election founding grace period, every faction.
  record("skip_election_timer", %{}, socket) do
    gov_cheat_fanout(socket, :cheat_gov_skip_founding)
  end

  # Cheats tab: conclude every currently-open election round, every faction.
  record("conclude_elections", %{}, socket) do
    gov_cheat_fanout(socket, :cheat_gov_conclude_elections)
  end

  # Cheats tab: clear lex-locking cooldowns for everyone — the per-faction
  # law-change cooldown and every player's policy re-lock cooldown.
  record("clear_lex_cooldowns", %{}, socket) do
    with :ok <- assert_cheat_access(socket),
         :ok <- assert_cheats_enabled(socket),
         {:ok, player_ids} <- resolve_targets(socket, "all") do
      faction_results =
        Enum.map(faction_ids(socket), fn faction_id ->
          Game.call(iid(socket), :faction, faction_id, :cheat_gov_clear_law_cooldown)
        end)

      player_results =
        Enum.map(player_ids, fn player_id ->
          Game.call(iid(socket), :player, player_id, :cheat_clear_policies_cooldown)
        end)

      {:ok,
       %{
         factions_cleared: Enum.count(faction_results, &(&1 == :ok)),
         players_cleared: Enum.count(player_results, &(&1 == :ok))
       }}
    else
      {:error, reason} -> {:error, %{reason: reason}}
    end
  end

  # Cheats tab: retime the running instance (multiplier × base speed).
  record("set_speed", %{"multiplier" => multiplier}, socket) do
    with :ok <- assert_cheat_access(socket),
         :ok <- assert_cheats_enabled(socket),
         true <- multiplier in @allowed_speed_multipliers or {:error, "invalid_multiplier"} do
      case Instance.Manager.call(iid(socket), {:cheat_set_speedup, multiplier}) do
        {:ok, :speedup_set, _count} -> {:ok, %{speedup: multiplier}}
        {:error, reason} -> {:error, %{reason: reason}}
      end
    else
      {:error, reason} -> {:error, %{reason: reason}}
    end
  end

  # ---- authorization ---------------------------------------------------

  defp cheat_access?(socket, instance_id) do
    is_bot?(socket) or creator_with_cheats?(socket, instance_id)
  end

  defp creator_with_cheats?(socket, instance_id) do
    Instance.Cheats.enabled?(instance_id) and
      RC.Instances.own_instance?(socket.assigns.account.id, instance_id)
  end

  defp assert_cheat_access(socket) do
    if cheat_access?(socket, iid(socket)), do: :ok, else: {:error, "cheat_access_denied"}
  end

  # The creator-facing ops (unlike the bot-only grant_resources) must never
  # run on a non-cheat instance, even for bots.
  defp assert_cheats_enabled(socket) do
    if Instance.Cheats.enabled?(iid(socket)), do: :ok, else: {:error, "cheats_disabled"}
  end

  defp is_bot?(socket) do
    case socket.assigns do
      %{account: %{is_bot: true}} -> true
      _ -> false
    end
  end

  defp own_player?(socket, instance_id, player_id) do
    RC.Registrations.account_owns_player?(socket.assigns.account.id, instance_id, player_id)
  end

  # ---- helpers ---------------------------------------------------------

  defp gov_cheat_fanout(socket, op) do
    with :ok <- assert_cheat_access(socket),
         :ok <- assert_cheats_enabled(socket) do
      results = Enum.map(faction_ids(socket), fn faction_id -> Game.call(iid(socket), :faction, faction_id, op) end)
      applied = Enum.count(results, &(&1 == :ok))

      # :ok on at least one faction is success; per-faction "nothing to do"
      # errors (:not_in_founding, :no_open_elections, :government_disabled)
      # only surface when NO faction applied, as a single aggregate reason.
      if applied > 0 do
        {:ok, %{factions_applied: applied}}
      else
        reason =
          results
          |> Enum.find_value(fn
            {:error, reason} -> reason
            _ -> nil
          end)
          |> Kernel.||("no_faction_applied")

        {:error, %{reason: reason}}
      end
    else
      {:error, reason} -> {:error, %{reason: reason}}
    end
  end

  defp resolve_targets(socket, "all") do
    case Game.call(iid(socket), :galaxy, :master, :get_state) do
      {:ok, galaxy} -> {:ok, Map.keys(galaxy.players)}
      _ -> {:error, "instance_unavailable"}
    end
  end

  defp resolve_targets(socket, player_id) when is_integer(player_id) do
    case Game.call(iid(socket), :galaxy, :master, :get_state) do
      {:ok, galaxy} ->
        if Map.has_key?(galaxy.players, player_id),
          do: {:ok, [player_id]},
          else: {:error, "unknown_player"}

      _ ->
        {:error, "instance_unavailable"}
    end
  end

  defp resolve_targets(_socket, _target), do: {:error, "invalid_target"}

  defp faction_ids(socket) do
    case RC.Instances.get_instance(iid(socket)) do
      %{factions: factions} when is_list(factions) -> Enum.map(factions, & &1.id)
      _ -> []
    end
  end

  defp iid(socket), do: socket.assigns.instance_id
  defp pid(socket), do: socket.assigns.player_id
end
