defmodule Portal.ForesightController do
  @moduledoc """
  Foresight — match predictions with Foresight Tokens (docs/foresight.md).

      GET  /api/foresight                → balances + active + settled predictions
      GET  /api/instances/:iid/foresight → per-faction totals + own predictions + window
      POST /api/instances/:iid/foresight → body {"faction_id" => id, "tokens" => n}

  Beta-gated on the `foresight` account feature, checked server-side
  (unlike older flags, which are client-honored): predictions move a real
  balance, so the server is the authority.
  """
  use Portal, :controller

  alias RC.Accounts
  alias RC.Foresight

  plug(
    Portal.Plug.AccountRateLimit,
    [bucket: "foresight_commit", limit: 30, window_ms: 60_000] when action == :commit
  )

  def overview(conn, _params) do
    account_id = conn.private.guardian_default_resource.id

    case check_feature(account_id) do
      :ok ->
        overview = Foresight.account_overview(account_id)

        json(conn, %{
          tokens: overview.tokens,
          points: overview.points,
          active: Enum.map(overview.active, &prediction_json/1),
          settled: Enum.map(overview.settled, &prediction_json/1)
        })

      {:error, reason} ->
        error_response(conn, reason)
    end
  end

  def summary(conn, %{"iid" => iid}) do
    account_id = conn.private.guardian_default_resource.id

    with :ok <- check_feature(account_id),
         {:ok, instance_id} <- parse_id(iid) do
      summary = Foresight.instance_summary(instance_id, account_id)

      json(conn, %{
        totals: summary.totals,
        mine: Enum.map(summary.mine, &prediction_json/1),
        open: summary.open
      })
    else
      {:error, reason} -> error_response(conn, reason)
    end
  end

  def commit(conn, %{"iid" => iid, "faction_id" => faction_id, "tokens" => tokens})
      when is_integer(faction_id) and is_integer(tokens) do
    account_id = conn.private.guardian_default_resource.id

    with :ok <- check_feature(account_id),
         {:ok, instance_id} <- parse_id(iid),
         {:ok, prediction} <- Foresight.commit(account_id, instance_id, faction_id, tokens) do
      overview = Foresight.account_overview(account_id, limit: 1)

      json(conn, %{
        prediction: prediction_json(prediction),
        tokens: overview.tokens,
        points: overview.points
      })
    else
      {:error, reason} -> error_response(conn, reason)
    end
  end

  def commit(conn, _params) do
    conn |> put_status(:bad_request) |> json(%{message: :bad_request})
  end

  defp check_feature(account_id) do
    if Accounts.feature_enabled?(account_id, "foresight"), do: :ok, else: {:error, :feature_disabled}
  end

  defp error_response(conn, :feature_disabled), do: conn |> put_status(:forbidden) |> json(%{message: :feature_disabled})
  defp error_response(conn, :not_found), do: conn |> put_status(:not_found) |> json(%{message: :not_found})
  defp error_response(conn, reason), do: conn |> put_status(:bad_request) |> json(%{message: reason})

  defp parse_id(raw) do
    case Integer.parse(to_string(raw)) do
      {id, ""} -> {:ok, id}
      _other -> {:error, :not_found}
    end
  end

  defp prediction_json(p) do
    %{
      id: p.id,
      instance_id: p.instance_id,
      faction_id: p.faction_id,
      faction_ref: p.faction_ref,
      tokens: p.tokens,
      credited_tokens: p.credited_tokens,
      status: p.status,
      tokens_recovered: p.tokens_recovered,
      bonus_tokens: p.bonus_tokens,
      points_awarded: p.points_awarded,
      committed_at: p.inserted_at,
      settled_at: p.settled_at
    }
  end
end
