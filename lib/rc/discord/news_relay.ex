defmodule RC.Discord.NewsRelay do
  @moduledoc """
  GenServer that owns all posting of Game.News bulletins to the #news
  channel — and with it, Discord's OWN dedup policy.

  ## Publisher-owned dedup

  Game.News.Server no longer decides flood behavior for Discord. Every
  battle event reaches this relay individually; the web surfaces keep
  their suppress-and-summarize window inside News.Server. Here:

    * **Battles roll up by editing.** The first battle posts a normal
      line. Any further battle arriving less than 5 minutes after this
      relay's last battle post/update EDITS that message into an
      aggregated per-sector tally ("Fleet engagements reported:
      sector Nubrae ×3, …") instead of posting again. The window is
      rolling — sustained fighting keeps updating one message, which
      is exactly the anti-flood behavior a chat channel wants.
    * **Everything else posts one message per bulletin** (bulletins
      are already rare: firsts, conquests, sector flips…).

  Battles are the only rolled-up kind for now: fleets can't convoy
  yet, so engagements arrive in quick succession. The pattern
  generalizes if other kinds ever need per-publisher dedup.

  ## Lifecycle

  Runs only under `RC.Discord`'s supervisor, i.e. only when the bot is
  configured and connected. `RC.Discord.News.post_async/3` casts here;
  a cast to the unregistered name (bot off, :test) is a silent no-op
  by GenServer semantics. Roll-up state is in-memory only — a restart
  simply starts a fresh message, never loses news.
  """

  use GenServer

  require Logger

  alias Nostrum.Api.Message
  alias RC.Discord.News

  # Rolling window: a battle arriving within this of the last battle
  # post/update edits that message instead of posting a new one.
  @rollup_window_ms 5 * 60 * 1000

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    # %{instance_id => %{msg_id, channel_id, counts: %{sector => n}, last_at}}
    {:ok, %{battles: %{}}}
  end

  @impl true
  def handle_cast({:bulletin, instance_id, bulletin_key, payload}, state) do
    state =
      with channel_id when not is_nil(channel_id) <- RC.Discord.news_channel_id(),
           %{discord_ready: true, name: instance_name} <- RC.Instances.get_instance(instance_id) do
        dispatch(state, instance_id, channel_id, instance_name, bulletin_key, payload)
      else
        # Channel unset or instance missing / not discord_ready.
        _ -> state
      end

    {:noreply, state}
  rescue
    e ->
      Logger.warning("[RC.Discord.NewsRelay] bulletin handling crashed: #{inspect(e)}")
      {:noreply, state}
  end

  ## Battle roll-up

  defp dispatch(state, instance_id, channel_id, instance_name, "news.battle", payload) do
    sector = payload[:sector_name] || "an uncharted region"
    now = System.monotonic_time(:millisecond)
    window = state.battles[instance_id]

    if window != nil and now - window.last_at < @rollup_window_ms do
      counts = Map.update(window.counts, sector, 1, &(&1 + 1))
      content = "📰 **#{instance_name}** — #{News.battle_rollup(counts)}"

      case Message.edit(window.channel_id, window.msg_id, %{content: content}) do
        {:ok, _} ->
          put_in(state.battles[instance_id], %{window | counts: counts, last_at: now})

        {:error, reason} ->
          # Message likely deleted by a moderator — fall back to a
          # fresh post carrying the full tally so nothing is lost.
          Logger.warning("[RC.Discord.NewsRelay] battle roll-up edit failed: #{inspect(reason)}")
          post_battle(state, instance_id, channel_id, instance_name, counts, now)
      end
    else
      post_battle(state, instance_id, channel_id, instance_name, %{sector => 1}, now)
    end
  end

  ## Everything else: one message per bulletin.

  defp dispatch(state, instance_id, channel_id, instance_name, bulletin_key, payload) do
    case News.render(bulletin_key, payload) do
      nil ->
        state

      headline ->
        create("📰 **#{instance_name}** — #{headline}", channel_id, instance_id)
        state
    end
  end

  defp post_battle(state, instance_id, channel_id, instance_name, counts, now) do
    content = "📰 **#{instance_name}** — #{News.battle_rollup(counts)}"

    case create(content, channel_id, instance_id) do
      {:ok, msg} ->
        window = %{msg_id: msg.id, channel_id: channel_id, counts: counts, last_at: now}
        put_in(state.battles[instance_id], window)

      _ ->
        # Post failed — drop the window so the next battle retries fresh.
        %{state | battles: Map.delete(state.battles, instance_id)}
    end
  end

  defp create(content, channel_id, instance_id) do
    case Message.create(channel_id, %{content: content}) do
      {:ok, _msg} = ok ->
        ok

      {:error, reason} ->
        Logger.warning(
          "[RC.Discord.NewsRelay] post failed (channel #{channel_id}, instance ##{instance_id}): " <>
            inspect(reason)
        )

        :error
    end
  end
end
