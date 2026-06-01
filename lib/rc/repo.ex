defmodule RC.Repo do
  use Ecto.Repo,
    otp_app: :rc,
    adapter: Ecto.Adapters.Postgres

  # Stage 5 #1 fix.
  #
  # `max_page_size: 200` is the server-side ceiling Scrivener will clamp
  # any client-supplied `?page_size=N` to. Without this cap, every
  # paginated /api/* listing (messenger, blog posts, instances, uploads,
  # …) honored `?page_size=10_000_000` verbatim, letting one authenticated
  # request drag back the entire table and OOM the BEAM.
  #
  # 200 is ~4× the largest current UI page (which uses 10-50 per Scrivener
  # default). Raise if a real client needs more.
  use Scrivener,
    page_size: 50,
    max_page_size: 200

  def format_errors(%Ecto.Changeset{} = changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
  end
end
