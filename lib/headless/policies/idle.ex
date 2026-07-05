defmodule Headless.Policies.Idle do
  @moduledoc """
  The null policy: the player exists, observes, and does nothing. The
  engine-only baseline for matchups and CPU measurements (it still pays the
  view-build cost, isolating "reading the game" from "acting on it").
  """

  @behaviour Headless.Bot.Policy

  @impl true
  def init(_ctx), do: %{}

  @impl true
  def decide(_view, mem), do: {[], mem}
end
