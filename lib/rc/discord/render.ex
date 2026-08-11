defmodule RC.Discord.Render do
  @moduledoc """
  SVG -> PNG rasterization for Discord news cards.

  Shells to `rsvg-convert` (librsvg), the same tool
  `RC.Scenarios.rasterize_svg_to_png/2` uses for Forge thumbnails —
  see the comment there for why ImageMagick is not an option. Returns
  the PNG as a binary ready for a Nostrum `files:` upload; callers
  fall back to their text rendering when rasterization is unavailable
  (e.g. a host without librsvg), so news never goes dark over a
  missing package.
  """

  require Logger

  @default_width 1600

  @doc """
  Rasterizes an SVG string to a PNG binary at the given pixel width
  (height follows the aspect ratio). `{:ok, binary} | {:error, term}`.
  """
  def rasterize(svg, width \\ @default_width) when is_binary(svg) do
    if available?() do
      base = Path.join(System.tmp_dir!(), "rc_discord_card_#{System.unique_integer([:positive])}")
      svg_path = base <> ".svg"
      png_path = base <> ".png"

      try do
        File.write!(svg_path, svg)

        case System.cmd(
               "rsvg-convert",
               ["--width=#{width}", "--keep-aspect-ratio", "--format=png", "--output=#{png_path}", svg_path],
               stderr_to_stdout: true
             ) do
          {_out, 0} -> File.read(png_path)
          {out, code} -> {:error, {:rsvg_convert, code, out}}
        end
      after
        File.rm(svg_path)
        File.rm(png_path)
      end
    else
      {:error, :rsvg_unavailable}
    end
  end

  @doc "Is the rasterizer present on this host?"
  def available?, do: System.find_executable("rsvg-convert") != nil

  @doc """
  Builds the Nostrum message options for an image post: the caption as
  regular content (fallback for clients that don't render attachments,
  plus searchability) with the PNG attached.
  """
  def image_message(caption, png, filename \\ "news.png") do
    %{content: caption, files: [%{name: filename, body: png}]}
  end
end
