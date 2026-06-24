if is_nil(System.get_env("SPEEDUP")) do
  ExUnit.start(exclude: [:replays, :mem_bench, :gen_determinism])
else
  ExUnit.start(exclude: [:test, :mem_bench, :gen_determinism], include: [:replays])
end

:ok = Ecto.Adapters.SQL.Sandbox.checkout(RC.Repo)
