defmodule Instance.Faction.ChatMessage do
  use TypedStruct
  use Util.MakeEnumerable

  alias Instance.Faction

  def jason(), do: []

  typedstruct enforce: true do
    field(:from, String.t())
    field(:timestamp, integer())
    field(:message, String.t())
  end

  # `from` is server-derived from the JWT-bound player_id (see Faction.Agent
  # `on_cast({:push_message, ...})`), but cap its length defensively. Stage 4
  # #M1 noted that the chat ring is rebroadcast in full to every faction
  # member on every push, so an unbounded `from` would amplify bandwidth.
  def new(from, message) do
    %Faction.ChatMessage{
      from: String.slice(from || "", 0..64),
      timestamp: :os.system_time(:seconds),
      message: String.slice(message, 0..1_000)
    }
  end
end
