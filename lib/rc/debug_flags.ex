defmodule RC.DebugFlags do
  @moduledoc """
  Run-time toggles for opt-in instrumentation that's too noisy to leave on
  in production but invaluable when chasing an intermittent bug.

  Reads from `Application.get_env(:rc, RC.DebugFlags, [])` so each flag
  can be set in `config/runtime.exs` from an env var (e.g.
  `RC_DEBUG_FLEET_INTERCEPTION=1`). A `set_*/1` setter also exists so
  tests and `iex` sessions can flip a flag without rebooting the app.

  Flags currently exposed:

    * `:fleet_interception` — when on,
      `Instance.Character.Actions.Fight.check_interception/3` emits a
      structured `Logger.info` line at each filter step: the raw
      `system.characters`, the post-faction-filter list, the
      post-state-lookup list with each candidate's `action_status` and
      `army.reaction`, and the final `reactions` list it filtered
      against. Use to diagnose "no combat happened where I expected
      one" reports — the log shows exactly which check ejected the
      defender.

    * `:action_trace` — when on, every action an admiral/agent
      starts, finishes, or aborts is appended to the
      `instance_event_log` table (`action_started` / `action_finished`
      / `action_aborted` rows) via `RC.Instances.InstanceEventLog`.
      This is the high-volume "what did this fleet do, in order?"
      trace; siege lifecycle events are logged regardless of this
      flag. Writes go to the DB, not the operator log, so turning it
      on does not flood journald — but it does grow the table quickly,
      so leave it off outside active debugging.

  Defaults are all `false` so a stray code path can never raise the
  noise level on its own.
  """

  @app :rc
  @key __MODULE__

  @doc """
  Is the fleet-interception instrumentation currently on?

  Default: `false`. Flip to `true` via:

    * `config :rc, RC.DebugFlags, fleet_interception: true` in
      `config/runtime.exs` (probably reading `System.get_env(...)`), or
    * `RC.DebugFlags.set_fleet_interception(true)` from `iex` /
      `setup_all` block in a test that needs the logs.
  """
  def fleet_interception?, do: get(:fleet_interception, false)

  @doc """
  Runtime override for `fleet_interception?/0`. Persists for the
  lifetime of the BEAM. Tests should reset this in `on_exit` if they
  flip it on.
  """
  def set_fleet_interception(value) when is_boolean(value),
    do: put(:fleet_interception, value)

  @doc """
  Is the action-trace instrumentation currently on?

  Default: `false`. Flip via `RC_DEBUG_ACTION_TRACE=1` in the
  environment or `RC.DebugFlags.set_action_trace(true)` at runtime.
  When on, action start/finish/abort events are appended to
  `instance_event_log`.
  """
  def action_trace?, do: get(:action_trace, false)

  @doc """
  Runtime override for `action_trace?/0`. Persists for the lifetime
  of the BEAM.
  """
  def set_action_trace(value) when is_boolean(value),
    do: put(:action_trace, value)

  ## Private

  defp get(flag, default) do
    @app
    |> Application.get_env(@key, [])
    |> Keyword.get(flag, default)
  end

  defp put(flag, value) do
    current = Application.get_env(@app, @key, [])
    Application.put_env(@app, @key, Keyword.put(current, flag, value))
  end
end
