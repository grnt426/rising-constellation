defmodule Portal.EdictController do
  @moduledoc """
  The Scenario Workshop's backend (see docs/scenario-scripting.md). The
  editor never parses, prints or runs a script itself: it sends text or a
  tree here and gets back the canonical tree, the canonical text and the
  diagnostics, so the language has exactly one implementation.

  Everything here is a pure computation bounded by `Edict.Limits` (and, for
  simulation, `Edict.Sandbox`); per-account rate limits keep one account from
  hogging the CPU.
  """
  use Portal, :controller

  alias Edict.{AST, Catalog, Checker, Parser, Printer, Simulator, SourceMap}

  plug(
    Portal.Plug.AccountRateLimit,
    [bucket: "edict_analyze", limit: 900, window_ms: 300_000] when action in [:analyze, :fragment]
  )

  plug(
    Portal.Plug.AccountRateLimit,
    [bucket: "edict_simulate", limit: 200, window_ms: 300_000] when action == :simulate
  )

  plug(Portal.Plug.AccountRateLimit, [bucket: "edict_playtest", limit: 10, window_ms: 600_000] when action == :playtest)

  # GET /api/edict/catalog
  def catalog(conn, _params) do
    json(conn, Map.put(Catalog.to_json(), :simulator, Simulator.assumptions()))
  end

  # GET /api/edict/examples
  def examples(conn, _params) do
    json(conn, %{examples: Enum.map(Edict.examples(), &Map.take(&1, [:key, :title, :level, :port_of, :source]))})
  end

  # POST /api/edict/analyze  {source} | {program}
  #
  # From text: the tree and the diagnostics. From a tree (the visual editor):
  # the sanitized tree, the diagnostics and the canonical text.
  def analyze(conn, %{"source" => source}) when is_binary(source) do
    %{program: program, diagnostics: diags} = Edict.analyze(source)
    json(conn, %{program: program, diagnostics: diags})
  end

  def analyze(conn, %{"program" => json} = params) do
    case AST.from_json(json) do
      {:ok, program} ->
        source = Printer.print(program)

        json(conn, %{
          program: program,
          diagnostics: Checker.check(program),
          source: source,
          positions: SourceMap.positions(program, source),
          snippets: SourceMap.snippets(program, List.wrap(params["code_ids"]))
        })

      {:error, message} ->
        unprocessable(conn, message)
    end
  end

  def analyze(conn, _params), do: unprocessable(conn, "send source or program")

  # POST /api/edict/fragment  {source, kind: "expr" | "block"}
  #
  # A code node's text, parsed on its own.
  def fragment(conn, %{"source" => source, "kind" => kind}) when is_binary(source) and kind in ["expr", "block"] do
    case Parser.parse_fragment(source, if(kind == "expr", do: :expr, else: :block)) do
      {:ok, node} -> json(conn, %{node: node})
      {:error, error} -> json(conn, %{error: error})
    end
  end

  def fragment(conn, _params), do: unprocessable(conn, "send source and kind")

  # POST /api/edict/format  {expr | block}
  #
  # The text for one expression or statement list (a node shown as code).
  def format(conn, %{"expr" => json}) do
    case AST.fragment_from_json(json, :expr) do
      {:ok, e} -> json(conn, %{source: Printer.print_expr(e)})
      {:error, message} -> unprocessable(conn, message)
    end
  end

  def format(conn, _params), do: unprocessable(conn, "send expr")

  # POST /api/edict/simulate  {source | program, pace?, pretend?}
  def simulate(conn, params) do
    with {:ok, program} <- program_from(params),
         opts = [pace: pace(params["pace"]), pretend: List.wrap(params["pretend"])],
         {:ok, report} <- Simulator.run(program, opts) do
      json(conn, %{ok: true, report: report})
    else
      {:error, errors} when is_list(errors) -> json(conn, %{ok: false, errors: errors})
      {:error, message} -> unprocessable(conn, message)
    end
  end

  # POST /api/edict/playtest  {source, profile_id}
  #
  # Boots a real single-player game from the script and returns the same
  # join payload as POST /api/daily/play, so the client enters it the same
  # way. Scripts with errors don't boot: the errors come back instead.
  def playtest(conn, %{"source" => source, "profile_id" => profile_id}) when is_binary(source) do
    account = Guardian.Plug.current_resource(conn)

    cond do
      RC.Deploy.dailies_locked?() ->
        conn |> put_status(503) |> json(%{message: :deploy_in_progress})

      true ->
        case RC.Accounts.get_profile(profile_id) do
          %RC.Accounts.Profile{account_id: aid} = profile when aid == account.id ->
            case Edict.Live.boot(profile, source) do
              {:ok, info} ->
                json(conn, %{
                  ok: true,
                  instance: info.instance_id,
                  faction: info.faction_id,
                  profile: info.profile_id,
                  registration_token: info.registration_token,
                  user_token: Guardian.Plug.current_token(conn)
                })

              {:error, errors} ->
                json(conn, %{ok: false, errors: errors})
            end

          _ ->
            conn |> put_status(403) |> json(%{message: :profile_not_owned})
        end
    end
  end

  def playtest(conn, _params), do: unprocessable(conn, "send source and profile_id")

  defp program_from(%{"source" => source}) when is_binary(source) do
    case Parser.parse(source) do
      {:ok, program} -> {:ok, program}
      {:error, error} -> {:error, [%{message: error.message, node_id: nil, at: [error.line, error.col]}]}
    end
  end

  defp program_from(%{"program" => json}), do: AST.from_json(json)
  defp program_from(_), do: {:error, "send source or program"}

  defp pace(p) when p in ["slow", "typical", "strong"], do: p
  defp pace(_), do: "typical"

  defp unprocessable(conn, message) do
    conn
    |> put_status(422)
    |> json(%{message: message})
  end
end
