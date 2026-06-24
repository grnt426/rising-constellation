if is_nil(System.get_env("SPEEDUP")) do
  ExUnit.start(exclude: [:replays, :mem_bench])
else
  ExUnit.start(exclude: [:test, :mem_bench], include: [:replays])
end

:ok = Ecto.Adapters.SQL.Sandbox.checkout(RC.Repo)
