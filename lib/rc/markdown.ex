defmodule RC.Markdown do
  # Stage 5 #B1.6 fix.
  #
  # HtmlSanitizeEx.markdown_html only runs scheme checks when the URL
  # contains a literal `:` (or its encoded forms). A protocol-relative
  # URL like `//attacker.example/login` passes the sanitizer's
  # else-branch, so `[Privacy Policy](//harvest.example/login)` renders
  # as `<a href="//harvest.example/login">` — visually looks like a
  # relative path to a moderator reviewing `content_raw`, while the
  # browser resolves it cross-origin under HTTPS.
  #
  # `strip_protocol_relative/1` runs after the sanitizer and rewrites
  # `href="//..."` / `src="//..."` to `href="https://..."` / `src="https://..."`.
  # `javascript:` and `data:` are still caught by the sanitizer's scheme
  # check (they contain `:`) so they're unaffected.
  @protocol_relative_url_regex ~r/(href|src)=(['"])\/\//

  def render_inline(md) do
    md
    |> Earmark.as_html!()
    |> HtmlSanitizeEx.markdown_html()
    |> strip_protocol_relative()
  end

  def render_changeset(changeset, field_to_format, field_to_set) do
    if changeset.valid? and Map.has_key?(changeset.changes, field_to_format) do
      Ecto.Changeset.put_change(changeset, field_to_set, render_inline(changeset.changes[field_to_format]))
    else
      changeset
    end
  end

  defp strip_protocol_relative(html) do
    Regex.replace(@protocol_relative_url_regex, html, ~S(\1=\2https://))
  end
end
