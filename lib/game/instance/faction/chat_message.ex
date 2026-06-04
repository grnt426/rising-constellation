defmodule Instance.Faction.ChatMessage do
  use TypedStruct
  use Util.MakeEnumerable

  alias Instance.Faction

  def jason(), do: []

  typedstruct enforce: true do
    field(:from, String.t())
    # `from_id` is the sender's profile_id (cross-game stable identity),
    # carried so the client can apply per-account chat mutes by id
    # instead of by display name — names can collide and change. Old
    # in-memory rings written before this field existed don't survive
    # an agent restart (chat is in-memory only), so no migration needed.
    field(:from_id, integer() | nil)
    field(:timestamp, integer())
    field(:message, String.t())
  end

  # `from` is server-derived from the JWT-bound player_id (see Faction.Agent
  # `on_cast({:push_message, ...})`), but cap its length defensively. Stage 4
  # #M1 noted that the chat ring is rebroadcast in full to every faction
  # member on every push, so an unbounded `from` would amplify bandwidth.
  def new(from, from_id, message) do
    %Faction.ChatMessage{
      from: String.slice(from || "", 0..64),
      from_id: from_id,
      timestamp: :os.system_time(:seconds),
      message: String.slice(message, 0..1_000)
    }
  end
end
