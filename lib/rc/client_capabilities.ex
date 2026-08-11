defmodule RC.ClientCapabilities do
  @moduledoc """
  Per-player client protocol capabilities, announced at channel join.

  The client tells the server which broadcast protocols its bundle (and
  the account's beta flags) can consume — `PlayerChannel.join/3` records
  the announcement here, and broadcasters consult it to pick a payload
  shape. Today there is one capability:

    * `"player_production"` — the slim construction delta. Announced by
      clients whose account has the `slim_sync` beta feature enabled;
      everyone else keeps the legacy full `player_player` broadcasts.

  Announcing a capability is not a privilege (it only changes the shape
  of the announcer's own traffic), so the server trusts the client's
  list — gated by the code-side allowlist below so junk can't accumulate.

  Semantics, deliberately simple:

    * keyed by `{instance_id, player_id}` — LAST JOIN WINS. Two tabs of
      the same profile running different bundle versions (only possible
      mid-deploy, and deploys force a reconnect anyway) may briefly
      disagree; the losing tab still functions because every client
      handles both message kinds — it just syncs via the other path.
    * entries are never deleted: an empty announcement on the next join
      overwrites, and a stale entry for a fully-disconnected player only
      shapes broadcasts nobody receives. The table dies with the node.
    * missing entry = no capabilities = legacy protocol. A table restart
      therefore fails safe (everyone legacy until their next rejoin).
  """
  use GenServer

  @table :rc_client_capabilities
  @allowed ~w(player_production)
  @max_announced 8

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, %{}}
  end

  @doc "Record the capabilities a joining client announced."
  def register(instance_id, player_id, capabilities) when is_list(capabilities) do
    sanitized =
      capabilities
      |> Enum.take(@max_announced)
      |> Enum.filter(&(&1 in @allowed))

    :ets.insert(@table, {{instance_id, player_id}, sanitized})
    :ok
  end

  def register(_instance_id, _player_id, _capabilities), do: :ok

  @doc "Does the player's most recently joined client support `capability`?"
  def has?(instance_id, player_id, capability) do
    case :ets.lookup(@table, {instance_id, player_id}) do
      [{_, capabilities}] -> capability in capabilities
      [] -> false
    end
  rescue
    # Table missing (supervisor restart window) — fail safe to legacy.
    ArgumentError -> false
  end
end
