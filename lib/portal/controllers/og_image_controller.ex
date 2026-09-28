defmodule Portal.OgImageController do
  @moduledoc """
  Public link-preview images (see Portal.OgImage):

      GET /og/map/:share_token.png
      GET /og/scenario/:share_token.png
      GET /og/instance/:share_token.png

  Share token only (RC.ShareToken). The token is the capability that
  already opens the page whose preview this is, so no auth and no
  draft/private checks; a numeric id or unknown token 404s.
  """
  use Portal, :controller

  alias RC.Scenarios

  def map(conn, %{"file" => file}), do: serve(conn, :map, file)
  def scenario(conn, %{"file" => file}), do: serve(conn, :scenario, file)
  def instance(conn, %{"file" => file}), do: serve(conn, :instance, file)

  defp serve(conn, kind, file) do
    with token when is_binary(token) <- token(file),
         row when not is_nil(row) <- fetch(kind, token),
         {:ok, png} <- Portal.OgImage.png(kind, row) do
      conn
      |> put_resp_content_type("image/png", nil)
      # The URL changes with the render (?v=), so it can be cached hard.
      |> put_resp_header("cache-control", "public, max-age=86400")
      |> send_resp(200, png)
    else
      _ -> send_resp(conn, 404, "not found")
    end
  end

  defp token(file) do
    with ".png" <- Path.extname(file),
         token = Path.rootname(file),
         {:token, ^token} <- RC.ShareToken.parse_ref(token) do
      token
    else
      _ -> nil
    end
  end

  defp fetch(:map, token), do: Scenarios.get_map_by_token(token)
  defp fetch(:scenario, token), do: Scenarios.get_scenario_by_token(token)
  defp fetch(:instance, token), do: RC.Instances.get_instance_by_token(token)
end
