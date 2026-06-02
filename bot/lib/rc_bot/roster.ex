defmodule RcBot.Roster do
  @moduledoc """
  Source of truth for "which bots exist + what creds + what game."

  v1: loaded from application config. The expected shape under
  `:rc_bot, :roster` is a list of maps, one per bot:

      [
        %{
          bot_id: "stressbot-1",
          email: "stressbot1@stress.local",
          password: "...",
          profile_id: 3,
          instance_id: 1,
          faction_id: 1
        },
        ...
      ]

  v2 (deferred): query `is_bot=true` accounts from the rc DB, derive
  credentials from a shared `RC_BOT_SHARED_PASSWORD` env var, and pick
  up the right (instance_id, faction_id) from a per-deployment config.
  That removes the need to maintain the roster list when scaling past
  ~10 bots, but adds DB coupling on the harness side.
  """

  @doc """
  Return the configured roster, or `[]` if none is set.
  """
  def all do
    Application.get_env(:rc_bot, :roster, [])
  end

  @doc """
  Return the roster entry matching `bot_id`, or nil.
  """
  def get(bot_id) do
    Enum.find(all(), &(&1.bot_id == bot_id))
  end

  @doc """
  Configured count — convenient for logging and dashboard display.
  """
  def size, do: length(all())
end
