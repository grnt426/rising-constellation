defmodule Portal.WaveController do
  @moduledoc """
  Dev harness for the Wave Defense MVP (docs/wave-defense.md).

      POST /api/harness/wave/start            boot a wave instance
      GET  /api/harness/wave/:iid/status      live readout (Wave.Status)
      POST /api/harness/wave/:iid/force_hire  run a hire cycle now
      POST /api/harness/wave/:iid/run         run one Warlord pass now
      POST /api/harness/wave/:iid/speed       {"multiplier": n} runtime speed cheat
      POST /api/harness/wave/:iid/dominion/:system_id  flip a rebel system to a dominion

  `start` body (all optional):

      {"email": "user1@abc",              // register this account in the human faction
       "owner_email": "user1@abc",        // instance owner (default user1@abc)
       "human_faction": "tetrarchy",      // default: first faction on the map
       "scenario_id": 42,                 // default: the bundled two-sector test map
       "knobs": {"hire_interval_ut": 5},  // merged over Wave.defaults/0
       "speedup": 100}                    // apply the speed cheat right after boot

  Gated twice: the harness pipeline's shared secret AND a non-prod environment.
  """
  use Portal, :controller

  def start(conn, params) do
    with :ok <- dev_only(conn) do
      opts =
        [
          owner_email: params["owner_email"],
          human_email: params["email"],
          human_faction: params["human_faction"],
          scenario_id: params["scenario_id"],
          knobs: params["knobs"]
        ]
        |> Enum.reject(fn {_k, v} -> is_nil(v) end)

      case Wave.Boot.start(opts) do
        {:ok, summary} ->
          speedup = apply_speedup(summary.instance_id, params["speedup"])

          json(
            conn,
            summary
            |> Map.put(:speedup, speedup)
            |> Map.put(:status, Wave.Status.read(summary.instance_id))
          )

        {:error, reason} ->
          conn |> put_status(500) |> json(%{error: inspect(reason)})
      end
    end
  end

  def status(conn, %{"iid" => iid}) do
    with :ok <- dev_only(conn), {:ok, iid} <- parse_id(conn, iid) do
      json(conn, Wave.Status.read(iid))
    end
  end

  def force_hire(conn, %{"iid" => iid}) do
    with :ok <- dev_only(conn), {:ok, iid} <- parse_id(conn, iid) do
      warlord_call(conn, iid, :force_hire)
    end
  end

  def run(conn, %{"iid" => iid}) do
    with :ok <- dev_only(conn), {:ok, iid} <- parse_id(conn, iid) do
      warlord_call(conn, iid, :run_now)
    end
  end

  # POST /api/harness/wave/:iid/speed {"multiplier": 200} — the runtime speed
  # cheat without the cheat channel's 50x ceiling, so a Legacy test game can
  # show a colonization round trip in minutes. Multiplies every tick factor in
  # the instance, the Warlord's included.
  def speed(conn, %{"iid" => iid} = params) do
    with :ok <- dev_only(conn), {:ok, iid} <- parse_id(conn, iid) do
      case apply_speedup(iid, params["multiplier"]) do
        nil -> conn |> put_status(400) |> json(%{error: "multiplier must be a positive number"})
        result -> json(conn, %{speedup: result})
      end
    end
  end

  # POST /api/harness/wave/:iid/dominion/:system_id — turn one of the
  # Rebellion's own systems into a dominion through the normal player call, so
  # the Rebel Dominion tree can be watched developing a dominion. The MVP has no
  # Siderians, so nothing else gives the bot a dominion to look at.
  def dominion(conn, %{"iid" => iid, "system_id" => system_id}) do
    with :ok <- dev_only(conn),
         {:ok, iid} <- parse_id(conn, iid),
         {:ok, system_id} <- parse_id(conn, system_id) do
      case Game.call(iid, :wave, :master, :status, 1, 10_000) do
        {:ok, %{player_id: player_id}} when is_integer(player_id) ->
          result =
            case Game.call(iid, :player, player_id, {:transform_system_to_dominion, system_id}, 1, 30_000) do
              :ok -> "ok"
              other -> inspect(other)
            end

          json(conn, %{result: result, status: Wave.Status.read(iid)})

        other ->
          conn |> put_status(500) |> json(%{error: inspect(other)})
      end
    end
  end

  defp apply_speedup(iid, multiplier) when is_number(multiplier) and multiplier > 0 do
    inspect(Instance.Manager.call(iid, {:cheat_set_speedup, multiplier}))
  end

  defp apply_speedup(_iid, _multiplier), do: nil

  defp warlord_call(conn, iid, message) do
    case Game.call(iid, :wave, :master, message, 1, 30_000) do
      {:ok, summary} -> json(conn, %{warlord: summary, status: Wave.Status.read(iid)})
      other -> conn |> put_status(500) |> json(%{error: inspect(other)})
    end
  end

  defp dev_only(conn) do
    if Application.get_env(:rc, :environment) in [:dev, :test] do
      :ok
    else
      conn |> put_status(403) |> json(%{error: "dev_only"}) |> halt()
    end
  end

  defp parse_id(conn, iid) do
    case Integer.parse(to_string(iid)) do
      {id, ""} -> {:ok, id}
      _ -> conn |> put_status(400) |> json(%{error: "bad_instance_id"}) |> halt()
    end
  end
end
