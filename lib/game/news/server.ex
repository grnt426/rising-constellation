defmodule Game.News.Server do
  @moduledoc """
  Per-instance GenServer that consumes raw `Game.News.emit/3` messages
  off PubSub and decides whether each one becomes a news bulletin.

  Responsibilities:

    * **Eligibility gate** — drops every message in fast-speed and
      tutorial instances. The check is performed once on first use
      and cached.
    * **Firsts** — for `"<category>.first"` keys, atomically claims
      the first via `RC.InstanceFirsts.claim/1` and only emits if
      this caller was actually first.
    * **Dedup window** — within a 5-minute window, suppresses
      additional emissions keyed by
      `{event_kind, actor_faction_id, location_id}` so a flood of
      similar actions (e.g. queued multi-agent assassinations) shows
      up as one bulletin instead of ten.
    * **Persistence** — successful news rows are written to
      `PlayerEvent` as global rows (no registration/faction FK) with
      the rendered payload in `data`. The frontend renderer picks
      the visibility-tier template by viewer identity.

  ## Resilience

  This server keeps only ephemeral dedup state. If it crashes, the
  supervisor restarts it with an empty dedup map; the worst case is
  a duplicate bulletin within the 5-minute window. We deliberately
  do NOT participate in the Core.GenState snapshot pipeline — the
  dedup window is not worth replaying.
  """

  use GenServer

  require Logger

  alias RC.PlayerEvents
  alias RC.InstanceFirsts

  # Dedup window for similar events. Matches the design call: queued
  # multi-agent actions can arrive over a few minutes and shouldn't
  # spam the ticker.
  @dedup_window_ms 5 * 60 * 1000

  defstruct [
    :instance_id,
    # :unknown | :eligible | :ineligible — resolved on first message,
    # then cached for the server lifetime.
    eligibility: :unknown,
    # %{dedup_key => expires_at_monotonic_ms}
    dedup: %{},
    # Count of events suppressed by the dedup window, per key. Used to
    # decide whether to emit a "summary" bulletin at window expiry.
    dedup_counts: %{}
  ]

  ## Client API

  def start_link(opts) do
    instance_id = Keyword.fetch!(opts, :instance_id)

    GenServer.start_link(
      __MODULE__,
      instance_id,
      name: Game.via_tuple({instance_id, :news_server})
    )
  end

  ## Callbacks

  @impl true
  def init(instance_id) do
    Phoenix.PubSub.subscribe(RC.PubSub, Game.News.topic(instance_id))
    state = %__MODULE__{instance_id: instance_id}
    {:ok, state}
  end

  @impl true
  def handle_info({:news_emit, key, payload}, %__MODULE__{} = state) do
    state =
      state
      |> resolve_eligibility()
      |> maybe_handle(key, payload)

    {:noreply, state}
  end

  # No-op for TickServer lifecycle calls if they ever leak through.
  def handle_info(_msg, state), do: {:noreply, state}

  ## Internals

  defp resolve_eligibility(%{eligibility: :unknown, instance_id: iid} = state) do
    eligibility =
      cond do
        eligible_speed?(iid) and not tutorial?(iid) -> :eligible
        true -> :ineligible
      end

    %{state | eligibility: eligibility}
  end

  defp resolve_eligibility(state), do: state

  defp eligible_speed?(instance_id) do
    case Data.Data.get(instance_id, :metadata) do
      nil -> false
      metadata -> Keyword.get(metadata, :speed) != :fast
    end
  rescue
    # If the metadata cache isn't ready (instance not yet
    # initialised), treat as ineligible — the first emit will resolve
    # to :ineligible and we'll re-evaluate on a future emit by
    # short-circuiting only if we actually got a verdict.
    _ -> false
  end

  defp tutorial?(instance_id) do
    # Galaxy.Agent's :get_state reply is `{:ok, state.data}` — i.e.
    # `galaxy` here is already the Galaxy struct, not the agent
    # wrapper. is_tutorial/1 reads its `:tutorial_id` field.
    case Game.call(instance_id, :galaxy, :master, :get_state, 1, 500) do
      {:ok, galaxy} -> Instance.Galaxy.Galaxy.is_tutorial(galaxy)
      _ -> false
    end
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  defp maybe_handle(%{eligibility: :ineligible} = state, _key, _payload), do: state

  defp maybe_handle(%{eligibility: :eligible} = state, key, payload) do
    state = expire_dedup(state)

    cond do
      first_key?(key) ->
        handle_first(state, key, payload)

      dedup_key = dedup_key_for(key, payload) ->
        handle_dedup(state, key, payload, dedup_key)

      true ->
        persist(state, key, payload)
        state
    end
  end

  # "X.first" keys go through the firsts table.
  defp first_key?(key), do: String.ends_with?(key, ".first")

  defp handle_first(state, key, payload) do
    attrs = %{
      first_key: key,
      instance_id: state.instance_id,
      winning_faction_id: payload[:winning_faction_id] || payload["winning_faction_id"],
      winning_registration_id: payload[:winning_registration_id] || payload["winning_registration_id"]
    }

    case InstanceFirsts.claim(attrs) do
      {:ok, _first} ->
        persist(state, key, payload)
        state

      {:already_claimed, _existing} ->
        # Not first — silently drop.
        state

      {:error, reason} ->
        Logger.warning("Game.News.Server first-claim insert failed",
          instance_id: state.instance_id,
          first_key: key,
          reason: inspect(reason)
        )

        state
    end
  end

  # Build a dedup key for floods of similar events. For the seed PR no
  # non-first event types are wired up yet; this returns nil so the
  # event falls through to direct persistence. As we instrument more
  # event types (battles, assassinations) we'll add cases here.
  defp dedup_key_for(_key, _payload), do: nil

  defp handle_dedup(state, key, payload, dedup_key) do
    now = System.monotonic_time(:millisecond)

    case Map.fetch(state.dedup, dedup_key) do
      :error ->
        # First time we've seen this key in the window — emit and arm.
        persist(state, key, payload)
        %{state | dedup: Map.put(state.dedup, dedup_key, now + @dedup_window_ms)}

      {:ok, _expires_at} ->
        # Inside the window — suppress, bump the counter for the
        # eventual summary emission (TODO: emit summary at expiry).
        counts = Map.update(state.dedup_counts, dedup_key, 1, &(&1 + 1))
        %{state | dedup_counts: counts}
    end
  end

  defp expire_dedup(state) do
    now = System.monotonic_time(:millisecond)
    {alive, _expired} = Enum.split_with(state.dedup, fn {_k, exp} -> exp > now end)
    %{state | dedup: Map.new(alive)}
  end

  defp persist(state, key, payload) do
    PlayerEvents.create(%{
      type: "global",
      key: "news." <> key,
      data: Jason.encode!(payload),
      instance_id: state.instance_id
    })
  end
end
