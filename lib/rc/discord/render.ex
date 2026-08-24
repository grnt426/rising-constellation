defmodule RC.Discord.Render do
  @moduledoc """
  SVG -> PNG rasterization for Discord news cards.

  Two backends, tried in order:

    * **`priv/bin/resvg`** — a static resvg binary vendored into the
      release by the prod Dockerfile (built from source for the target
      arch). Fully self-contained: fonts load directly from
      `priv/fonts`, so the host needs no OS packages at all — no
      librsvg, no fontconfig. This is the production path.
    * **`rsvg-convert`** — librsvg on `$PATH` (the dev container ships
      it). Uses fontconfig for fonts.

  The Forge map/scenario thumbnails (`RC.Scenarios`) rasterize through
  this module too, so both image pipelines share the same backend
  resolution.

  With neither present, `rasterize/2` returns
  `{:error, :rasterizer_unavailable}` and callers fall back to their
  text rendering — news never goes dark over a missing binary.
  """

  require Logger

  @default_width 1600

  @doc """
  Rasterizes an SVG string to a PNG binary at the given pixel width
  (height follows the aspect ratio). `{:ok, binary} | {:error, term}`.
  """
  def rasterize(svg, width \\ @default_width) when is_binary(svg) do
    case rasterizer() do
      nil ->
        {:error, :rasterizer_unavailable}

      {backend, bin} ->
        base = Path.join(System.tmp_dir!(), "rc_discord_card_#{System.unique_integer([:positive])}")
        svg_path = base <> ".svg"
        png_path = base <> ".png"

        try do
          File.write!(svg_path, svg)

          case System.cmd(bin, args(backend, svg_path, png_path, width), stderr_to_stdout: true) do
            {_out, 0} -> File.read(png_path)
            {out, code} -> {:error, {backend, code, out}}
          end
        after
          File.rm(svg_path)
          File.rm(png_path)
        end
    end
  end

  @doc "Is a rasterizer backend present?"
  def available?, do: rasterizer() != nil

  defp rasterizer do
    resvg = Path.join(priv_dir(), "bin/resvg")

    cond do
      File.exists?(resvg) -> {:resvg, resvg}
      bin = System.find_executable("rsvg-convert") -> {:rsvg, bin}
      true -> nil
    end
  end

  defp args(:resvg, svg_path, png_path, width) do
    # --skip-system-fonts keeps rendering deterministic across hosts:
    # every glyph must resolve from the vendored priv/fonts files.
    ["--width", Integer.to_string(width), "--skip-system-fonts"] ++
      font_args() ++ [svg_path, png_path]
  end

  defp args(:rsvg, svg_path, png_path, width) do
    ["--width=#{width}", "--keep-aspect-ratio", "--format=png", "--output=#{png_path}", svg_path]
  end

  defp font_args do
    fonts_dir = Path.join(priv_dir(), "fonts")

    case File.ls(fonts_dir) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".ttf"))
        |> Enum.flat_map(&["--use-font-file", Path.join(fonts_dir, &1)])

      _ ->
        []
    end
  end

  defp priv_dir, do: to_string(:code.priv_dir(:rc))

  @doc """
  Builds the Nostrum message options for an image post: the caption as
  regular content (fallback for clients that don't render attachments,
  plus searchability) with the PNG attached.
  """
  def image_message(caption, png, filename \\ "news.png") do
    %{content: caption, files: [%{name: filename, body: png}]}
  end

  @doc """
  Posts message opts; when an ATTACHMENT post is rejected and fallback
  opts are given, retries once without the attachment. First seen live
  2026-08-12 00:00 UTC: the community #game-news channel overwrite
  grants the bot Send Messages but not Attach Files, so the image
  digest 403'd while a text post would have landed. The permission fix
  is Discord-side; this keeps the news flowing meanwhile instead of
  dropping the window for that channel.
  """
  def create_or_fallback(channel_id, opts, fallback_opts \\ nil) do
    case Nostrum.Api.Message.create(channel_id, opts) do
      {:ok, _} = ok ->
        ok

      {:error, reason} = err ->
        if fallback_opts && Map.has_key?(opts, :files) do
          Logger.warning(
            "[RC.Discord.Render] image post failed (channel #{channel_id}): #{inspect(reason)} — retrying without attachment"
          )

          Nostrum.Api.Message.create(channel_id, fallback_opts)
        else
          err
        end
    end
  end
end
