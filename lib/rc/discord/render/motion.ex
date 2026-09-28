defmodule RC.Discord.Render.Motion do
  @moduledoc """
  Timing curves for the animated (GIF) news cards.

  Renderers take a loop phase `t` in `[0, 1)` — `nil` means the static
  PNG card, which must render exactly as it did before animation
  existed. Every curve here returns to its starting value at `t = 1`,
  so the GIF loops without a seam, and sits at rest at `t = 0`, so the
  first frame (what Discord shows with autoplay off) reads like the
  static card.
  """

  alias RC.Discord.Render.Style

  @spin_window 0.4

  @doc """
  Spin-then-rest for five-point stars: eases through `degrees` (a
  multiple of 72, so the star lands on an identical pose) during the
  first `window` fraction of the loop after `delay` (default 40%), then
  holds still. Returns `{angle, progress}` where progress runs 0→1
  across the spin and is 0 while resting.
  """
  def spin(t, delay \\ 0.0, degrees \\ 144, window \\ @spin_window) do
    local = frac(t - delay)

    if local < window do
      p = local / window
      {degrees * ease_in_out(p), p}
    else
      {degrees * 1.0, 0.0}
    end
  end

  @doc """
  Progress 0→1 through a one-off beat of length `window` starting at
  `delay` (wrapping), and 0 outside it — for glints and flashes that
  fire once per loop and rest.
  """
  def beat(t, delay, window) do
    local = frac(t - delay)
    if local < window, do: local / window, else: 0.0
  end

  @doc """
  Fill-in-then-hold, arranged so the loop's FIRST frame is already
  full: holds at 1.0, and during the final `window` of the loop drops
  to empty and eases back up to full.
  """
  def fill_in(t, window \\ 0.2) do
    start = 1 - window

    if t < start do
      1.0
    else
      p = (t - start) / window
      1 - :math.pow(1 - p, 3)
    end
  end

  @doc "Wraps a phase into [0, 1)."
  def frac(x), do: x - Float.floor(x * 1.0)

  @doc "Ease-out cubic on 0..1."
  def ease_out(p), do: 1 - :math.pow(1 - p, 3)

  @doc "Smooth 0→1→0 pulse over one loop, 0 at t = 0."
  def pulse(t), do: 0.5 - 0.5 * :math.cos(2 * :math.pi() * t)

  @doc "Gentle grow/shrink factor around 1.0."
  def breathe(t, amplitude, phase \\ 0.0), do: 1 + amplitude * :math.sin(2 * :math.pi() * (t + phase))

  @doc "A 0→1→0 hump across a spin's progress (0 while resting)."
  def hump(progress), do: :math.sin(:math.pi() * progress)

  @doc "SVG transform attribute rotating about a point (\"\" when still)."
  def rotate(deg, _cx, _cy) when deg == 0, do: ""
  def rotate(deg, cx, cy), do: ~s{ transform="rotate(#{Style.fnum(deg * 1.0)} #{Style.fnum(cx)} #{Style.fnum(cy)})"}

  @doc "SVG transform attribute rotating then scaling about a point."
  def rotate_scale(deg, scale, cx, cy) do
    ~s{ transform="translate(#{Style.fnum(cx)} #{Style.fnum(cy)}) rotate(#{Style.fnum(deg * 1.0)}) scale(#{Style.fnum(scale * 1.0)}) translate(#{Style.fnum(-cx)} #{Style.fnum(-cy)})"}
  end

  @doc """
  A stroke-dasharray that tiles a circle of radius `r` with exactly
  `count` dashes, so rotating the ring by 360/count degrees is seamless.
  """
  def ring_dashes(r, count) do
    period = 2 * :math.pi() * r / count
    "#{Style.fnum(period * 0.58)},#{Style.fnum(period * 0.42)}"
  end

  defp ease_in_out(p) when p < 0.5, do: 4 * p * p * p
  defp ease_in_out(p), do: 1 - :math.pow(-2 * p + 2, 3) / 2
end
