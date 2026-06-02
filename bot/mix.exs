defmodule RcBot.MixProject do
  use Mix.Project

  def project do
    [
      app: :rc_bot,
      version: "0.1.0",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      releases: [
        rc_bot: [
          include_executables_for: [:unix],
          applications: [runtime_tools: :permanent]
        ]
      ]
    ]
  end

  def application do
    [
      mod: {RcBot.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  defp deps do
    [
      # Phoenix Channel client. Handles socket lifecycle, heartbeats,
      # reconnection — the things you don't want to roll yourself.
      {:slipstream, "~> 1.1"},
      # HTTP client for login + registration. Req is simpler than HTTPoison
      # and the JSON encoding/decoding is built in.
      {:req, "~> 0.5"},
      {:jason, "~> 1.4"},
      # Driver-side admin LiveView (RcBot.Endpoint).
      # Matches the rc app's pinned versions so we don't surprise-upgrade.
      {:phoenix, "~> 1.7.14"},
      {:phoenix_live_view, "~> 0.20.17"},
      {:phoenix_html, "~> 4.0"},
      {:phoenix_pubsub, "~> 2.0"},
      {:plug_cowboy, "~> 2.7"}
    ]
  end
end
