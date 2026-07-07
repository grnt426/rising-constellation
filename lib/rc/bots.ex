defmodule RC.Bots do
  @moduledoc """
  Bot opponents for live games.

  An instance created with `bot_faction` set has that faction played
  entirely by bots: humans can't join it (registration_controller rejects
  with :bot_faction_locked), and this module keeps its bot player count
  equal to the SMALLEST human faction (an instance with human factions of
  3 and 4 players fields 3 bots), capped by the faction's capacity.

  Bot players are real accounts/profiles/registrations from a shared pool
  (`arena-bot-N@tetrarchyfalls.local`), assigned deterministically: bot
  slot k of any instance is always pool profile k, which makes `balance/1`
  idempotent and lets a human unjoin shrink the bot side pre-start.

  Personalities come from `priv/bot_personalities.json` — the strongest
  marathon champions per faction, exported by
  `mix headless.export_personalities`. The pick is a stable hash of
  {instance_id, profile_id}, so a bot keeps its personality across server
  restarts without any schema.

  The drivers themselves (Headless.Bot processes running the Tunable
  policy) are started and kept alive by RC.Bots.Overseer.
  """

  import Ecto.Query

  alias RC.Accounts
  alias RC.Instances
  alias RC.Instances.Registration
  alias RC.Registrations
  alias RC.Repo

  require Logger

  @pack_path "bot_personalities.json"
  @pool_email_prefix "arena-bot-"

  ## Personalities

  @doc """
  The personality pack, cached in persistent_term keyed by the file's
  mtime — re-exporting the pack (mix headless.export_personalities) takes
  effect on the next lookup, no server restart needed. The stat per call
  is cheap; the expensive persistent_term write only happens on change.
  """
  def personalities do
    path = :rc |> Application.app_dir("priv") |> Path.join(@pack_path)

    mtime =
      case File.stat(path, time: :posix) do
        {:ok, %{mtime: t}} -> t
        _ -> 0
      end

    case :persistent_term.get({__MODULE__, :pack}, nil) do
      {^mtime, pack} ->
        pack

      _ ->
        pack =
          case File.read(path) do
            {:ok, json} -> Jason.decode!(json)["personalities"] || %{}
            _ -> %{}
          end

        :persistent_term.put({__MODULE__, :pack}, {mtime, pack})
        pack
    end
  end

  @doc """
  Deterministic personality for a bot player: stable across restarts,
  varied across bots. Falls back to the Tunable default when the pack has
  no champions for the faction.
  """
  def personality_for(instance_id, faction_ref, profile_id) do
    case Map.get(personalities(), to_string(faction_ref), []) do
      [] ->
        %{"name" => "Generalist", "genome" => Headless.Policies.Tunable.default()}

      champs ->
        Enum.at(champs, :erlang.phash2({instance_id, profile_id}, length(champs)))
    end
  end

  ## Balancing

  @doc """
  Reconcile the bot faction's player count with the smallest human
  faction. Adds bot registrations (and mid-game players, for running
  late-registration instances) when humans join; removes surplus bot
  registrations while the instance is still open. Idempotent; safe to call
  after every join/unjoin. No-op for instances without a bot faction.
  """
  def balance(%Instances.Instance{bot_faction: nil}), do: :ok

  def balance(%Instances.Instance{} = instance) do
    factions = Repo.all(from(f in Instances.Faction, where: f.instance_id == ^instance.id))

    case Enum.find(factions, &(&1.faction_ref == instance.bot_faction)) do
      nil ->
        Logger.error("bots: instance #{instance.id} bot_faction #{instance.bot_faction} has no faction row")
        :error

      bot_faction ->
        target =
          factions
          |> Enum.reject(&(&1.id == bot_faction.id))
          |> Enum.map(&Registrations.count_by_faction(&1.id))
          |> Enum.min(fn -> 0 end)
          |> min(bot_faction.capacity)

        reconcile(instance, bot_faction, target)
    end
  end

  defp reconcile(instance, bot_faction, target) do
    current =
      Repo.all(
        from(r in Registration,
          where: r.faction_id == ^bot_faction.id,
          join: p in assoc(r, :profile),
          preload: [profile: p]
        )
      )

    # Slot k <-> pool profile k: makes add/remove deterministic.
    wanted = if target > 0, do: pool_profiles(target), else: []
    wanted_ids = MapSet.new(wanted, & &1.id)
    current_ids = MapSet.new(current, & &1.profile_id)

    for profile <- wanted, profile.id not in current_ids do
      add_bot(instance, bot_faction, profile)
    end

    if instance.state == "open" do
      for reg <- current, reg.profile_id not in wanted_ids do
        Repo.delete(reg)
      end
    end

    :ok
  end

  defp add_bot(instance, faction, profile) do
    initial_state = if instance.state == "running", do: "playing", else: "joined"

    case Registrations.register_profile(faction, profile, initial_state) do
      {:ok, %{registration: registration}} ->
        # Mid-game join (late registration): spawn the player agent the
        # same way a human late-join does.
        if instance.state == "running" and Instance.Manager.created?(instance.id) do
          Instance.Manager.call(instance.id, {:add_player, faction, profile, registration.id})
        end

        :ok

      {:error, op, value, _} ->
        Logger.error("bots: failed adding bot to instance #{instance.id}: #{inspect(op)} #{inspect(value)}")
        :error
    end
  end

  ## Bot account pool

  @doc "The first `n` pool profiles, creating accounts/profiles as needed."
  def pool_profiles(n) when n > 0 do
    Enum.map(1..n, &pool_profile/1)
  end

  defp pool_profile(i) do
    email = "#{@pool_email_prefix}#{i}@tetrarchyfalls.local"

    account =
      case Accounts.get_account_by_email(email) do
        {:ok, account} ->
          account

        {:error, _} ->
          {:ok, account} =
            Accounts.create_account(%{
              email: email,
              password: "arena-" <> Base.url_encode64(:crypto.strong_rand_bytes(12)),
              name: "AI Player #{i}",
              role: :user,
              status: :active
            })

          mark_bot(account)
      end

    case Repo.get_by(Accounts.Profile, account_id: account.id) do
      nil ->
        {:ok, profile} = Accounts.create_profile(%{account_id: account.id, name: "AI Player #{i}", avatar: "bot"})
        profile

      profile ->
        profile
    end
  end

  # is_bot is admin-changeset-only by design; set it directly so bot
  # accounts are excluded from rankings/search like other bots.
  defp mark_bot(account) do
    account
    |> Ecto.Changeset.change(is_bot: true)
    |> Repo.update()
    |> case do
      {:ok, account} -> account
      _ -> account
    end
  end
end
