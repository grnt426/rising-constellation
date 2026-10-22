defmodule RC.Scripts do
  @moduledoc """
  Scenario scripts saved to an account, and publishing them.

    * An account keeps at most #{10} scripts (`max_per_account/0`).
    * A script is published or not: there is no separate published copy, so
      what others see and attach is always the version its author last
      saved. Publishing needs a script that checks clean, and saving a
      published script keeps it clean.
    * No two published scripts have the same text (a partial unique index on
      the digest): copying someone's script and publishing it unchanged is
      refused.

  Name, description, canonical text, digest and error count are all derived
  here from the script itself; the client sends only a tree (or text) and
  the editor's layout.
  """

  import Ecto.Query

  alias Edict.{AST, Checker, Effects, Limits, Parser, Printer}
  alias RC.Repo
  alias RC.Scripts.Script

  @max_per_account 10
  @max_layout_bytes 64 * 1024

  def max_per_account, do: @max_per_account

  # --- reading -----------------------------------------------------------------

  @doc "An account's scripts, most recently saved first (sources included)."
  def list_mine(account_id) do
    Script
    |> where([s], s.author_id == ^account_id)
    |> order_by([s], desc: s.updated_at)
    |> preload(:author)
    |> Repo.all()
  end

  @doc """
  Published scripts, most recently published first. `opts`: `:search` (a
  name fragment), `:limit` (default 100).
  """
  def list_published(opts \\ []) do
    limit = opts |> Keyword.get(:limit, 100) |> min(200) |> max(1)

    Script
    |> where([s], not is_nil(s.published_at))
    |> search(Keyword.get(opts, :search))
    |> order_by([s], desc: s.published_at, desc: s.id)
    |> limit(^limit)
    |> preload(:author)
    |> Repo.all()
  end

  defp search(query, term) when is_binary(term) and term != "" do
    pattern = "%" <> String.replace(String.slice(term, 0, 60), ~r/[\\%_]/, "\\\\\\0") <> "%"
    where(query, [s], ilike(s.name, ^pattern))
  end

  defp search(query, _), do: query

  def get(id) when is_integer(id), do: Script |> preload(:author) |> Repo.get(id)

  def get(id) when is_binary(id) do
    case Integer.parse(id) do
      {n, ""} -> get(n)
      _ -> nil
    end
  end

  def get(_), do: nil

  @doc "Whether `account_id` may read (and attach) the script: its own, or a published one."
  def visible?(%Script{author_id: id}, id), do: true
  def visible?(%Script{published_at: %DateTime{}}, _account_id), do: true
  def visible?(_script, _account_id), do: false

  @doc "A script by id if `account_id` may read it, else nil."
  def get_visible(id, account_id) do
    case get(id) do
      %Script{} = script -> if visible?(script, account_id), do: script
      nil -> nil
    end
  end

  # --- writing -----------------------------------------------------------------

  @doc """
  Save a new script for `account_id`. `attrs`: `"program"` (the editor's
  tree as JSON) or `"source"` (text), and `"layout"`. Returns `{:ok, script}`
  or `{:error, reason}`: `:limit` (already #{@max_per_account} scripts),
  `{:invalid, message}`, or a changeset.
  """
  def create(account_id, attrs) when is_integer(account_id) do
    with {:ok, fields} <- derive(attrs) do
      Repo.transaction(fn ->
        # one at a time per account, so two quick saves can't both pass the count
        Repo.one!(from(a in RC.Accounts.Account, where: a.id == ^account_id, select: a.id, lock: "FOR UPDATE"))

        if count_for(account_id) >= @max_per_account do
          Repo.rollback(:limit)
        else
          %Script{author_id: account_id}
          |> Script.changeset(fields)
          |> Repo.insert()
          |> case do
            {:ok, script} -> Repo.preload(script, :author)
            {:error, changeset} -> Repo.rollback(changeset)
          end
        end
      end)
    end
  end

  @doc """
  Save a new version of a script. A published script stays published, so it
  must still check clean and must not become the copy of another published
  script: `{:error, :has_errors}` / `{:error, {:duplicate, other}}`.
  """
  def update(%Script{} = script, attrs) do
    with {:ok, fields} <- derive(attrs),
         :ok <- publishable(script, fields) do
      script
      |> Script.changeset(fields)
      |> Repo.update()
      |> duplicate_from_index(fields.digest, script.id)
    end
  end

  def delete(%Script{} = script), do: Repo.delete(script)

  @doc "Publish a script: `{:error, :has_errors}` or `{:error, {:duplicate, other}}` when it can't be."
  def publish(%Script{published_at: %DateTime{}} = script), do: {:ok, script}

  def publish(%Script{} = script) do
    with :ok <- publishable(%{script | published_at: DateTime.utc_now()}, script) do
      script
      |> Script.publish_changeset(DateTime.utc_now())
      |> Repo.update()
      |> duplicate_from_index(script.digest, script.id)
    end
  end

  def unpublish(%Script{} = script) do
    script |> Script.publish_changeset(nil) |> Repo.update()
  end

  defp publishable(%Script{published_at: nil}, _fields), do: :ok

  defp publishable(%Script{id: id}, %{error_count: errors, digest: digest}) do
    cond do
      errors > 0 -> {:error, :has_errors}
      other = published_with(digest, id) -> {:error, {:duplicate, other}}
      true -> :ok
    end
  end

  defp published_with(digest, except_id) do
    Script
    |> where([s], s.digest == ^digest and not is_nil(s.published_at))
    |> where([s], s.id != ^(except_id || 0))
    |> preload(:author)
    |> limit(1)
    |> Repo.one()
  end

  # the unique index caught a race the check above didn't see
  defp duplicate_from_index({:error, %Ecto.Changeset{errors: errors} = cs}, digest, id) do
    if Keyword.has_key?(errors, :digest) do
      case published_with(digest, id) do
        nil -> {:error, cs}
        other -> {:error, {:duplicate, other}}
      end
    else
      {:error, cs}
    end
  end

  defp duplicate_from_index({:ok, script}, _digest, _id), do: {:ok, Repo.preload(script, :author, force: true)}

  defp count_for(account_id) do
    Repo.aggregate(from(s in Script, where: s.author_id == ^account_id), :count)
  end

  # --- attaching to a scenario ----------------------------------------------------

  @doc """
  The scripts a scenario attaches, rebuilt on the server from what its editor
  sent (`requested`: script ids, or the frozen entries a loaded scenario
  carries; only their ids count). Each id the editing account may read is
  frozen from its current saved version (`Edict.Attachment.freeze/1`). One
  it no longer may (unpublished, deleted) keeps the copy the scenario
  already had (`previous_game_data`), so a scenario never loses a script
  behind its author's back. Text from the client is never kept.
  """
  def attach(requested, account_id, previous_game_data \\ nil) do
    previous = Map.new(Edict.Attachment.scripts(previous_game_data || %{}), &{&1["id"], &1})

    requested
    |> List.wrap()
    |> Enum.map(fn
      %{"id" => id} -> id
      id -> id
    end)
    |> Enum.map(&to_id/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.take(Edict.Attachment.max_scripts())
    |> Enum.flat_map(fn id ->
      case get_visible(id, account_id) do
        %Script{} = script -> [Edict.Attachment.freeze(script)]
        nil -> List.wrap(previous[id])
      end
    end)
  end

  defp to_id(id) when is_integer(id), do: id

  defp to_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp to_id(_), do: nil

  # --- deriving a script's fields ---------------------------------------------

  @doc false
  # The fields the server keeps for a tree or text: canonical source, its
  # digest, the setup's name and description, the checker's error count.
  def derive(attrs) when is_map(attrs) do
    with {:ok, program} <- program_from(attrs),
         source = Printer.print(program),
         :ok <- fits(source),
         {:ok, layout} <- layout_from(attrs) do
      errors = program |> Checker.check() |> Enum.count(&(&1.severity == "error"))

      {:ok,
       %{
         name: setup_text(program, "name") || "Untitled scenario",
         description: Effects.clean_text(setup_text(program, "description") || "", 500),
         source: source,
         program: program |> Jason.encode!() |> Jason.decode!(),
         layout: layout,
         digest: digest(source),
         error_count: errors
       }}
    end
  end

  def derive(_), do: {:error, {:invalid, "send a program or a source"}}

  @doc "The digest that identifies a script's text."
  def digest(source), do: :crypto.hash(:sha256, source) |> Base.encode16(case: :lower)

  defp program_from(%{"program" => json}) when is_map(json) do
    case AST.from_json(json) do
      {:ok, program} -> {:ok, program}
      {:error, message} -> {:error, {:invalid, message}}
    end
  end

  defp program_from(%{"source" => source}) when is_binary(source) do
    case Parser.parse(source) do
      {:ok, program} -> {:ok, program}
      {:error, %{message: message, line: line}} -> {:error, {:invalid, "line #{line}: #{message}"}}
    end
  end

  defp program_from(_), do: {:error, {:invalid, "send a program or a source"}}

  defp fits(source) do
    if byte_size(source) <= Limits.max_source_bytes(),
      do: :ok,
      else: {:error, {:invalid, "the script is too long (#{div(Limits.max_source_bytes(), 1024)} KB at most)"}}
  end

  defp layout_from(%{"layout" => layout}) when is_map(layout) do
    if :erlang.external_size(layout) <= @max_layout_bytes,
      do: {:ok, layout},
      else: {:error, {:invalid, "the layout is too large"}}
  end

  defp layout_from(_), do: {:ok, %{}}

  @doc "A setup field written as plain text in the script (`name = \"…\"`), or nil."
  def setup_text(%{decls: decls}, field) do
    Enum.find_value(decls, fn
      %{k: :setup, body: body} ->
        Enum.find_value(body, fn
          %{k: :assign, target: %{k: :ident, name: ^field}, expr: %{k: :str, v: v}} -> v
          _ -> nil
        end)

      _ ->
        nil
    end)
  end
end
