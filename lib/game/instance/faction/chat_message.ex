defmodule Instance.Faction.ChatMessage do
  use TypedStruct
  use Util.MakeEnumerable

  alias Instance.Faction

  # Chat channels (the tabs of the in-game chat). Kept as strings, never
  # atoms: messages are snapshotted with the faction, and the channel of
  # an incoming message is client-supplied.
  @channels ~w(general claims spotted aid ask)
  @default_channel "general"

  def channels(), do: @channels
  def default_channel(), do: @default_channel

  def jason(), do: []

  typedstruct enforce: true do
    # Per-faction sequence number (Faction.chat_seq). Lets the client key
    # rows, count unread per channel and jump to a given message. Rings
    # restored from a pre-channel snapshot are numbered by
    # Faction.ensure_chat_fields/1.
    #
    # `id`, `channel` and `meta` came after the rest: defaulted rather
    # than enforced, like the snapshots that lack them.
    field(:id, integer(), default: 0)
    field(:from, String.t())
    # `from_id` is the sender's profile_id (cross-game stable identity),
    # carried so the client can apply per-account chat mutes by id
    # instead of by display name — names can collide and change.
    field(:from_id, integer() | nil)
    field(:timestamp, integer())
    field(:channel, String.t(), default: @default_channel)
    field(:message, String.t())
    # Server-authored context for posts the game makes on a player's
    # behalf (never client-supplied), string keys only:
    #   %{"kind" => "claim", "system_id" => id}
    #   %{"kind" => "sighting", "sighting_id" => id}
    field(:meta, map() | nil, default: nil)
  end

  # `from` is server-derived from the JWT-bound player_id (see Faction.Agent
  # `on_cast({:push_message, ...})`), but cap its length defensively. Stage 4
  # #M1 noted that the chat ring is rebroadcast in full to every faction
  # member on every push, so an unbounded `from` would amplify bandwidth.
  #
  # `id` stays 0 here: the faction stamps the real sequence number when
  # the message enters the ring (Faction.append_chat_message/2).
  def new(from, from_id, message, opts \\ []) do
    %Faction.ChatMessage{
      id: 0,
      from: String.slice(from || "", 0..64),
      from_id: from_id,
      timestamp: :os.system_time(:seconds),
      channel: normalize_channel(Keyword.get(opts, :channel, @default_channel)),
      message: String.slice(message, 0..1_000),
      meta: Keyword.get(opts, :meta)
    }
  end

  def valid_channel?(channel), do: channel in @channels

  def normalize_channel(channel) when channel in @channels, do: channel
  def normalize_channel(_channel), do: @default_channel
end
