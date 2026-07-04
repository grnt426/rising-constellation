defmodule Portal.GovDebugController do
  @moduledoc """
  Harness-secret-gated, DEV-ONLY faction government clock control.

  Advances a faction's government by `ut` game-time units through the
  real engine (`Faction.Agent {:gov_debug_advance, ut}`): founding ends,
  ballots close, quorums and tallies process exactly as if the time had
  passed. Unlike the faction-channel `gov_debug_advance` this is not
  bound to faction membership, so it can drive factions with ZERO
  registered players — the empty-faction edge cases (e.g. an unclaimed
  ARK whose founding ends with nobody to bid).

  Hard-gated to `:environment == :dev` on every action: the harness
  scope itself exists in prod for the bot pipeline, and a prod time-warp
  must not — so even a valid harness secret gets a 404 there.
  """
  use Portal, :controller

  # GET /api/harness/gov-debug/status?iid=6&fid=12
  def status(conn, %{"iid" => iid, "fid" => fid}) do
    with :ok <- dev_only(),
         {:ok, iid, fid} <- parse_ids(iid, fid),
         {:ok, %{government: government}} <-
           Game.call(iid, :faction, fid, {:get_government, nil}) do
      json(conn, %{
        instance_id: iid,
        faction_id: fid,
        phase: government.phase,
        founding_remaining: government.founding.value,
        ballots:
          Enum.map(government.ballots, fn ballot ->
            %{id: ballot.id, seat: ballot.seat, kind: ballot.kind, remaining: ballot.cooldown.value}
          end),
        seats: government.seats
      })
    else
      {:error, :not_dev} -> conn |> put_status(404) |> json(%{error: :not_available})
      {:error, :invalid_params} -> conn |> put_status(400) |> json(%{error: :invalid_params})
      {:error, reason} -> conn |> put_status(422) |> json(%{error: inspect(reason)})
      other -> conn |> put_status(422) |> json(%{error: inspect(other)})
    end
  end

  # POST /api/harness/gov-debug/advance {"iid": 6, "fid": 12, "ut": 1430.5}
  def advance(conn, %{"iid" => iid, "fid" => fid, "ut" => ut}) do
    with :ok <- dev_only(),
         {:ok, iid, fid} <- parse_ids(iid, fid),
         true <- is_number(ut) and ut > 0 and ut <= 1_000_000,
         :ok <- Game.call(iid, :faction, fid, {:gov_debug_advance, ut}) do
      json(conn, %{advanced: true, instance_id: iid, faction_id: fid, ut: ut})
    else
      {:error, :not_dev} -> conn |> put_status(404) |> json(%{error: :not_available})
      {:error, :invalid_params} -> conn |> put_status(400) |> json(%{error: :invalid_params})
      false -> conn |> put_status(400) |> json(%{error: :invalid_params})
      {:error, reason} -> conn |> put_status(422) |> json(%{advanced: false, error: inspect(reason)})
      other -> conn |> put_status(422) |> json(%{advanced: false, error: inspect(other)})
    end
  end

  # POST /api/harness/gov-debug/deposit {"iid": 6, "fid": 11, "credit": 0, "technology": 5000, "ideology": 5000}
  def deposit(conn, %{"iid" => iid, "fid" => fid} = params) do
    amounts = %{
      credit: Map.get(params, "credit", 0),
      technology: Map.get(params, "technology", 0),
      ideology: Map.get(params, "ideology", 0)
    }

    with :ok <- dev_only(),
         {:ok, iid, fid} <- parse_ids(iid, fid),
         true <- Enum.all?(Map.values(amounts), &(is_number(&1) and &1 >= 0 and &1 <= 10_000_000)),
         :ok <- Game.call(iid, :faction, fid, {:gov_debug_deposit, amounts}) do
      json(conn, %{deposited: true, amounts: amounts})
    else
      {:error, :not_dev} -> conn |> put_status(404) |> json(%{error: :not_available})
      {:error, :invalid_params} -> conn |> put_status(400) |> json(%{error: :invalid_params})
      false -> conn |> put_status(400) |> json(%{error: :invalid_params})
      other -> conn |> put_status(422) |> json(%{error: inspect(other)})
    end
  end

  defp dev_only do
    if Application.get_env(:rc, :environment) == :dev,
      do: :ok,
      else: {:error, :not_dev}
  end

  defp parse_ids(iid, fid) do
    with {iid, ""} <- Integer.parse(to_string(iid)),
         {fid, ""} <- Integer.parse(to_string(fid)) do
      {:ok, iid, fid}
    else
      _ -> {:error, :invalid_params}
    end
  end
end
