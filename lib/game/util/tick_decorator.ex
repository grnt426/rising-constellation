defmodule Util.TickDecorator do
  @moduledoc """
  Decorators related to Core.Tick
  """
  use Decorator.Define, tick: 0, tick_rearm: 0

  @doc """
  This can be used on GenServer callbacks:
  * handle_call/3
  * handle_cast/2
  * handle_continue/2
  * handle_info/3
  * terminate/2

  It relies on var!/1 to make the macro not hygienic (intentionally mutating and
  leaking 'state')
  see https://elixirschool.com/en/lessons/advanced/metaprogramming/#macro-hygiene
  """
  def tick(body, context) do
    quote do
      var!(state) = next_tick(unquote(List.last(context.args)))
      unquote(body)
    end
  end

  @doc """
  `tick/0`, plus re-arming the tick timer after the body when the body
  changed the agent's `data`.

  `tick/0` runs `next_tick/1` BEFORE the body, so the next tick is scheduled
  from the pre-change state. When the body changes what that schedule
  depends on (a production bonus, a queued order, a siege), the timer stays
  armed for the old state: a boosted construction completes late, a slowed
  one wakes early for nothing. The agent module must define
  `tick_interval/1` (data -> unit time | :never), normally its domain
  module's `compute_next_tick_interval/1`.

  Note: the decorator library applies a function's first decorated clause's
  decorators to every clause that has none, so decorating a handler's first
  clause covers them all.
  """
  def tick_rearm(body, context) do
    quote do
      var!(state) = next_tick(unquote(List.last(context.args)))
      tick_rearm_data_before = var!(state).data
      Core.TickServer.rearm_after(unquote(body), tick_rearm_data_before, &tick_interval/1)
    end
  end
end
