defmodule RC.RateLimit do
  @moduledoc """
  Per-key rate limiter for sensitive endpoints (login, password reset,
  invites, account deletion requests, forge writes).

  Hammer's ETS backend with fixed windows aligned to the epoch, as Hammer 6's
  `check_rate/3` used: limits are per node, which is fine for a single-node
  deployment; a multi-node one would need a shared backend (hammer_backend_redis).

      case RC.RateLimit.hit(key, window_ms, limit) do
        {:allow, count} -> ...
        {:deny, retry_after_ms} -> ...
      end
  """
  use Hammer, backend: :ets
end
