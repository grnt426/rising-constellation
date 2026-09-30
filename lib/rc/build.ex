defmodule RC.Build do
  @moduledoc """
  Which game server this is, for `GET /api/version` and the
  `portal:user:*` join reply:

    * `version` — the git revision this release was built from, stamped
      into `priv/VERSION` by `deploy/release.sh` ("dev" outside a release);
    * `live_since` — when this server came online. Every start counts, not
      only deploys: a restart wipes all in-memory game state, so for a
      client it is a new version of the game even on the same revision
      (a rollback, a crash, a manual restart);
    * `deploying` — the deploy notice flag (`RC.Deploy`): raised on the
      old server before a deploy builds, cleared once the new server is
      healthy. Because it is persisted, a freshly started server reports
      `true` until the deploy script finishes.

  `version` and `live_since` are read once, at boot, and never change for
  the life of the node — a deploy replaces the release files only after
  it has stopped this server, and this module never re-reads them. The
  client compares them with what it saw when it loaded, and with its own
  bundle's revision (`VUE_APP_GIT_SHA`), to tell a stale tab from a deploy
  in progress.
  """

  @key {__MODULE__, :info}

  @doc "Stamps this node's revision and start time. Called once from RC.Application."
  def init do
    info = %{
      version: read_version(),
      live_since: DateTime.utc_now() |> DateTime.truncate(:second)
    }

    :persistent_term.put(@key, info)
    info
  end

  @doc "`%{version, live_since, deploying}`: the JSON the client stores."
  def info do
    stamped =
      case :persistent_term.get(@key, nil) do
        nil -> init()
        stamped -> stamped
      end

    Map.put(stamped, :deploying, RC.Deploy.get_flag() == true)
  end

  defp read_version do
    case File.read(Application.app_dir(:rc, "priv/VERSION")) do
      {:ok, contents} ->
        case String.trim(contents) do
          "" -> "dev"
          version -> version
        end

      {:error, _} ->
        "dev"
    end
  end
end
