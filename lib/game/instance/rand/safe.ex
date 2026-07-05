defmodule Instance.Rand.Safe do
  @moduledoc """
  Rand-agent access with a local fallback and a process-local circuit
  breaker.

  The per-instance rand agent can be unreachable in two legitimate windows:
  registry lag during instance boot (worse under many simultaneous instance
  creations — the AI-training harness's normal load) and mid-restart after
  a crash. Both surface as `Game.call` error results, which callers used to
  feed into `Enum`/`.key`/arithmetic — crash-looping gameplay agents like
  the character market from inside `new/1`.

  The agent's operations are seeded versions of `Enum.random` /
  `Enum.take_random` (see `Instance.Rand.Agent` / `REnum`), so unseeded
  draws are semantically-faithful fallbacks for these rare windows.

  The circuit breaker (per calling process, per instance) exists because a
  single failed `Game.call` costs retry timeouts: bulk generation (a market
  filling ~dozens of characters, several rolls each) against a down agent
  would otherwise pay that cost hundreds of times.
  """

  @breaker_ms 1_000

  @doc "Seeded `Enum.random/1` via the rand agent, with unseeded fallback."
  def random(instance_id, enumerable) do
    call(instance_id, {:random, enumerable}, fn -> Enum.random(enumerable) end)
  end

  @doc "Seeded `Enum.take_random/2` via the rand agent, with unseeded fallback."
  def take_random(instance_id, enumerable, count) do
    call(instance_id, {:take_random, enumerable, count}, fn -> Enum.take_random(enumerable, count) end)
  end

  @doc "Seeded uniform float in [0.0, 1.0) via the rand agent, with unseeded fallback."
  def uniform(instance_id) do
    call(instance_id, {:uniform}, fn -> :rand.uniform() end)
  end

  @doc "Seeded uniform integer in 1..n via the rand agent, with unseeded fallback."
  def uniform(instance_id, n) do
    call(instance_id, {:uniform, n}, fn -> :rand.uniform(n) end)
  end

  defp call(instance_id, msg, fallback) do
    key = {:rand_breaker, instance_id}
    now = System.monotonic_time(:millisecond)

    if now < Process.get(key, 0) do
      fallback.()
    else
      case Game.call(instance_id, :rand, :master, msg) do
        :process_not_found ->
          trip(key, now, fallback)

        {:error, _} ->
          trip(key, now, fallback)

        result ->
          result
      end
    end
  end

  defp trip(key, now, fallback) do
    Process.put(key, now + @breaker_ms)
    fallback.()
  end
end
