defmodule RC.MixProject do
  use Mix.Project

  def project do
    [
      app: :rc,
      version: "1.1.0",
      build_path: "_build",
      config_path: "config/config.exs",
      deps_path: "deps",
      lockfile: "mix.lock",
      elixir: "~> 1.19",
      elixirc_paths: elixirc_paths(Mix.env()),
      # :phoenix_live_view first: LiveView 1.1+ extracts colocated hooks/JS.
      compilers: [:phoenix_live_view] ++ Mix.compilers(),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      test_coverage: [tool: ExCoveralls],
      preferred_cli_env: [coveralls: :test, "coveralls.detail": :test, "coveralls.post": :test, "coveralls.html": :test],
      releases: [
        rc: [
          include_executables_for: [:unix],
          applications: [runtime_tools: :permanent]
        ]
      ]
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {RC.Application, []},
      extra_applications: [
        :logger,
        :runtime_tools,
        :os_mon,
        :ueberauth,
        :ueberauth_identity,
        :scrivener_ecto,
        :plug_logger_json
      ],
      # Nostrum is "included" rather than a regular runtime dep: its
      # .app and modules are loaded into the release at boot, but its
      # Application supervisor is NOT auto-started by the application
      # controller. RC.Discord.Supervisor calls
      # Application.ensure_all_started(:nostrum) manually only when
      # DISCORD_BOT_TOKEN is configured — otherwise nostrum's own
      # supervisor crashes the BEAM at boot. See the dep declaration
      # below for the history (we previously tried :load + optional,
      # neither worked because Mix's release-mode-consistency check
      # rejected the build).
      included_applications: [:nostrum]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    [
      # ALTCHA proof-of-work captcha (server-side challenge/verify only —
      # the client solver is ~30 lines of SubtleCrypto in assets/js/app.js,
      # no third-party service involved). See Portal.Captcha.
      {:altcha, "~> 2.0"},
      {:argon2_elixir, "~> 4.1"},
      {:behavior_tree, "~> 0.3.1"},
      {:corsica, "~> 1.0"},
      {:credo, "~> 1.2", only: [:dev, :test], runtime: false},
      {:csv, "~> 2.3"},
      {:collision, "~> 0.3.1"},
      {:ddrt, git: "https://github.com/windfish-studio/ddrt.git", ref: "3c0ba6defbfaad392e5ee41a7aae25c937a21058"},
      # ddrt (above, unmaintained) pins delta_crdt ~> 0.5, which holds horde
      # at 0.8.3 and through it telemetry at 0.4. delta_crdt 0.6 only added
      # the put/get/to_map API and deprecated mutate/read, which ddrt and
      # Spatial.Supervisor still call; nothing was removed, so override.
      {:delta_crdt, "~> 0.6.5", override: true},
      {:decorator, "~> 1.2"},
      # Markdown for player messages, blog posts and the help manual (RC.Markdown).
      {:mdex, "~> 0.14"},
      {:ecto_autoslug_field, "~> 2.0"},
      {:ecto_enum, "~> 1.4"},
      {:ecto_psql_extras, "~> 0.4"},
      {:ecto_sql, "~> 3.14"},
      # Only `mix update_data` (dev) reads Google Sheets; it starts the app
      # itself with the service-account credentials. runtime: false keeps it
      # out of boot (it would warn about missing auth) and out of releases.
      {:elixir_google_spreadsheets, "~> 1.0", runtime: false},
      {:email_guard, "~> 1.0"},
      {:ex_aws_s3, "~> 2.0"},
      # 2.5+ for IMDSv2 instance-metadata credentials (SES sends use the
      # EC2 instance role — see config :ex_aws, :ses in runtime.exs); 2.7 for
      # hackney 4.
      {:ex_aws, "~> 2.7"},
      # MIME rendering for Swoosh.Adapters.ExAwsAmazonSES raw sends.
      {:gen_smtp, "~> 1.2"},
      {:ex_doc, "~> 0.40", only: :dev, runtime: false},
      {:excoveralls, "~> 0.13", only: :test},
      {:filtrex, "~> 0.4.3"},
      {:floki, ">= 0.0.0", only: :test},
      # LiveViewTest (LiveView 1.1+) parses rendered HTML with lazy_html.
      {:lazy_html, ">= 0.1.0", only: :test},
      {:gelf_logger, "~> 0.10"},
      # 0.26 is the first with Gettext.Backend (`use Gettext, backend:`), which
      # the code uses. 1.0 is blocked: filtrex (even 0.5) needs timex ~> 3.7,
      # and timex 3 needs gettext ~> 0.26.
      {:gettext, "~> 0.26"},
      {:guardian_phoenix, "~> 2.0"},
      {:guardian, "~> 2.5"},
      # 4.x: every 1.x has open advisories (EEF-CVE-2026-115693 and others).
      # Used by ex_aws, tzdata, HTTPoison, and directly for SNS certificates.
      {:hackney, "~> 4.10"},
      # Steam Web API calls and the dev SPA proxy (Portal.Plug.DevProxy).
      {:httpoison, "~> 3.0"},
      # Per-IP rate limiting for sensitive endpoints (RC.RateLimit). ETS
      # backend, single-node only.
      {:hammer, "~> 7.5"},
      {:horde, "~> 0.10"},
      {:html_sanitize_ex, "~> 1.4"},
      {:jason, "~> 1.0"},
      {:libcluster, "~> 3.2"},
      {:libgraph, "~> 0.13"},
      {:machinery, "~> 1.0.0"},
      # Discord bot library. Driving the Tetrarchy bot that lives in
      # both the community and game guilds — see lib/rc/discord.ex.
      #
      # Manual start control: nostrum is listed in :included_applications
      # in our application/0 block above. That gets its .beam files
      # packed into the release tree (along with transitive deps gun,
      # cowlib, certifi, …) and loaded at BEAM boot, but its
      # Application supervisor is not auto-started. RC.Discord then
      # calls Application.ensure_all_started(:nostrum) only when
      # DISCORD_BOT_TOKEN is set — otherwise nostrum crashes the BEAM.
      #
      # Two earlier attempts that failed (recording so we don't loop):
      #   * `runtime: false` excluded the dep from the release entirely
      #     — broke prod with "no such file or directory: nostrum.app".
      #   * `optional: true` + `nostrum: :load` in release config was
      #     rejected by Mix with "Application :rc has mode :permanent
      #     but it depends on :nostrum which is set to :load".
      {:nostrum, "~> 0.10"},
      {:phoenix_ecto, "~> 4.6"},
      {:phoenix_html, "~> 4.0"},
      {:phoenix_html_helpers, "~> 1.0"},
      {:phoenix_view, "~> 2.0"},
      {:phoenix_live_dashboard, "~> 0.9"},
      {:phoenix_live_reload, "~> 1.2", only: :dev},
      {:phoenix_live_view, "~> 1.2"},
      {:phoenix_pubsub, "~> 2.0"},
      {:phoenix, "~> 1.8"},
      {:plug_cowboy, "~> 2.0"},
      {:plug_logger_json, "~> 0.7.0"},
      # plug_logger_json (prod's request logger) encodes with Poison but its
      # .app leaves Poison out, so a release only ships Poison when some other
      # app pulls it in. elixir_google_spreadsheets did until it went
      # runtime: false (2026-11-12); without Poison every prod request 500'd.
      {:poison, "~> 4.0"},
      {:postgrex, ">= 0.0.0"},
      {:puid, "~> 1.0"},
      {:rexbug, "~> 1.0"},
      {:scrivener_ecto, "~> 3.0"},
      {:scrivener_headers, "~> 3.1"},
      {:sweet_xml, "~> 0.6"},
      {:swoosh, "~> 1.0"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:terraform, "~> 1.0.1", only: :dev},
      {:typed_struct, "~> 0.2"},
      {:ueberauth_identity, "~> 0.3"},
      {:ueberauth, "~> 0.6"},
      # libvips bindings — encodes the animated Discord news cards (GIF).
      # Ships a precompiled NIF + libvips per target (x86_64/aarch64
      # linux-gnu), fetched at deps.compile, so hosts need no packages.
      {:vix, "~> 0.41"},
      {:waffle_ecto, "~> 0.1"},
      # 2.x dropped its hackney dependency (no remote URL uploads here).
      {:waffle, "~> 2.1"}
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  # For example, to create, migrate and run the seeds file at once:
  #
  #     $ mix ecto.setup
  #
  # See the documentation for `Mix` for more info on aliases.
  defp aliases do
    [
      "ecto.setup": ["ecto.create", "ecto.migrate", "run priv/repo/seeds.exs"],
      "puppet.setup": ["run priv/repo/puppets.exs"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ecto.create --quiet", "ecto.migrate", "test"]
    ]
  end
end
