defmodule RC.Discord.DailyBulletin do
  @moduledoc """
  Scheduler for the once-a-day summary bulletin (`RC.Discord.Bulletin`
  holds the pure slot/rendering logic).

  Every minute, for each promoted live match (`discord_matches` row +
  instance `discord_ready` + state running):

    1. Compute today's seeded post slot (12:00-14:00 ET). Before it:
       do nothing. After it, if today's bulletin hasn't posted yet:
    2. Compute today's seeded cutoff slot (07:00-11:00 ET). Collect
       every accumulated `discord_bulletin_events` row up to the
       cutoff, plus `instance_firsts` claimed inside the window
       `(last summarized cutoff, today's cutoff]`.
    3. Post the bulletin to #news, then in ONE transaction delete the
       consumed rows and stamp `bulletin_last_posted_on` /
       `bulletin_cutoff_at`. A failed post leaves everything unstamped
       so the next tick retries; a failed transaction logs loudly (at
       worst one duplicate bulletin once the DB recovers — never a
       once-a-minute flood).

  The slot seed is `bulletin_salt`, a random per-match secret
  generated lazily on first sweep — stored, never derived, so weeks of
  observed post times can't be used to predict the hidden cutoff.

  Paused matches are skipped (no empty digests during an off-season
  pause); their events fold into the first bulletin after unpause via
  the cutoff high-water mark. Ended matches get their leftover
  accumulator rows pruned.

  Runs only under `RC.Discord`'s supervisor (bot configured), and even
  then ignores itself in :test.
  """

  use GenServer

  require Logger
  import Ecto.Query

  alias Nostrum.Api.Message
  alias RC.Discord.Bulletin
  alias RC.Discord.BulletinEvent
  alias RC.Discord.EasternTime
  alias RC.Discord.Match
  alias RC.Instances.Instance
  alias RC.Instances.InstanceFirst
  alias RC.Repo

  @tick_ms 60_000
  # Wait before the first tick so we don't compete with boot-time work.
  @initial_delay_ms 45_000

  def start_link(opts \\ []),
    do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    if Application.get_env(:rc, :environment) == :test do
      :ignore
    else
      schedule(@initial_delay_ms)
      {:ok, %{}}
    end
  end

  @doc "Force a sweep now (operator debugging from iex)."
  def run_now, do: GenServer.cast(__MODULE__, :run_now)

  @impl true
  def handle_info(:tick, state) do
    sweep()
    schedule(@tick_ms)
    {:noreply, state}
  end

  @impl true
  def handle_cast(:run_now, state) do
    sweep()
    {:noreply, state}
  end

  defp schedule(ms), do: Process.send_after(self(), :tick, ms)

  defp sweep do
    now = DateTime.utc_now()

    # Lean per-minute query: no preloads — the check needs only the
    # match row and the instance's state; the heavier render data
    # loads inside post_bulletin for the (rare) due match.
    from(m in Match,
      join: i in assoc(m, :instance),
      where: i.discord_ready == true,
      where: i.state == "running",
      preload: [instance: i]
    )
    |> Repo.all()
    |> Enum.each(&maybe_post(&1, now))

    prune_ended_matches()
  rescue
    e ->
      Logger.warning("[RC.Discord.DailyBulletin] sweep failed: #{Exception.message(e)}")
  end

  # A finished match never posts again, so its unconsumed accumulator
  # rows would otherwise linger forever. Prune them here (normally a
  # zero-row no-op).
  defp prune_ended_matches do
    from(e in BulletinEvent,
      join: i in Instance,
      on: i.id == e.instance_id,
      where: i.state == "ended"
    )
    |> Repo.delete_all()
  end

  defp maybe_post(%Match{} = match, now_utc) do
    match = ensure_salt(match)
    today = EasternTime.today()

    posted_today? =
      match.bulletin_last_posted_on != nil and
        Date.compare(match.bulletin_last_posted_on, today) != :lt

    due? = DateTime.compare(now_utc, Bulletin.post_time(today, match.bulletin_salt)) != :lt

    with false <- posted_today?,
         true <- due?,
         channel_id when not is_nil(channel_id) <- RC.Discord.news_channel_id() do
      cutoff_utc =
        today
        |> Bulletin.cutoff_time(match.bulletin_salt)
        |> EasternTime.to_utc()

      post_bulletin(match, channel_id, today, cutoff_utc)
    else
      _ -> :ok
    end
  rescue
    e ->
      Logger.warning(
        "[RC.Discord.DailyBulletin] bulletin for instance ##{match.instance_id} failed: " <>
          Exception.message(e)
      )
  end

  # The slot seed must be a stored random secret. Deriving it from
  # anything observable (timestamps) would let players reconstruct it
  # from weeks of public post times and predict the hidden cutoff.
  defp ensure_salt(%Match{bulletin_salt: salt} = match) when is_binary(salt), do: match

  defp ensure_salt(%Match{} = match) do
    salt = Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)

    {1, _} =
      Repo.update_all(from(m in Match, where: m.id == ^match.id, where: is_nil(m.bulletin_salt)),
        set: [bulletin_salt: salt]
      )

    %{match | bulletin_salt: salt}
  rescue
    # Lost a race with a concurrent sweep (can't happen — single
    # process — but cheap to be exact): re-read the winning salt.
    _ -> Repo.get!(Match, match.id)
  end

  defp post_bulletin(%Match{} = match, channel_id, today, cutoff_utc) do
    events =
      from(e in BulletinEvent,
        where: e.instance_id == ^match.instance_id,
        where: e.inserted_at <= ^cutoff_utc,
        order_by: e.inserted_at
      )
      |> Repo.all()

    window_start = match.bulletin_cutoff_at || match.inserted_at
    firsts = load_first_lines(match.instance_id, window_start, cutoff_utc)

    instance = Repo.preload(match.instance, [:factions])
    faction_count = length(instance.factions || [])
    instance_name = instance.name || "Game ##{match.instance_id}"

    content = Bulletin.render(instance_name, faction_count, events, firsts)

    case Message.create(channel_id, %{content: content}) do
      {:ok, _msg} ->
        consume_and_stamp(match, events, today, cutoff_utc)

      {:error, reason} ->
        # No stamp, no delete — the next tick retries with the same
        # window.
        Logger.warning(
          "[RC.Discord.DailyBulletin] post failed for instance ##{match.instance_id}: " <>
            inspect(reason)
        )
    end
  end

  # Delete exactly the rows that were rendered and stamp the latch in
  # one transaction. If this fails (DB blip right after a successful
  # post), the worst case is ONE duplicate bulletin when the DB
  # recovers — the alternative (ignoring the stamp result) re-posts
  # every minute for the rest of the day.
  defp consume_and_stamp(%Match{} = match, events, today, cutoff_utc) do
    ids = Enum.map(events, & &1.id)

    result =
      Repo.transaction(fn ->
        Repo.delete_all(from(e in BulletinEvent, where: e.id in ^ids))

        Repo.update_all(from(m in Match, where: m.id == ^match.id),
          set: [bulletin_last_posted_on: today, bulletin_cutoff_at: cutoff_utc]
        )
      end)

    case result do
      {:ok, _} ->
        Logger.warning(
          "[RC.Discord.DailyBulletin] posted bulletin for instance ##{match.instance_id} " <>
            "(#{length(ids)} events, cutoff #{cutoff_utc})"
        )

      {:error, reason} ->
        Logger.error(
          "[RC.Discord.DailyBulletin] posted for instance ##{match.instance_id} but could not " <>
            "stamp/consume (#{inspect(reason)}); a duplicate bulletin may follow when the DB recovers"
        )
    end
  end

  defp load_first_lines(instance_id, from_dt, to_dt) do
    # instance_firsts stamps at second precision; truncate the usec
    # bounds so Ecto can cast the params.
    from_dt = DateTime.truncate(from_dt, :second)
    to_dt = DateTime.truncate(to_dt, :second)

    from(f in InstanceFirst,
      where: f.instance_id == ^instance_id,
      where: f.inserted_at > ^from_dt,
      where: f.inserted_at <= ^to_dt,
      order_by: f.inserted_at,
      preload: [:winning_faction, winning_registration: :profile]
    )
    |> Repo.all()
    |> Enum.map(fn first ->
      who =
        case first.winning_registration do
          %{profile: %{name: name}} when is_binary(name) -> name
          _ -> nil
        end

      faction_ref =
        case first.winning_faction do
          %{faction_ref: ref} -> ref
          _ -> nil
        end

      Bulletin.first_line(first.first_key, who, faction_ref)
    end)
  end
end
