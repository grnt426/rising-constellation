defmodule RC.BotMonitoring.Event do
  @moduledoc """
  A single observation about a stress-test bot — either an action the bot
  took (captured server-side in channel handlers) or a lifecycle event
  the bot reported about itself.

  Powers the `/admin/bots` dashboard. Never written for real (non-bot)
  accounts.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @event_types ~w(action lifecycle transport)
  @statuses ~w(ok error info)
  @channels ~w(player cheat lifecycle transport)

  schema "bot_events" do
    field :event_type, :string
    field :event_name, :string
    field :channel, :string
    field :status, :string
    field :reason, :string
    field :duration_ms, :integer

    belongs_to :account, RC.Accounts.Account
    belongs_to :profile, RC.Accounts.Profile
    belongs_to :instance, RC.Instances.Instance

    timestamps(updated_at: false, type: :utc_datetime_usec)
  end

  @doc false
  def changeset(event, attrs) do
    event
    |> cast(attrs, [
      :account_id,
      :profile_id,
      :instance_id,
      :event_type,
      :event_name,
      :channel,
      :status,
      :reason,
      :duration_ms
    ])
    |> validate_required([:event_type, :event_name, :channel, :status])
    |> validate_inclusion(:event_type, @event_types)
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:channel, @channels)
    |> validate_length(:event_name, max: 64)
    |> validate_length(:reason, max: 256)
  end
end
