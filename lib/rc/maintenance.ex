defmodule RC.Maintenance do
  @moduledoc """
  The Maintenance context.
  """

  import Ecto.Query, warn: false

  alias Portal.Config
  alias Portal.Controllers.PortalChannel
  alias RC.Maintenance
  alias RC.Repo

  @doc """
  Write flag to DB and update cache (cache is warmed up from DB at startup)
  """
  def set_flag(flag, account_id) do
    Config.update_key(:maintenance_flag, flag)

    PortalChannel.broadcast_change("portal:user:*", %{maintenance_flag: flag})

    %Maintenance.Log{}
    |> Maintenance.Log.changeset(%{flag: flag, account_id: account_id})
    |> Repo.insert()
  end

  @doc """
  Get flag from cache, fallback to DB
  """
  def get_flag() do
    case Config.fetch_key(:maintenance_flag) do
      :error ->
        get_flag_from_db()

      flag ->
        flag
    end
  end

  def get_latest() do
    latest =
      from(l in Maintenance.Log, order_by: [desc: :id], limit: 1)
      |> Repo.one()

    case latest do
      nil -> %Maintenance.Log{flag: false}
      latest -> latest
    end
  end

  def get_flag_from_db() do
    case get_latest() do
      nil -> false
      %Maintenance.Log{flag: flag} -> flag
    end
  end
end
