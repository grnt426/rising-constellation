# Start every run with an empty Waffle local-storage tree — ONCE, here.
# The per-test `on_exit rm_rf` cleanups this replaces deleted the SHARED
# storage root (or shared subtrees) mid-run and raced concurrent tests'
# writes under async max_cases (observed: GroupsTest dying in mkdir_p!
# while another file's exit callback removed the tree). Files written
# during one run are id-scoped and bounded; deleting them while the
# suite runs is what broke.
File.rm_rf(Path.join(File.cwd!(), Application.get_env(:waffle, :storage_dir)))

if is_nil(System.get_env("SPEEDUP")) do
  ExUnit.start(exclude: [:replays, :mem_bench, :gen_determinism])
else
  ExUnit.start(exclude: [:test, :mem_bench, :gen_determinism], include: [:replays])
end

:ok = Ecto.Adapters.SQL.Sandbox.checkout(RC.Repo)
