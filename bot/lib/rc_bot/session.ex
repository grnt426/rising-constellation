defmodule RcBot.Session do
  @moduledoc """
  One bot's full lifecycle: log in → register → connect → join channels →
  run a short action burst → disconnect.

  Task #4 implementation: minimal end-to-end proof. The burst phase grants
  itself some resources via the cheat channel and sends a single
  `order_building` (which may fail if no system is owned yet — that's fine,
  we're verifying the wire path here, not strategy).

  Args passed to `start_link/1`:
    * `:bot_id`       — opaque identifier, also used as registry key
    * `:email`        — bot account email
    * `:password`     — bot account password
    * `:profile_id`   — pid of the bot's profile
    * `:instance_id`  — instance to join
    * `:faction_id`   — faction within the instance
  """

  use Slipstream, restart: :temporary

  require Logger

  defstruct [
    :bot_id,
    :email,
    :password,
    :profile_id,
    :instance_id,
    :faction_id,
    :jwt,
    :registration_token,
    # Latest player_player snapshot. Seeded from the instance:player join
    # reply, then refreshed by every broadcast on that channel. Passed to
    # the policy module to decide actions.
    player_view: nil,
    # Policy module — swappable per-bot for future experimentation.
    policy: RcBot.Policy.Dumb,
    joined: MapSet.new(),
    burst_done: false
  ]

  def child_spec(args) do
    %{
      id: {__MODULE__, args[:bot_id]},
      start: {__MODULE__, :start_link, [args]},
      restart: :temporary,
      type: :worker
    }
  end

  def start_link(args) do
    name = {:via, Registry, {RcBot.Registry, {:session, args[:bot_id]}}}
    Slipstream.start_link(__MODULE__, args, name: name)
  end

  @impl Slipstream
  def init(args) do
    bot_state = struct(__MODULE__, args)
    Logger.metadata(bot_id: bot_state.bot_id, stage: :init)
    Logger.info("bot starting")

    with {:ok, jwt} <- RcBot.Auth.login(bot_state.email, bot_state.password),
         :ok <- RcBot.Telemetry.report(jwt, "login_ok", base_telemetry_opts(bot_state)),
         {:ok, reg_token} <- get_or_register(bot_state, jwt),
         :ok <-
           RcBot.Telemetry.report(jwt, "register_ok", base_telemetry_opts(bot_state)) do
      bot_state = %{bot_state | jwt: jwt, registration_token: reg_token}

      case connect(socket_config(jwt)) do
        {:ok, socket} ->
          {:ok, assign(socket, :bot, bot_state)}

        {:error, reason} ->
          RcBot.Telemetry.report(jwt, "connect_fail",
            base_telemetry_opts(bot_state) ++ [status: "error", reason: inspect(reason)]
          )

          Logger.error("socket connect failed: #{inspect(reason)}")
          {:stop, {:connect_failed, reason}}
      end
    else
      {:error, reason} ->
        # We may or may not have a JWT depending on which step failed.
        # Telemetry.report handles nil JWT by no-op'ing.
        RcBot.Telemetry.report(nil, "bootstrap_fail",
          base_telemetry_opts(bot_state) ++ [status: "error", reason: inspect(reason)]
        )

        Logger.error("bootstrap HTTP failed: #{inspect(reason)}")
        {:stop, {:bootstrap_failed, reason}}
    end
  end

  # Common telemetry context — instance + profile so the dashboard can
  # group lifecycle events with the action stream.
  defp base_telemetry_opts(%__MODULE__{} = state) do
    [instance_id: state.instance_id, profile_id: state.profile_id]
  end

  @impl Slipstream
  def handle_connect(socket) do
    Logger.metadata(stage: :connect)
    Logger.info("socket connected, joining channels")

    bot = socket.assigns.bot
    RcBot.Telemetry.report(bot.jwt, "socket_connected", base_telemetry_opts(bot))

    socket =
      socket
      |> join("portal:profile:#{bot.profile_id}", %{})
      |> join("instance:player:#{bot.instance_id}:#{bot.profile_id}", %{
        "registration" => bot.registration_token
      })
      |> join("cheat:player:#{bot.instance_id}:#{bot.profile_id}", %{})

    {:ok, socket}
  end

  @impl Slipstream
  def handle_join(topic, join_response, socket) do
    Logger.info("joined #{topic}")

    bot =
      socket.assigns.bot
      |> Map.update!(:joined, &MapSet.put(&1, topic))
      |> maybe_seed_player_view(topic, join_response)

    socket = assign(socket, :bot, bot)

    if all_joined?(bot) and not bot.burst_done do
      send(self(), :run_burst)
    end

    {:ok, socket}
  end

  # Only the instance:player join reply carries player state. Other channels'
  # join replies are server status maps we don't need to track.
  defp maybe_seed_player_view(bot, "instance:player:" <> _rest, %{"player_player" => view}) do
    %{bot | player_view: view}
  end

  defp maybe_seed_player_view(bot, _topic, _resp), do: bot

  @impl Slipstream
  def handle_info(:run_burst, socket) do
    Logger.metadata(stage: :burst)
    bot = socket.assigns.bot

    cheat_topic = "cheat:player:#{bot.instance_id}:#{bot.profile_id}"

    # Top up resources so the policy can afford whatever it decides.
    # Idempotent and harmless if not used.
    push(socket, cheat_topic, "grant_resources", %{credit: 100_000, technology: 10_000})

    actions = bot.policy.decide_actions(bot.player_view)
    Logger.info("burst: policy=#{inspect(bot.policy)} actions=#{length(actions)}")

    RcBot.Telemetry.report(
      bot.jwt,
      "burst_start",
      base_telemetry_opts(bot) ++ [reason: "actions=#{length(actions)}"]
    )

    Enum.each(actions, fn {event, payload, channel} ->
      topic = channel_topic(channel, bot)
      Logger.info("burst push: #{topic} #{event}")
      push(socket, topic, event, payload)
    end)

    socket = assign(socket, :bot, %{bot | burst_done: true})
    Process.send_after(self(), :end_burst, 1_500)
    {:noreply, socket}
  end

  def handle_info(:end_burst, socket) do
    Logger.info("burst done, disconnecting")
    bot = socket.assigns.bot
    RcBot.Telemetry.report(bot.jwt, "burst_complete", base_telemetry_opts(bot))
    {:noreply, disconnect(socket)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl Slipstream
  def handle_reply(ref, reply, socket) do
    Logger.debug("reply ref=#{inspect(ref)} payload=#{inspect(reply)}")
    {:ok, socket}
  end

  @impl Slipstream
  def handle_topic_close(topic, reason, socket) do
    Logger.error("topic_close topic=#{topic} reason=#{inspect(reason)}")

    bot = socket.assigns.bot

    RcBot.Telemetry.report(
      bot.jwt,
      "channel_join_fail",
      base_telemetry_opts(bot) ++ [status: "error", reason: "#{topic}: #{inspect(reason)}"]
    )

    {:ok, socket}
  end

  @impl Slipstream
  def handle_message(topic, event, %{"player_player" => view} = payload, socket) do
    Logger.debug("server msg topic=#{topic} event=#{event} player_player update")
    _ = payload
    bot = %{socket.assigns.bot | player_view: view}
    {:ok, assign(socket, :bot, bot)}
  end

  def handle_message(topic, event, payload, socket) do
    Logger.debug("server msg topic=#{topic} event=#{event} payload=#{inspect(payload)}")
    {:ok, socket}
  end

  defp channel_topic(:player, bot), do: "instance:player:#{bot.instance_id}:#{bot.profile_id}"
  defp channel_topic(:cheat, bot), do: "cheat:player:#{bot.instance_id}:#{bot.profile_id}"

  @impl Slipstream
  def handle_disconnect(reason, socket) do
    Logger.info("disconnected: #{inspect(reason)}")

    bot = socket.assigns.bot

    RcBot.Telemetry.report(
      bot.jwt,
      "disconnected",
      base_telemetry_opts(bot) ++ [reason: inspect(reason)]
    )

    # Give the fire-and-forget telemetry task a beat to actually fire its
    # HTTP request before the BEAM tears the process down.
    Process.sleep(100)

    {:stop, :normal, socket}
  end

  # Pre-supplied tokens let the harness skip the HTTP register/fetch round
  # (useful in e2e tests where the token is already known) and let an
  # operator paste a captured token without re-running registration logic.
  defp get_or_register(%__MODULE__{registration_token: t}, _jwt) when is_binary(t), do: {:ok, t}

  defp get_or_register(state, jwt) do
    RcBot.Auth.register(jwt, state.profile_id, state.instance_id, state.faction_id)
  end

  defp socket_config(jwt) do
    uri = Application.fetch_env!(:rc_bot, :target_ws)
    [uri: "#{uri}?token=#{URI.encode_www_form(jwt)}"]
  end

  defp all_joined?(%__MODULE__{joined: joined, instance_id: iid, profile_id: pid}) do
    required =
      MapSet.new([
        "portal:profile:#{pid}",
        "instance:player:#{iid}:#{pid}",
        "cheat:player:#{iid}:#{pid}"
      ])

    MapSet.subset?(required, joined)
  end
end
