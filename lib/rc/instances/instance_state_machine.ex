defmodule RC.Instances.InstanceStateMachine do
  alias RC.Instances

  use Machinery,
    states: ["created", "open", "running", "paused", "not_running", "ended", "maintenance"],
    transitions: %{
      "created" => ["open", "maintenance", "ended"],
      "open" => ["running", "maintenance", "ended"],
      "running" => ["paused", "not_running", "ended", "maintenance"],
      "paused" => ["running", "ended", "maintenance"],
      # not_running -> paused: boot restore of a game that was paused when the
      # node stopped. The status fixer demotes it to not_running, then
      # RC.Instances.restore_instance/2 reloads the snapshot without starting
      # the clock and moves it back to paused.
      "not_running" => ["running", "paused", "ended", "maintenance"],
      "maintenance" => ["created", "open", "running", "paused", "not_running", "ended"]
    }

  # without account id
  def log_transition(%Instances.Instance{account_id: account_id, id: instance_id} = _instance, next_state) do
    {:ok, %{instance: instance}} =
      Instances.create_instance_state(%{instance_id: instance_id, state: next_state}, account_id)

    instance
  end
end
