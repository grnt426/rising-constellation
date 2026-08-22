defmodule RC.Discord.DailyChallengeBlast do
  @moduledoc """
  Scheduler for the once-a-day daily-challenge blast: congratulate the
  top 3 of the day that just ended and preview the newly-active
  challenge, in every configured news channel (community #game-news
  and, if distinct, the match-feed channel).

  Dailies rotate at 07:00 UTC (`Daily.today/0`). A run started just
  before the boundary still has its 30-minute clock to finish, plus
  the per-minute autosave lag — so the blast waits until 45 minutes
  past rotation (07:45 UTC) before treating the ended day's
  leaderboard as final.

  Every minute:

    1. Compute the ended date (`Daily.today/0` minus one day). Before
       its blast slot (07:45 UTC): do nothing.
    2. If `discord_daily_blasts` has no latch row for that date, post
       the blast to every configured news channel, then insert the
       latch. The latch only writes after at least one channel
       accepted the message, so a Discord outage retries next minute;
       the unique index makes duplicates impossible even so.

  Winners render as in-game name plus Discord display name when the
  account is linked — plain text, never a `<@id>` mention, so nobody
  gets pinged. The next-challenge preview reuses the objective and
  mutator copy the daily page itself serves.

  Runs only under `RC.Discord`'s supervisor (bot configured), and even
  then ignores itself in :test. A server that was down over a rotation
  simply blasts the most recently ended day once it's back — older
  missed days stay silent (stale congrats are noise).
  """

  use GenServer

  require Logger
  import Ecto.Query

  alias Nostrum.Api.Guild, as: NostrumGuild
  alias RC.Accounts.Account
  alias RC.Accounts.Profile
  alias RC.Discord.DailyBlastLog
  alias RC.Repo

  @tick_ms 60_000
  # Wait before the first tick so we don't compete with boot-time work.
  @initial_delay_ms 45_000
  # Minutes past the 07:00 UTC rotation before the ended day's board is
  # treated as final (last runs finalize ~30 min after rotation, plus
  # autosave slack).
  @post_delay_min 45

  @medals %{1 => "🥇", 2 => "🥈", 3 => "🥉"}

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

  # --- Scheduling (pure parts public for tests) ------------------------

  @doc """
  When the blast for `ended_date` goes out: #{@post_delay_min} minutes
  past the rotation that closed it (i.e. the next calendar day at
  07:#{@post_delay_min} UTC).
  """
  def due_at(%Date{} = ended_date) do
    ended_date
    |> Date.add(1)
    |> DateTime.new!(Time.new!(Daily.rotation_hour_utc(), @post_delay_min, 0), "Etc/UTC")
  end

  defp sweep do
    now = DateTime.utc_now()
    ended_date = Date.add(Daily.today(now), -1)
    ended_iso = Date.to_iso8601(ended_date)

    with true <- DateTime.compare(now, due_at(ended_date)) != :lt,
         false <- posted?(ended_iso),
         [_ | _] = channels <- configured_channels() do
      post_blast(ended_iso, channels)
    else
      _ -> :ok
    end
  rescue
    e ->
      Logger.warning("[RC.Discord.DailyChallengeBlast] sweep failed: #{Exception.message(e)}")
  end

  defp posted?(ended_iso),
    do: Repo.exists?(from(l in DailyBlastLog, where: l.date == ^ended_iso))

  defp configured_channels do
    [RC.Discord.news_channel_id(), RC.Discord.community_game_news_channel_id()]
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp post_blast(ended_iso, channels) do
    ended_definition = Daily.definition_for(ended_iso)
    next_definition = Daily.definition_for(Daily.today())

    winners =
      ended_iso
      |> Daily.leaderboard(3)
      |> Enum.map(&Map.put(&1, :discord_name, discord_name(&1.profile_id)))

    content =
      render_blast(
        ended_iso,
        ended_definition.objective,
        winners,
        next_definition.objective,
        next_definition.mutators
      )

    message_opts = blast_message(ended_iso, ended_definition, winners, next_definition, content)

    results =
      Enum.map(channels, fn channel_id ->
        case RC.Discord.Render.create_or_fallback(channel_id, message_opts, %{content: content}) do
          {:ok, _msg} ->
            :ok

          {:error, reason} ->
            Logger.warning(
              "[RC.Discord.DailyChallengeBlast] post failed (channel #{channel_id}): " <>
                inspect(reason)
            )

            :error
        end
      end)

    if :ok in results do
      case %DailyBlastLog{} |> DailyBlastLog.changeset(%{date: ended_iso}) |> Repo.insert() do
        {:ok, _} ->
          Logger.warning(
            "[RC.Discord.DailyChallengeBlast] posted blast for #{ended_iso} " <>
              "(#{length(winners)} winners, #{length(results)} channels)"
          )

        {:error, changeset} ->
          # Unique-index race can't happen (single process); a DB blip
          # here means one duplicate blast when it recovers, same
          # trade-off the daily bulletin makes.
          Logger.error(
            "[RC.Discord.DailyChallengeBlast] posted #{ended_iso} but could not latch: " <>
              inspect(changeset.errors)
          )
      end
    end
  end

  # Podium card when there are winners and the rasterizer is up; the
  # text blast otherwise (it stays as the caption either way, so the
  # results remain searchable and readable on image-less clients).
  defp blast_message(_ended_iso, _ended_definition, [], _next_definition, content), do: %{content: content}

  defp blast_message(ended_iso, ended_definition, winners, next_definition, content) do
    data = %{
      date: ended_iso,
      challenge_name: ended_definition.objective.name,
      winners:
        Enum.map(winners, fn w ->
          %{rank: w.rank, name: to_string(w.name), score: format_score(ended_definition.objective, w.score)}
        end),
      next: %{
        name: next_definition.objective.name,
        description: next_definition.objective.description,
        mutators: Enum.map(next_definition.mutators, &%{polarity: &1.polarity, name: &1.name})
      }
    }

    case RC.Discord.Render.rasterize(RC.Discord.Render.Cards.daily(data)) do
      {:ok, png} ->
        RC.Discord.Render.image_message(content, png, "daily.png")

      error ->
        Logger.info("[RC.Discord.DailyChallengeBlast] image blast unavailable (#{inspect(error)}); posting text")
        %{content: content}
    end
  rescue
    e ->
      Logger.warning("[RC.Discord.DailyChallengeBlast] image blast crashed: #{inspect(e)}")
      %{content: content}
  end

  # --- Rendering (pure, unit-tested without the bot) -------------------

  @doc """
  Render the blast message. `winners` are `Daily.leaderboard/2` rows
  (top 3) each with a `:discord_name` (string or nil); the objectives
  and mutators come from `Daily.definition_for/1` for the ended and
  the newly-active dates.
  """
  def render_blast(ended_iso, ended_objective, winners, next_objective, next_mutators) do
    header = "**Daily Challenge — #{ended_iso}#{objective_suffix(ended_objective)}**"

    winner_lines =
      case winners do
        [] ->
          ["No champions this time — the challenge went unclaimed."]

        winners ->
          Enum.map(winners, fn w ->
            "#{Map.get(@medals, w.rank, "•")} #{winner_name(w)} — #{format_score(ended_objective, w.score)}"
          end)
      end

    Enum.join([header] ++ winner_lines ++ next_lines(next_objective, next_mutators), "\n")
  end

  defp objective_suffix(%{name: name}), do: ": #{name}"
  defp objective_suffix(_), do: ""

  # In-game name, plus the linked Discord display name in parentheses.
  # Plain text on purpose — a <@id> mention would ping.
  defp winner_name(%{name: name, discord_name: discord_name}) when is_binary(discord_name),
    do: "#{name} (#{discord_name})"

  defp winner_name(%{name: name}), do: to_string(name)

  defp next_lines(nil, _mutators), do: []

  defp next_lines(objective, mutators) do
    mutator_line =
      case mutators || [] do
        [] ->
          []

        mutators ->
          ["Mutators: " <> Enum.map_join(mutators, ", ", &mutator_label/1)]
      end

    ["Up next: **#{objective.name}** — #{objective.description}"] ++ mutator_line
  end

  defp mutator_label(%{name: name, polarity: :negative}), do: "−#{name}"
  defp mutator_label(%{name: name}), do: "+#{name}"
  defp mutator_label(_), do: "?"

  # Race scores are "seconds left on the clock"; everything else is a
  # resource total/rate.
  defp format_score(%{mode: :race}, score) when is_number(score) and score > 0,
    do: "#{format_number(score)}s to spare"

  defp format_score(%{mode: :race}, _score), do: "closest to the goal"

  defp format_score(_objective, score) when is_number(score), do: format_number(score)
  defp format_score(_objective, score), do: to_string(score)

  defp format_number(n) when is_number(n) do
    n
    |> trunc()
    |> Integer.to_string()
    |> String.replace(~r/(?<=\d)(?=(\d{3})+$)/, ",")
  end

  # --- Discord identity ------------------------------------------------

  # profile → account → discord_id → member display name. Any miss
  # (unlinked, left the guilds, API blip) degrades to nil — the blast
  # then shows the in-game name alone.
  defp discord_name(profile_id) do
    with discord_id when not is_nil(discord_id) <- discord_id_for_profile(profile_id),
         name when is_binary(name) <- member_display_name(discord_id) do
      name
    else
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp discord_id_for_profile(profile_id) do
    from(p in Profile,
      join: a in Account,
      on: a.id == p.account_id,
      where: p.id == ^profile_id,
      select: a.discord_id
    )
    |> Repo.one()
  end

  defp member_display_name(discord_id) do
    user_id = String.to_integer(to_string(discord_id))

    with guild_id when not is_nil(guild_id) <- RC.Discord.community_guild_id(),
         {:ok, member} <- NostrumGuild.member(guild_id, user_id) do
      user = Map.get(member, :user) || %{}
      Map.get(member, :nick) || Map.get(user, :global_name) || Map.get(user, :username)
    else
      _ -> nil
    end
  end
end
