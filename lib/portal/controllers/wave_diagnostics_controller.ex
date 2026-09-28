defmodule Portal.WaveDiagnosticsController do
  @moduledoc """
  Admin-only health readout of a Rebel Defense instance's bot controller
  (`Wave.Diagnostics`). Routed under the admin-authorization scope.

      GET /api/instances/:iid/wave/diagnostics
  """
  use Portal, :controller

  action_fallback(Portal.FallbackController)

  def show(conn, %{"iid" => iid}) do
    with {id, ""} <- Integer.parse(to_string(iid)),
         %{} = instance <- RC.Instances.get_instance(id) do
      if Wave.Lobby.wave?(instance.game_data) do
        json(conn, Map.put(Wave.Diagnostics.read(id, instance.game_data), :state, instance.state))
      else
        conn |> put_status(:unprocessable_entity) |> json(%{message: :not_a_wave_instance})
      end
    else
      _ -> {:error, :not_found}
    end
  end
end
