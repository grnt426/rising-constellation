defmodule Portal.FeatureController do
  @moduledoc """
  Per-account opt-in beta feature flags (Account → Beta Features).

      GET /api/features          → %{"features" => %{"agent_fan_display" => true, ...}}
      PUT /api/features          → body {"feature" => key, "enabled" => bool}

  Only whitelisted keys (`RC.Accounts.AccountFeature.known/0`) are accepted.
  """
  use Portal, :controller

  alias RC.Accounts

  def index(conn, _params) do
    account_id = conn.private.guardian_default_resource.id
    json(conn, %{features: Accounts.list_features(account_id)})
  end

  def update(conn, %{"feature" => feature, "enabled" => enabled}) when is_boolean(enabled) do
    account_id = conn.private.guardian_default_resource.id

    case Accounts.set_feature(account_id, feature, enabled) do
      {:ok, _} ->
        json(conn, %{features: Accounts.list_features(account_id)})

      {:error, _changeset} ->
        conn |> put_status(:bad_request) |> json(%{message: :unknown_feature})
    end
  end

  def update(conn, _params) do
    conn |> put_status(:bad_request) |> json(%{message: :bad_request})
  end
end
