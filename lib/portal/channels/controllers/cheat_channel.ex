defmodule Portal.Controllers.CheatChannel do
  @moduledoc """
  Out-of-band channel used by stress-test bots to short-circuit normal game
  economics (grant resources, instant-finish production, etc.). Refuses to
  join unless the caller's account has `is_bot == true`. Every handler also
  re-asserts the flag so a config slip can't accidentally expose cheats to
  real players.

  Topic format: `cheat:player:{instance_id}:{player_id}`. Caller must already
  be authorised to act AS that player — same registration check the normal
  PlayerChannel does.
  """

  use Phoenix.Channel
  use Portal.ReplayRecorder

  require Logger

  def join("cheat:player:" <> channel_data, _params, socket) do
    [instance_id, player_id] =
      channel_data
      |> String.split(":")
      |> Enum.map(&String.to_integer/1)

    cond do
      not is_bot?(socket) ->
        {:error, %{reason: "not_a_bot"}}

      not Instance.Manager.created?(instance_id) ->
        {:error, %{reason: "instance_not_instantiated"}}

      not own_player?(socket, instance_id, player_id) ->
        {:error, %{reason: "not_authorised_for_player"}}

      true ->
        socket =
          socket
          |> assign(:instance_id, instance_id)
          |> assign(:player_id, player_id)
          |> assign(:channel_name, "cheat")
          # `has_replay` gates Portal.ReplayRecorder's per-action replay
          # persistence. Cheats are out-of-band stress-test glue; we don't
          # want them mixed into game replays. Bot monitoring still fires
          # — it has its own gate (account.is_bot).
          |> assign(:has_replay, false)

        {:ok, socket}
    end
  end

  record("grant_resources", payload, socket) do
    with :ok <- assert_bot(socket) do
      amounts = %{
        credit: Map.get(payload, "credit", 0),
        technology: Map.get(payload, "technology", 0),
        ideology: Map.get(payload, "ideology", 0)
      }

      case Game.call(iid(socket), :player, pid(socket), {:cheat, :grant_resources, amounts}) do
        {:error, reason} -> {:error, %{reason: reason}}
        _ -> :ok
      end
    else
      {:error, reason} -> {:error, %{reason: reason}}
    end
  end

  defp is_bot?(socket) do
    case socket.assigns do
      %{account: %{is_bot: true}} -> true
      _ -> false
    end
  end

  defp assert_bot(socket) do
    if is_bot?(socket), do: :ok, else: {:error, "not_a_bot"}
  end

  defp own_player?(socket, instance_id, player_id) do
    RC.Registrations.account_owns_player?(socket.assigns.account.id, instance_id, player_id)
  end

  defp iid(socket), do: socket.assigns.instance_id
  defp pid(socket), do: socket.assigns.player_id
end
