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
      it). Uses fontconfig for fonts, like the Forge thumbnails
      (`RC.Scenarios.rasterize_svg_to_png/2`).

  With neither present, `rasterize/2` returns
  `{:error, :rasterizer_unavailable}` and callers fall back to their
  text rendering — news never goes dark over a missing binary.

  Animated cards (`rasterize_gif/2`) rasterize each loop frame through
  the same backend, then encode the frames with libvips (the `vix`
  dependency: precompiled NIF + libvips fetched at `mix deps.compile`,
  so this path needs no host packages either). libvips writes GIFs via
  cgif with inter-frame diffing, so mostly-static cards stay small.
  `card_image/3` is the one entry point posters use: a GIF when the card
  moves, the static PNG whenever the GIF path fails or is too large.
  """

  require Logger

  @default_width 1600

  # Discord's attachment cap for bots in an unboosted guild is 10 MiB;
  # leave headroom for the multipart envelope.
  @max_gif_bytes 9_500_000

  @doc """
  Rasterizes an SVG string to a PNG binary at the given pixel width
  (height follows the aspect ratio). `{:ok, binary} | {:error, term}`.
  """
  def rasterize(svg, width \\ @default_width) when is_binary(svg) do
    case rasterizer() do
      nil ->
        {:error, :rasterizer_unavailable}

      backend ->
        base = Path.join(System.tmp_dir!(), "rc_discord_card_#{System.unique_integer([:positive])}")
        png_path = base <> ".png"

        try do
          with :ok <- rasterize_to(backend, svg, base <> ".svg", png_path, width) do
            File.read(png_path)
          end
        after
          File.rm(png_path)
        end
    end
  end

  @doc """
  Renders a looping animated GIF. `render_frame` is called with each
  loop phase `t` in `[0, 1)` and returns that frame's SVG.

  Options: `:frames` (default 40), `:delay_ms` per frame (default 60,
  a 2.4 s loop; GIF delays are whole centiseconds, so use multiples of
  10), `:width` (default 1600), `:max_concurrency` for frame
  rasterization (default half the schedulers — prod shares its cores
  with running games).

  `{:ok, gif_binary} | {:error, term}`.
  """
  def rasterize_gif(render_frame, opts \\ []) when is_function(render_frame, 1) do
    frames = Keyword.get(opts, :frames, 40)
    delay = Keyword.get(opts, :delay_ms, 60)
    width = Keyword.get(opts, :width, @default_width)
    concurrency = Keyword.get(opts, :max_concurrency, max(1, div(System.schedulers_online(), 2)))

    case rasterizer() do
      nil ->
        {:error, :rasterizer_unavailable}

      backend ->
        dir = Path.join(System.tmp_dir!(), "rc_discord_gif_#{System.unique_integer([:positive])}")
        File.mkdir_p!(dir)

        try do
          frame_results =
            0..(frames - 1)
            |> Task.async_stream(
              fn i ->
                base = Path.join(dir, "frame_#{String.pad_leading(Integer.to_string(i), 3, "0")}")
                png = base <> ".png"

                case rasterize_to(backend, render_frame.(i / frames), base <> ".svg", png, width) do
                  :ok -> {:ok, png}
                  error -> {:error, {:frame, i, error}}
                end
              end,
              max_concurrency: concurrency,
              timeout: 120_000,
              ordered: true
            )
            |> Enum.map(fn {:ok, result} -> result end)

          with nil <- Enum.find(frame_results, &match?({:error, _}, &1)) do
            encode_gif(Enum.map(frame_results, fn {:ok, png} -> png end), delay)
          end
        after
          File.rm_rf(dir)
        end
    end
  end

  # PNG frames -> one tall libvips image with page-height/delay/loop
  # metadata, which gifsave writes as an animated GIF. Frames load
  # lazily from disk; effort 4 of 10 is within ~2% of the smallest
  # output for these cards at a fraction of the CPU.
  defp encode_gif(pngs, delay) do
    alias Vix.Vips.{Image, MutableImage, Operation}

    with {:ok, images} <- load_frames(pngs),
         {:ok, strip} <- Operation.arrayjoin(images, across: 1),
         {:ok, strip} <-
           Image.mutate(strip, fn m ->
             :ok = MutableImage.set(m, "page-height", :gint, Image.height(hd(images)))
             :ok = MutableImage.set(m, "delay", :VipsArrayInt, List.duplicate(delay, length(images)))
             :ok = MutableImage.set(m, "loop", :gint, 0)
           end),
         {:ok, gif} <- Operation.gifsave_buffer(strip, effort: 4, "interframe-maxerror": 0.0) do
      if byte_size(gif) > @max_gif_bytes, do: {:error, {:gif_too_large, byte_size(gif)}}, else: {:ok, gif}
    end
  rescue
    # a NIF that failed to load (unsupported target) must not take the
    # post down with it — callers fall back to the PNG
    e -> {:error, {:gif_encode, e}}
  end

  defp load_frames(pngs) do
    Enum.reduce_while(pngs, {:ok, []}, fn png, {:ok, acc} ->
      case Vix.Vips.Image.new_from_file(png, access: :VIPS_ACCESS_SEQUENTIAL) do
        {:ok, image} -> {:cont, {:ok, [image | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, images} -> {:ok, Enum.reverse(images)}
      error -> error
    end
  end

  @doc """
  The image to attach for a news card: `{:ok, binary, filename}`.

  `render` takes a loop phase (`nil` = the static card). With
  `animated: true` it tries a GIF first (`basename <> ".gif"`); any
  GIF failure is logged and degrades to the static PNG, so a card
  never goes missing over its animation. `gif_opts` pass through to
  `rasterize_gif/2`.
  """
  def card_image(render, basename, opts \\ []) when is_function(render, 1) do
    gif =
      if Keyword.get(opts, :animated, true) do
        case rasterize_gif(render, Keyword.get(opts, :gif_opts, [])) do
          {:ok, gif} ->
            gif

          error ->
            Logger.warning("[RC.Discord.Render] #{basename} GIF failed, posting PNG: #{inspect(error)}")
            nil
        end
      end

    if gif do
      {:ok, gif, basename <> ".gif"}
    else
      with {:ok, png} <- rasterize(render.(nil)), do: {:ok, png, basename <> ".png"}
    end
  end

  # svg string -> png file; the svg is written beside it, then removed
  defp rasterize_to({backend, bin}, svg, svg_path, png_path, width) do
    File.write!(svg_path, svg)

    case System.cmd(bin, args(backend, svg_path, png_path, width), stderr_to_stdout: true) do
      {_out, 0} -> :ok
      {out, code} -> {:error, {backend, code, out}}
    end
  after
    File.rm(svg_path)
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
