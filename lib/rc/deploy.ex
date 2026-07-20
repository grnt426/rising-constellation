defmodule RC.Deploy do
  @moduledoc """
  Deployment-notice flag: player-facing "a deploy is happening" signal.

  Storage follows the `RC.Maintenance` / `RC.BotControl` dual-storage
  idiom: `Portal.Config` is the fast in-memory cache, the append-only
  `deploy_log` table is the durable truth (the flag must survive the
  mid-deploy app restart), and every change is broadcast on the public
  `portal:user:*` topic so connected clients react live. Clients that
  connect later pick the flag up from the `portal:user:*` join reply
  (see `Portal.Controllers.PortalChannel`).

  The deploy script drives this over ssh + `rc rpc`:

    * `start_deploy/1`  — preflight, before the build: raises the flag
      and announces the upcoming interruption in every live game's chat.
    * `finish_deploy/1` — after a verified deploy: clears the flag and
      announces that an update was applied.
    * `clear_deploy/1`  — aborted/failed deploy (or Discord
      `/cleardeploy`): clears the flag with no announcement.

  All three are zero-arity-callable from `rc rpc` (the `source` argument
  defaults to `"script"`) so the remote command needs no nested quoting.
  """

  import Ecto.Query, warn: false

  require Logger

  alias Portal.Config
  alias Portal.Controllers.PortalChannel
  alias RC.Repo

  @ongoing_message "Server deployment is on-going. Expect momentary service interruption within the next 10 minutes."
  @finished_message "An update has been applied, a client refresh is recommended."

  def ongoing_message, do: @ongoing_message
  def finished_message, do: @finished_message

  @doc """
  Raise the deploy notice: flag up + SYSTEM chat line in every faction of
  every live instance. Idempotent — re-running re-broadcasts the flag but
  the chat line is only inserted once per faction ring.
  """
  def start_deploy(source \\ "script") do
    set_flag(true, source)
    broadcast_system_chat(@ongoing_message, :once)
    :ok
  end

  @doc """
  Deploy verified complete: flag down + "update applied" SYSTEM chat line
  in every faction of every live instance.
  """
  def finish_deploy(source \\ "script") do
    set_flag(false, source)
    broadcast_system_chat(@finished_message, :always)
    :ok
  end

  @doc """
  Deploy aborted or failed: flag down, no chat announcement. Also the
  manual kill-switch behind Discord's `/cleardeploy`.
  """
  def clear_deploy(source \\ "script") do
    set_flag(false, source)
    :ok
  end

  @doc """
  Write flag to DB and update cache + broadcast (cache is warmed up from
  DB at startup by `Portal.Config.init_config/0`).
  """
  def set_flag(flag, source) when is_boolean(flag) do
    Config.update_key(:deploy_flag, flag)

    PortalChannel.broadcast_change("portal:user:*", %{deploy_flag: flag})

    %RC.Deploy.Log{}
    |> RC.Deploy.Log.changeset(%{flag: flag, source: to_string(source)})
    |> Repo.insert()
  end

  @doc """
  Get flag from cache, fallback to DB. Never raises — this sits on the
  faction-channel join path.
  """
  def get_flag do
    case Config.fetch() do
      {:ok, %{deploy_flag: flag}} -> flag
      _ -> get_flag_from_db()
    end
  end

  def get_flag_from_db do
    case from(l in RC.Deploy.Log, order_by: [desc: :id], limit: 1) |> Repo.one() do
      nil -> false
      %RC.Deploy.Log{flag: flag} -> flag
    end
  end

  @doc """
  Serve-time staleness filter for a faction chat ring, applied per
  recipient at the channel boundary (join reply + every faction push).
  Pure — the ring itself is never mutated and nothing is broadcast, so a
  client that was connected during the deploy keeps its copy until it
  refreshes, while a client that loads the game later never receives the
  stale lines:

    * the ongoing notice is only real while `deploy_flag?` is up;
    * the finished ("refresh recommended") notice is only for sockets
      that were already connected when it fired — a freshly loaded
      client is already running the new code.

  Only SYSTEM lines (`from_id: nil`) are eligible: a player pasting the
  exact notice text is never filtered.
  """
  def filter_stale_chat(chat, joined_at, deploy_flag?)
      when is_list(chat) and is_integer(joined_at) and is_boolean(deploy_flag?) do
    ongoing = @ongoing_message
    finished = @finished_message

    Enum.filter(chat, fn
      %{from_id: nil, message: ^ongoing} -> deploy_flag?
      %{from_id: nil, message: ^finished, timestamp: timestamp} -> timestamp >= joined_at
      _ -> true
    end)
  end

  @doc """
  Push a SYSTEM chat line into every faction chat ring of every live
  instance. `mode` is `:always` (plain append) or `:once` (skip factions
  whose ring already holds the exact line — used for the ongoing notice,
  which is also re-asserted on every late channel join).
  """
  def broadcast_system_chat(message, mode) when is_binary(message) and mode in [:always, :once] do
    op =
      case mode do
        :always -> {:push_system_message, message}
        :once -> {:push_system_message_once, message}
      end

    ["running", "paused"]
    |> RC.Instances.list_instances_with_state()
    |> Enum.filter(fn instance -> Instance.Manager.get_status(instance.id) in [:running, :instantiated] end)
    |> Enum.each(fn instance ->
      Enum.each(faction_ids(instance.id), fn faction_id ->
        Game.cast(instance.id, :faction, faction_id, op)
      end)
    end)
  end

  defp faction_ids(instance_id) do
    case RC.Instances.get_instance(instance_id) do
      %{factions: factions} when is_list(factions) -> Enum.map(factions, & &1.id)
      _ -> []
    end
  end
end
