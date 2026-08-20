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

    * `start_deploy/1`  — preflight, before the build: raises the flag.
      Every player-facing surface (portal marquee, in-game headband, the
      pinned chat banner) renders straight from the flag, so raising it
      IS the announcement.
    * `finish_deploy/1` — after a verified deploy: clears the flag and
      announces that an update was applied via a SYSTEM chat line.
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
  Raise the deploy notice: flag up. No chat line is inserted — the chat
  renderer pins a banner above the message list while the flag is up
  (Chat.vue, `state.portal.deployOngoing`), so the notice can't sink
  into the scroll-back and vanishes on its own when the flag clears.
  Idempotent — re-running just re-broadcasts the flag.
  """
  def start_deploy(source \\ "script") do
    set_flag(true, source)
    :ok
  end

  @doc """
  Deploy verified complete: flag down + "update applied" SYSTEM chat line
  in every faction of every live instance. Unlike the ongoing notice this
  one is a genuine chronological event, so it stays a real chat line.
  """
  def finish_deploy(source \\ "script") do
    set_flag(false, source)
    broadcast_system_chat(@finished_message)
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
  Pure — the ring itself is never mutated:

    * ongoing-notice lines are dropped unconditionally: the flag-driven
      chat banner replaced them, so any copy in a ring is a relic —
      old fan-outs surviving in faction snapshots, plus the one the
      OLD release's preflight `start_deploy` inserts during the deploy
      that ships this scheme;
    * the finished ("refresh recommended") notice is only for sockets
      that were already connected when it fired — a freshly loaded
      client is already running the new code.

  Only SYSTEM lines (`from_id: nil`) are eligible: a player pasting the
  exact notice text is never filtered.
  """
  def filter_stale_chat(chat, joined_at) when is_list(chat) and is_integer(joined_at) do
    ongoing = @ongoing_message
    finished = @finished_message

    Enum.filter(chat, fn
      %{from_id: nil, message: ^ongoing} -> false
      %{from_id: nil, message: ^finished, timestamp: timestamp} -> timestamp >= joined_at
      _ -> true
    end)
  end

  @doc """
  Push a SYSTEM chat line into every faction chat ring of every live
  instance (the "update applied" announcement).
  """
  def broadcast_system_chat(message) when is_binary(message) do
    ["running", "paused"]
    |> RC.Instances.list_instances_with_state()
    |> Enum.filter(fn instance -> Instance.Manager.get_status(instance.id) in [:running, :instantiated] end)
    |> Enum.each(fn instance ->
      Enum.each(faction_ids(instance.id), fn faction_id ->
        Game.cast(instance.id, :faction, faction_id, {:push_system_message, message})
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
