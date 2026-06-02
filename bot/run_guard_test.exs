# Smoke-test the host guard.
#
# - Without sentinel: start_link succeeds (returns {:ok, _}).
# - With sentinel: start_link returns :ignore + logs the refusal.
# - With sentinel + override env: start_link succeeds again.

require Logger

run = fn label, expect ->
  result = RcBot.Orchestrator.start_link([])

  Logger.info("[#{label}] result=#{inspect(result)} (expected #{inspect(expect)})")

  case result do
    {:ok, pid} ->
      :ok = GenServer.stop(pid)
      result

    other ->
      other
  end
end

# Case 1: clean machine, no sentinel.
sentinel = "/etc/rc/secret.json"
File.rm_rf(sentinel)
run.("no sentinel", :ok_ish)

# Case 2: sentinel present (simulate prod host).
:ok = File.mkdir_p("/etc/rc")
File.write!(sentinel, "{}")

System.delete_env("RC_BOT_FORCE_RUN")
run.("sentinel present, no override", :ignore)

# Case 3: sentinel present + override env.
System.put_env("RC_BOT_FORCE_RUN", "1")
run.("sentinel present, override set", :ok_ish)

# Cleanup
File.rm_rf(sentinel)
System.delete_env("RC_BOT_FORCE_RUN")
