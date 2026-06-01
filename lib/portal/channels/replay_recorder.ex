defmodule Portal.ReplayRecorder do
  require Logger

  defmacro __using__(_opts) do
    quote do
      require Logger
      import Portal.ReplayRecorder
    end
  end

  # Stage 4 #H7 + #I1 hardening.
  #
  # 1. The Task body is wrapped in try/rescue/catch so any raise from the
  #    handler — String.to_existing_atom on a bad atom, MatchError on a
  #    bad payload, etc. — still produces a `reply(ref, {:error, ...})`
  #    push to the client and a structured server-side log entry.
  #    Previously a crash silently stalled the client and left no DB row.
  #
  # 2. `record_action` skips persistence when `result` is `{:error, _}`
  #    (any tuple beginning with the `:error` atom). The query layer
  #    already filters error rows out of replay playback
  #    (`RC.Replays.admin_filter/1`), so writing them only adds DB load
  #    that an attacker can leverage for pool-saturation DoS.
  defmacro record(msg, params, socket, do: block) do
    quote do
      def unquote(:handle_in)(unquote(msg), unquote(params), unquote(socket)) do
        hyg_socket = unquote(socket)
        ref = socket_ref(hyg_socket)

        # Stage 7 F25: dispatch under RC.TaskSupervisor so the task
        # is supervised + observable rather than an orphan `Task.start`.
        Task.Supervisor.start_child(
          RC.TaskSupervisor,
          fn ->
            {duration, result} =
              try do
                :timer.tc(fn -> unquote(block) end)
              rescue
                e ->
                  Logger.error(
                    "handle_in #{inspect(unquote(msg))} crashed: #{Exception.message(e)}",
                    channel: hyg_socket.assigns[:channel_name],
                    instance_id: hyg_socket.assigns[:instance_id],
                    player_id: hyg_socket.assigns[:player_id]
                  )

                  {0, {:error, %{reason: :internal_error}}}
              catch
                kind, value ->
                  Logger.error(
                    "handle_in #{inspect(unquote(msg))} threw #{kind}: #{inspect(value)}",
                    channel: hyg_socket.assigns[:channel_name],
                    instance_id: hyg_socket.assigns[:instance_id],
                    player_id: hyg_socket.assigns[:player_id]
                  )

                  {0, {:error, %{reason: :internal_error}}}
              end

            record_action(unquote(msg), unquote(params), unquote(socket), result, duration)
            reply(ref, result)
          end,
          restart: :temporary
        )

        {:noreply, hyg_socket}
      end
    end
  end

  def record_action(
        msg,
        params,
        %{assigns: %{player_id: player_id, instance_id: instance_id, channel_name: channel, has_replay: true}},
        result,
        duration
      ) do
    if should_record_result?(result) do
      # Stage 7 F25: supervised under RC.TaskSupervisor. The previous
      # raw `spawn/1` left orphan PIDs whose crashes (e.g. DB
      # connection refused) disappeared into the void.
      Task.Supervisor.start_child(
        RC.TaskSupervisor,
        fn ->
          case RC.Replays.create_replay(%{
                 instance_id: instance_id,
                 msg: msg,
                 params: params,
                 channel: channel,
                 profile_id: player_id,
                 timestamp: DateTime.utc_now(),
                 result: inspect(result),
                 duration: duration
               }) do
            {:error, %Ecto.Changeset{errors: errors}} ->
              Logger.error("replay insert error #{inspect(errors)}", instance_id: instance_id)

            _ ->
              nil
          end
        end,
        restart: :temporary
      )
    end
  end

  def record_action(_msg, _params, _socket, _result, _duration),
    do: nil

  # Skip persistence for handler-level errors. They are filtered out at
  # query time anyway (`RC.Replays.admin_filter/1`), so the writes are
  # pure DB load — a DoS amplifier for an attacker spamming bad payloads.
  defp should_record_result?({:error, _}), do: false
  defp should_record_result?(_), do: true
end
