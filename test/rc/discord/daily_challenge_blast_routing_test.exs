defmodule RC.Discord.DailyChallengeBlastRoutingTest do
  @moduledoc """
  Channel routing for the daily-challenge blast. Not async: it swaps
  the `RC.Discord` application env (channel ids) around each case.
  """

  use ExUnit.Case, async: false

  alias RC.Discord.DailyChallengeBlast, as: Blast

  setup do
    previous = Application.get_env(:rc, RC.Discord)
    on_exit(fn -> restore(previous) end)
    :ok
  end

  defp restore(nil), do: Application.delete_env(:rc, RC.Discord)
  defp restore(previous), do: Application.put_env(:rc, RC.Discord, previous)

  defp configure(opts), do: Application.put_env(:rc, RC.Discord, opts)

  test "the dedicated #daily-challenge channel is the only destination" do
    configure(
      daily_challenge_channel_id: "1518766710306373692",
      news_channel_id: "1533832123302023319",
      community_game_news_channel_id: "1533832123302023320"
    )

    assert Blast.configured_channels() == [1_518_766_710_306_373_692]
  end

  test "falls back to the deduped news channels when it is unset" do
    configure(
      daily_challenge_channel_id: "",
      news_channel_id: "1533832123302023319",
      community_game_news_channel_id: "1533832123302023319"
    )

    assert Blast.configured_channels() == [1_533_832_123_302_023_319]
  end

  test "no channels configured at all means no blast" do
    configure([])

    assert Blast.configured_channels() == []
  end
end
