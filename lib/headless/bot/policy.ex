defmodule Headless.Bot.Policy do
  @moduledoc """
  Behaviour for headless bot policies.

  A policy is a pure decision function over a `Headless.Bot.View` snapshot:
  the driver (`Headless.Bot`) builds the view on a game-time cadence, calls
  `decide/2`, and executes the returned abstract actions via
  `Headless.Bot.Act`. Policies never call the engine directly — that keeps
  them pure (testable against recorded views, evolvable by the game-ai.md §6
  loop) and keeps every engine payload shape in one place (`Act`).

  `mem` is the policy's private memory, threaded through calls — pipeline
  state machines (e.g. the colonization loop) live here.
  """

  @type mem :: term()
  @type action :: Headless.Bot.Act.action()

  @doc "Build the policy's initial memory. `ctx` has :player_id and :faction."
  @callback init(ctx :: map()) :: mem()

  @doc """
  One decision pass. Returns abstract actions to attempt (in order) and the
  updated memory. Refusals are normal — the engine validates; policies may
  retry next tick.
  """
  @callback decide(view :: Headless.Bot.View.t(), mem()) :: {[action()], mem()}
end
