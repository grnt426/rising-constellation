defmodule RcBot.Router do
  use Phoenix.Router
  import Phoenix.LiveView.Router

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:put_secure_browser_headers)
  end

  scope "/", RcBot.Web do
    pipe_through(:browser)

    live("/", BotsLive)
    live("/bots", BotsLive)
  end
end
