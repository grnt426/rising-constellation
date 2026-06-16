defmodule Instance.Contracts.Contract do
  @moduledoc """
  A single Agent Contract (a "Broker" deal): an escrow + manual two-sided-closure
  agreement between a **payer** (the issuer who posts a bounty) and a **performer**
  (the claimant who takes it on) for some agent service.

  This module is PURE. It holds no process state and never touches the DB, the
  `Data.Querier`, or other agents. The owning `Instance.Contracts.Agent` decides
  *when* to finalize a contract — when both parties have submitted a closure
  (`ready_to_resolve?/1`) or the deadline has passed (`expired?/2`) — and is
  responsible for actually moving credits and bumping strikes from the effects
  returned by `resolve/1`.

  The game never verifies that the contracted action actually happened; the players
  close contracts themselves ("the Brokers aren't judges"). All `action_*`/`target_*`
  fields are descriptive only. The single mechanically-enforced term is the
  `action_category`, which gates *creation* (the issuer must own that agent type) and
  drives the UI.
  """
  use TypedStruct

  @categories [:spy, :speaker, :admiral]
  @payer_closures [:pay, :terminate, :dispute]
  @performer_closures [:claim, :withdraw, :dispute]
  @terminal_statuses [:paid, :refunded, :disputed]

  @closure_intents %{
    "pay" => :pay,
    "terminate" => :terminate,
    "dispute" => :dispute,
    "claim" => :claim,
    "withdraw" => :withdraw
  }

  # Broker fee schedule. Both components scale with the SUM of the two parties'
  # permanent dispute strikes and are netted out of the bounty at payout — never
  # reserved up front, never charged on a refund/dispute. The per-component caps
  # keep the performer's payout floor at `bounty * (1 - listing_cap - closing_cap)`,
  # which is > 0, so excessive strikes raise costs but can NEVER hard-ban a player
  # from the market. Tunable here for v1; can migrate to Data.Game.Constant later.
  @base_listing_pct 0.05
  @base_closing_pct 0.05
  @strike_step_pct 0.03
  @listing_cap_pct 0.40
  @closing_cap_pct 0.40

  def jason(), do: []

  typedstruct enforce: true do
    field(:id, integer())
    field(:payer_id, integer())
    field(:performer_id, integer() | nil, default: nil)

    # Descriptive only (honor-system). `action_category` additionally gates creation
    # and drives the UI; the rest are free metadata for the counterparty to read.
    # `action_type`/`note` are kept as strings so untrusted client input never has to
    # be turned into atoms.
    field(:action_category, atom())
    field(:action_type, String.t() | nil, default: nil)
    field(:target_system_id, integer() | nil, default: nil)
    field(:target_character_id, integer() | nil, default: nil)
    field(:note, String.t(), default: "")

    field(:bounty, integer())
    field(:max_claimant_strikes, integer())

    field(:status, atom(), default: :listed)
    field(:payer_closure, atom() | nil, default: nil)
    field(:performer_closure, atom() | nil, default: nil)

    # Fee snapshot, locked at claim (nil while still :listed). Stored as absolute
    # credits since the bounty is fixed; kept alongside the strike counts they were
    # derived from so the UI can explain the numbers.
    field(:listing_fee, integer() | nil, default: nil)
    field(:closing_fee, integer() | nil, default: nil)
    field(:payer_strikes_at_claim, integer() | nil, default: nil)
    field(:performer_strikes_at_claim, integer() | nil, default: nil)

    # Game-time (in-game days, per Instance.Time). `deadline` is recomputed to
    # `claim_time + duration` when the contract is claimed, giving the performer a
    # full window regardless of how long it sat on the board.
    field(:duration, float())
    field(:created_at, float())
    field(:deadline, float())
  end

  @doc "The valid agent categories a contract can be filed under."
  def categories, do: @categories

  # ── construction ──────────────────────────────────────────────────────────

  @doc """
  Validate and build a freshly listed contract. The caller (the payer's
  `Player.Agent`) is responsible for the gating check (owns the matching agent type)
  and for escrowing the bounty before storing the returned contract.

  `attrs` is an atom-keyed map; `now` is the current game-time.
  """
  def new(id, payer_id, attrs, now) when is_integer(id) and is_integer(payer_id) do
    with {:ok, bounty} <- validate_bounty(attrs[:bounty]),
         {:ok, category} <- validate_category(attrs[:action_category]),
         {:ok, duration} <- validate_duration(attrs[:duration]),
         {:ok, max_strikes} <- validate_max_claimant_strikes(attrs[:max_claimant_strikes]) do
      now = now * 1.0
      duration = duration * 1.0

      {:ok,
       %__MODULE__{
         id: id,
         payer_id: payer_id,
         action_category: category,
         action_type: attrs[:action_type],
         target_system_id: attrs[:target_system_id],
         target_character_id: attrs[:target_character_id],
         note: attrs[:note] || "",
         bounty: bounty,
         max_claimant_strikes: max_strikes,
         status: :listed,
         duration: duration,
         created_at: now,
         deadline: now + duration
       }}
    end
  end

  @doc """
  Validate an atom-keyed attrs map without building a contract — used by the payer's
  Player.Agent as a pre-flight check before it escrows the bounty.
  """
  def validate_attrs(attrs) do
    with {:ok, _} <- validate_bounty(attrs[:bounty]),
         {:ok, _} <- validate_category(attrs[:action_category]),
         {:ok, _} <- validate_duration(attrs[:duration]),
         {:ok, _} <- validate_max_claimant_strikes(attrs[:max_claimant_strikes]) do
      :ok
    end
  end

  @doc """
  Parse a string-keyed client params map into the atom-keyed attrs `new/4` expects.
  `action_category` is whitelisted to a known atom; `action_type`/`note` stay strings
  (descriptive, never matched on) so untrusted input never creates atoms.
  """
  def parse_attrs(params) when is_map(params) do
    with {:ok, category} <- parse_category(params["action_category"]),
         {:ok, bounty} <- parse_int(params["bounty"], :invalid_bounty),
         {:ok, duration} <- parse_number(params["duration"], :invalid_duration),
         {:ok, max_strikes} <- parse_int(params["max_claimant_strikes"], :invalid_max_claimant_strikes) do
      {:ok,
       %{
         action_category: category,
         action_type: parse_string(params["action_type"]),
         target_system_id: parse_optional_int(params["target_system_id"]),
         target_character_id: parse_optional_int(params["target_character_id"]),
         note: parse_string(params["note"]) || "",
         bounty: bounty,
         duration: duration,
         max_claimant_strikes: max_strikes
       }}
    end
  end

  def parse_attrs(_), do: {:error, :invalid_params}

  @doc "Map a client closure-intent string to its atom, or `:invalid`."
  def parse_closure_intent(intent) when is_binary(intent), do: Map.get(@closure_intents, intent, :invalid)
  def parse_closure_intent(intent) when intent in [:pay, :terminate, :dispute, :claim, :withdraw], do: intent
  def parse_closure_intent(_), do: :invalid

  # ── lifecycle transitions (pure) ──────────────────────────────────────────

  @doc """
  Claim a listed contract. Locks the fee snapshot from both parties' current strike
  counts and resets the deadline to `now + duration`. No credits move at claim — the
  fee is only realized (out of the bounty) if the contract later pays out.
  """
  def claim(%__MODULE__{} = c, performer_id, payer_strikes, performer_strikes, now)
      when is_integer(performer_id) and is_integer(payer_strikes) and is_integer(performer_strikes) do
    cond do
      c.status != :listed ->
        {:error, :not_listed}

      performer_id == c.payer_id ->
        {:error, :cannot_claim_own_contract}

      performer_strikes > c.max_claimant_strikes ->
        {:error, :too_many_strikes}

      true ->
        %{listing_fee: listing, closing_fee: closing} =
          compute_fees(c.bounty, payer_strikes, performer_strikes)

        {:ok,
         %{
           c
           | performer_id: performer_id,
             status: :active,
             listing_fee: listing,
             closing_fee: closing,
             payer_strikes_at_claim: payer_strikes,
             performer_strikes_at_claim: performer_strikes,
             deadline: now * 1.0 + c.duration
         }}
    end
  end

  @doc """
  Record a closure intent from one party. The payer may submit
  `:pay | :terminate | :dispute`; the performer `:claim | :withdraw | :dispute`.
  Intents are mutable until the contract resolves (see `withdraw_closure/2`).
  """
  def submit_closure(%__MODULE__{} = c, submitter_id, intent) do
    cond do
      c.status != :active ->
        {:error, :not_active}

      submitter_id == c.payer_id and intent in @payer_closures ->
        {:ok, %{c | payer_closure: intent}}

      submitter_id == c.performer_id and intent in @performer_closures ->
        {:ok, %{c | performer_closure: intent}}

      submitter_id == c.payer_id or submitter_id == c.performer_id ->
        {:error, :invalid_closure_for_role}

      true ->
        {:error, :not_a_party}
    end
  end

  @doc "Retract a previously-submitted closure intent (allowed any time before resolution)."
  def withdraw_closure(%__MODULE__{} = c, submitter_id) do
    cond do
      c.status != :active -> {:error, :not_active}
      submitter_id == c.payer_id -> {:ok, %{c | payer_closure: nil}}
      submitter_id == c.performer_id -> {:ok, %{c | performer_closure: nil}}
      true -> {:error, :not_a_party}
    end
  end

  @doc "Issuer voids a still-unclaimed listing. Resolves as a clean refund."
  def cancel(%__MODULE__{} = c, payer_id) do
    cond do
      c.payer_id != payer_id -> {:error, :not_a_party}
      c.status != :listed -> {:error, :not_listed}
      true -> resolve(c)
    end
  end

  # ── resolution ────────────────────────────────────────────────────────────

  @doc """
  The resolution matrix. `nil` means "silent" — no closure submitted by the deadline.

    * a `:dispute` from either party is dominant → `:disputed`
    * the payer's explicit `:pay` pays out (so Pay + Withdraw still pays)
    * a silent payer pays only against a `:claim`
    * everything else refunds

  | payer ↓ \\ performer → | claim | withdraw | dispute | nil(silent) |
  | pay       | paid     | paid     | disputed | paid     |
  | terminate | refunded | refunded | disputed | refunded |
  | dispute   | disputed | disputed | disputed | disputed |
  | nil       | paid     | refunded | disputed | refunded |
  """
  def outcome(:dispute, _), do: :disputed
  def outcome(_, :dispute), do: :disputed
  def outcome(:pay, _), do: :paid
  def outcome(nil, :claim), do: :paid
  def outcome(_payer, _performer), do: :refunded

  @doc """
  Finalize a contract and describe the resulting credit/strike effects. Call when
  `ready_to_resolve?/1` is true, when `expired?/2` is true, or to cancel a listed one.

  Returns `{:ok, effects}` where `effects` is:

      %{
        outcome:  :paid | :refunded | :disputed,
        contract: <updated terminal contract>,
        payout:   <credits to send the performer>,  # 0 unless :paid
        refund:   <credits to return the payer>,     # 0 unless :refunded/:disputed
        strike:   0 | 1                              # added to BOTH parties when :disputed
      }
  """
  def resolve(%__MODULE__{status: :listed} = c) do
    # Unclaimed — cancelled by the issuer or expired before any claim. Full refund.
    {:ok, refund_effects(c)}
  end

  def resolve(%__MODULE__{status: :active} = c) do
    case outcome(c.payer_closure, c.performer_closure) do
      :paid -> {:ok, paid_effects(c)}
      :refunded -> {:ok, refund_effects(c)}
      :disputed -> {:ok, dispute_effects(c)}
    end
  end

  def resolve(%__MODULE__{status: s}) when s in @terminal_statuses, do: {:error, :already_resolved}

  defp paid_effects(c) do
    payout = c.bounty - (c.listing_fee || 0) - (c.closing_fee || 0)
    %{outcome: :paid, contract: %{c | status: :paid}, payout: max(payout, 0), refund: 0, strike: 0}
  end

  defp refund_effects(c),
    do: %{outcome: :refunded, contract: %{c | status: :refunded}, payout: 0, refund: c.bounty, strike: 0}

  defp dispute_effects(c),
    do: %{outcome: :disputed, contract: %{c | status: :disputed}, payout: 0, refund: c.bounty, strike: 1}

  # ── predicates / helpers ──────────────────────────────────────────────────

  @doc "True once both parties have submitted a closure intent."
  def ready_to_resolve?(%__MODULE__{status: :active, payer_closure: p, performer_closure: q}),
    do: not is_nil(p) and not is_nil(q)

  def ready_to_resolve?(_), do: false

  @doc "True if the contract is still open (`:listed`/`:active`) and its deadline has passed."
  def expired?(%__MODULE__{status: s, deadline: d}, now) when s in [:listed, :active],
    do: now * 1.0 >= d

  def expired?(_, _), do: false

  @doc "True if the contract has reached a terminal state."
  def terminal?(%__MODULE__{status: s}), do: s in @terminal_statuses

  @doc "True if `player_id` is the payer or the performer of this contract."
  def party?(%__MODULE__{payer_id: p, performer_id: q}, player_id),
    do: player_id == p or player_id == q

  # ── fee math ──────────────────────────────────────────────────────────────

  @doc """
  Listing + closing fee for a bounty given the two parties' strike counts. Both fees
  come out of the bounty, so `payout = bounty - listing - closing`.
  """
  def compute_fees(bounty, payer_strikes, performer_strikes) do
    combined = payer_strikes + performer_strikes
    listing = round(bounty * listing_pct(combined))
    closing = round(bounty * closing_pct(combined))

    %{listing_fee: listing, closing_fee: closing, total: listing + closing, payout: bounty - listing - closing}
  end

  @doc "Listing-fee rate for a given combined strike count (capped)."
  def listing_pct(combined_strikes),
    do: min(@listing_cap_pct, @base_listing_pct + combined_strikes * @strike_step_pct)

  @doc "Closing-fee rate for a given combined strike count (capped)."
  def closing_pct(combined_strikes),
    do: min(@closing_cap_pct, @base_closing_pct + combined_strikes * @strike_step_pct)

  # ── validation / parsing ──────────────────────────────────────────────────

  defp validate_bounty(b) when is_integer(b) and b > 0, do: {:ok, b}
  defp validate_bounty(_), do: {:error, :invalid_bounty}

  defp validate_category(c) when c in @categories, do: {:ok, c}
  defp validate_category(_), do: {:error, :invalid_category}

  defp validate_duration(d) when is_number(d) and d > 0, do: {:ok, d}
  defp validate_duration(_), do: {:error, :invalid_duration}

  defp validate_max_claimant_strikes(n) when is_integer(n) and n >= 0, do: {:ok, n}
  defp validate_max_claimant_strikes(_), do: {:error, :invalid_max_claimant_strikes}

  defp parse_category(c) when c in @categories, do: {:ok, c}
  defp parse_category("spy"), do: {:ok, :spy}
  defp parse_category("speaker"), do: {:ok, :speaker}
  defp parse_category("admiral"), do: {:ok, :admiral}
  defp parse_category(_), do: {:error, :invalid_category}

  defp parse_int(n, _err) when is_integer(n), do: {:ok, n}

  defp parse_int(n, err) when is_binary(n) do
    case Integer.parse(n) do
      {i, ""} -> {:ok, i}
      _ -> {:error, err}
    end
  end

  defp parse_int(_, err), do: {:error, err}

  defp parse_number(n, _err) when is_number(n), do: {:ok, n * 1.0}

  defp parse_number(n, err) when is_binary(n) do
    case Float.parse(n) do
      {f, ""} -> {:ok, f}
      _ -> {:error, err}
    end
  end

  defp parse_number(_, err), do: {:error, err}

  defp parse_optional_int(nil), do: nil
  defp parse_optional_int(n) when is_integer(n), do: n

  defp parse_optional_int(n) when is_binary(n) do
    case Integer.parse(n) do
      {i, ""} -> i
      _ -> nil
    end
  end

  defp parse_optional_int(_), do: nil

  defp parse_string(nil), do: nil
  defp parse_string(s) when is_binary(s), do: s
  defp parse_string(s) when is_atom(s), do: Atom.to_string(s)
  defp parse_string(_), do: nil
end
