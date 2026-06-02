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
      {:jason, "~> 1.4"}
    ]
  end
end
