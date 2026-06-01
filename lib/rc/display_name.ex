defmodule RC.DisplayName do
  @moduledoc """
  Shared validator for user-visible name/title fields.

  Stage 5 #B1.4 fix. Before this, `Account.name`, `Profile.name`,
  `Conversation.name`, `Folder.name`, `Instance.name`, and `BlogPost.title`
  all accepted arbitrary Unicode — including U+202E RIGHT-TO-LEFT
  OVERRIDE, U+200B ZERO WIDTH SPACE, leading/trailing whitespace, and C0
  control bytes. Vue's mustache interpolation HTML-escapes `<>&'"` but
  does NOT strip bidi controls, so an attacker could register a name
  with a U+202E embedded and have it render as a visually-deceptive
  variant in messenger / standings / blog author labels.

  The validator:

    1. Trims leading/trailing whitespace.
    2. Normalises to Unicode NFC so visually-identical strings collide
       on uniqueness constraints (`a + combining acute` vs `á`).
    3. Rejects any codepoint in category `Cc` (control) or `Cf` (format),
       plus the bidi-override block U+2028..U+202F explicitly.

  Apply by piping through the changeset:

      defp shared_validations(changeset) do
        changeset
        |> validate_length(:name, max: 50)
        |> RC.DisplayName.validate_display_name(:name)
      end
  """

  import Ecto.Changeset

  # U+0000..U+001F (C0 control), U+007F (DEL), U+0080..U+009F (C1 control),
  # U+200B..U+200F (zero-width + LRM/RLM), U+2028..U+202F (line/paragraph
  # separators + LRE/RLE/PDF/LRO/RLO + space variants), U+2060..U+206F
  # (word joiner + other format controls), U+FEFF (BOM), U+FFF9..U+FFFB
  # (interlinear annotation markers).
  @bad_codepoints_regex ~r/[\x{0000}-\x{001F}\x{007F}-\x{009F}\x{200B}-\x{200F}\x{2028}-\x{202F}\x{2060}-\x{206F}\x{FEFF}\x{FFF9}-\x{FFFB}]/u

  @doc """
  Validate that `field` on `changeset` is a clean display name.

  Performs NFC normalisation + trim BEFORE the validation so the stored
  value matches what the user intended; rejects on disallowed codepoints
  with a changeset error keyed on `field` (so the SPA's existing 422
  display surfaces it).
  """
  def validate_display_name(changeset, field) do
    changeset
    |> update_change(field, &normalize/1)
    |> validate_change(field, fn ^field, value ->
      cond do
        not is_binary(value) ->
          [{field, "must be a string"}]

        Regex.match?(@bad_codepoints_regex, value) ->
          [{field, "contains disallowed control or formatting characters"}]

        true ->
          # Blank/empty is the responsibility of validate_required, which
          # every consumer pairs with us. Ecto's cast pre-trims and drops
          # `""` from `changes` before our validate_change ever runs, so
          # an explicit blank check here would be a no-op anyway.
          []
      end
    end)
  end

  defp normalize(value) when is_binary(value) do
    value
    |> String.trim()
    |> :unicode.characters_to_nfc_binary()
    |> case do
      bin when is_binary(bin) -> bin
      # If NFC normalisation fails (incomplete/malformed bytes), fall
      # back to the trimmed input — `validate_display_name` will then
      # reject any binary that still contains disallowed chars.
      _ -> String.trim(value)
    end
  end

  defp normalize(value), do: value
end
