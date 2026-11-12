defmodule Portal.Plug.DevProxy do
  use HTTPoison.Base
  use Plug.Router

  @portal_host "http://localhost:8080"
  @game_host "http://localhost:8081"

  def process_url(url) do
    cond do
      String.starts_with?(url, "/portal") -> @portal_host <> url
      String.starts_with?(url, "/game") -> @game_host <> url
      true -> url
    end
  end

  plug(:match)
  plug(:dispatch)

  # catch all `get`s
  get _ do
    %{method: "GET", request_path: request_path, params: params, req_headers: req_headers} = conn

    cond do
      Application.get_env(:rc, :disallow_mp3) and String.ends_with?(request_path, ".mp3") ->
        send_resp(conn, 404, "")

      String.starts_with?(request_path, "/portal") or String.starts_with?(request_path, "/game") ->
        res = get!(request_path, req_headers, params: Map.to_list(params))
        send_response({:ok, conn, res})

      true ->
        send_resp(conn, 404, "")
    end
  end

  # Hop-by-hop headers describe the upstream connection, not this one. The
  # body below goes out whole (send_resp sets its own content-length), so a
  # forwarded `transfer-encoding: chunked` (webpack-dev-server 4 answers
  # compressible assets chunked, brotli-encoded) announced chunk framing that
  # never came: the browser waited on every script forever.
  @hop_by_hop ~w(connection keep-alive transfer-encoding content-length te trailer upgrade proxy-connection)

  defp send_response({:ok, conn, %{headers: headers, status_code: status_code, body: body}}) do
    headers = Enum.reject(headers, fn {name, _} -> String.downcase(name) in @hop_by_hop end)
    conn = %{conn | resp_headers: headers}
    send_resp(conn, status_code, body)
  end
end

defmodule EnvOnly do
  defmacro test(do: block) do
    if Mix.env() == :test do
      block
    end
  end

  defmacro dev(do: block) do
    if Mix.env() == :dev do
      block
    end
  end

  defmacro not_prod(do: block) do
    if Mix.env() != :prod do
      block
    end
  end

  defmacro not_dev(do: block) do
    if Mix.env() != :dev do
      block
    end
  end

  defmacro prod(do: block) do
    if Mix.env() == :prod do
      block
    end
  end
end
