defmodule RC.Discord.Consumer do
  @moduledoc """
  Nostrum event consumer for the Tetrarchy Falls Discord bot.

  Kept intentionally thin: this module is just the dispatch table that
  routes Nostrum gateway events to the right handler. Per the Nostrum
  docs, the `use Nostrum.Consumer` macro automatically spawns a fresh
  Task per event, so we get parallelism for free — no need to start
  multiple consumers in the supervision tree.

  Currently handled events:

    * `:READY` — bot has connected to the gateway and identified.
      We use this to (re)register guild-scoped slash commands. Guild
      commands propagate instantly (vs. global commands which can take
      up to an hour), and we're a private bot living in two fixed
      guilds, so guild scope is the right choice.

    * `:INTERACTION_CREATE` — a user invoked a slash command, button,
      or modal. Delegated to `RC.Discord.Commands.dispatch/1`.

  All other events are intentionally ignored.
  """

  use Nostrum.Consumer

  require Logger

  @impl true
  def handle_event({:READY, ready, _ws_state}) do
    # :warning level so the connection status is visible even at dev's
    # default logger level (config/dev.exs sets level: :warning).
    Logger.warning(
      "[RC.Discord] gateway connected as #{ready.user.username}##{ready.user.discriminator} " <>
        "(session #{ready.session_id})"
    )

    RC.Discord.Commands.register_all()
  end

  @impl true
  def handle_event({:INTERACTION_CREATE, interaction, _ws_state}) do
    RC.Discord.Commands.dispatch(interaction)
  end

  # Catch-all so unhandled gateway events don't log noise. Nostrum
  # already provides a default no-op, but being explicit here makes
  # the intent obvious when reading.
  @impl true
  def handle_event(_event), do: :ok
end
