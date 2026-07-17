# Profiles a full instance boot of a large scenario (default: /data/bigone.json).
#
# Run inside the rc container while the stack is up:
#   docker compose exec rc mix run profile_galaxy_boot.exs
#
# Mirrors Daily.Boot.boot_persisted/2's create path: scenario row → instance →
# publish → one registration (admin@abc's profile) → Instance.Manager.
# create_from_model, which is where all the CPU goes and where the
# [boot-timing] phase logs come from. Destroys the supervision tree afterward
# so repeat runs don't accumulate 6.6k-process instances.

require Logger

path = System.get_env("SCENARIO_JSON", "/data/bigone.json")
raw = Jason.decode!(File.read!(path))
game_data = raw["game_data"]

n_systems = game_data["sectors"] |> Enum.map(&length(&1["systems"])) |> Enum.sum()
IO.puts("=== boot profile: #{length(game_data["sectors"])} sectors / #{n_systems} systems ===")

account = RC.Repo.get_by!(RC.Accounts.Account, email: "admin@abc")
profile = RC.Repo.get_by!(RC.Accounts.Profile, account_id: account.id)

{:ok, scenario} =
  %RC.Scenarios.Scenario{}
  |> RC.Scenarios.Scenario.changeset(%{
    game_data: game_data,
    game_metadata: raw["game_metadata"],
    is_map: false
  })
  |> RC.Repo.insert()

faction_attrs =
  Enum.map(game_data["factions"], fn f -> %{"key" => f["key"], "capacity" => 221} end)

instance_attrs = %{
  "name" => "boot-profile #{System.os_time(:second)}",
  "description" => "galaxy-generation CPU profiling",
  "opening_date" => DateTime.to_iso8601(DateTime.utc_now()),
  "registration_type" => "pre_registration",
  "game_type" => "private",
  "public" => false,
  "start_setting" => "auto",
  "factions" => faction_attrs
}

{:ok, %{instance: instance}} = RC.Instances.create_instance(instance_attrs, scenario, account.id)
{:ok, _} = RC.Instances.publish_instance(instance, account.id)

[faction | _] = instance.factions
{:ok, _} = RC.Registrations.register_profile(faction, profile)

loaded = RC.Instances.get_instance_with_registration(instance.id)

{us, result} = :timer.tc(fn -> Instance.Manager.create_from_model(loaded, nil) end)
IO.puts("=== TOTAL create_from_model: #{Float.round(us / 1_000_000, 2)} s → #{inspect(result)} ===")

# --- micro-benches against the live instance's agents/caches -----------------

iid = instance.id

bench = fn label, n, fun ->
  {us, _} = :timer.tc(fn -> Enum.each(1..n, fn _ -> fun.() end) end)
  IO.puts("#{label}: #{Float.round(us / 1000 / n, 3)} ms/call (n=#{n})")
end

sample_system = hd(hd(game_data["sectors"])["systems"])
sample_type = String.to_existing_atom(sample_system["type"])

bench.("rand round-trip (Game.call {:uniform, 50})", 500, fn ->
  Game.call(iid, :rand, :master, {:uniform, 50})
end)

bench.("Data.Picker.random \"place\"", 200, fn ->
  Data.Picker.random("place", iid)
end)

bench.("Data.Querier.one Constant", 500, fn ->
  Data.Querier.one(Data.Game.Constant, iid, :main)
end)

bench.("Data.Querier.one StellarSystem #{sample_type}", 500, fn ->
  Data.Querier.one(Data.Game.StellarSystem, iid, sample_type)
end)

bench.("StellarSystem.new serial", 100, fn ->
  Instance.StellarSystem.StellarSystem.new(sample_system, 1, iid)
end)

# Same benches with the instance flipped to the :shared (persistent_term,
# zero-copy) content cache — isolates the :legacy registry-copy tax.
try do
  IO.puts("--- switching instance to :shared data_memory_mode ---")
  Data.Data.switch_memory_mode(iid, :shared)

  bench.("Data.Querier.one Constant [shared]", 500, fn ->
    Data.Querier.one(Data.Game.Constant, iid, :main)
  end)

  bench.("Data.Querier.one StellarSystem #{sample_type} [shared]", 500, fn ->
    Data.Querier.one(Data.Game.StellarSystem, iid, sample_type)
  end)

  bench.("StellarSystem.new serial [shared]", 100, fn ->
    Instance.StellarSystem.StellarSystem.new(sample_system, 1, iid)
  end)
rescue
  e -> IO.puts("[shared-mode bench failed: #{Exception.message(e)}]")
end

# --- teardown ----------------------------------------------------------------

Instance.Manager.destroy(iid)
IO.puts("destroyed instance #{iid}")
