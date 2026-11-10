defmodule RC.Portraits do
  @moduledoc """
  Player portraits (`profiles.avatar`) and the opt-in AI-generated set.

  The classic portraits (`avatar[MF]_NNN.jpg`) are the original artwork.
  The `portrait*` set was made with AI image generation. Players see it
  only after turning on "AI-generated portraits" in Settings
  (`settings.aigc_portraits`). Everyone else, and every place with no
  known viewer (the Discord `/player` card), sees the classic stand-in
  paired with it below.

  The SPA swaps on its side: `front/src/utils/portraits.js` holds the same
  table (a node test checks the two agree), and `<card-art>` applies it.
  """

  @classic for g <- ~w(M F), n <- 1..7, do: "avatar#{g}_00#{n}.jpg"

  # AI portrait => classic stand-in: a look-alike where there is one
  # (hair, age, build), spread so few stand-ins repeat.
  @aigc %{
    "portraitF_001.jpg" => "avatarF_006.jpg",
    "portraitF_002.jpg" => "avatarF_004.jpg",
    "portraitF_003.jpg" => "avatarF_002.jpg",
    "portraitF_004.jpg" => "avatarF_003.jpg",
    "portraitF_005.jpg" => "avatarF_001.jpg",
    "portraitF_006.jpg" => "avatarF_005.jpg",
    "portraitF_007.jpg" => "avatarF_007.jpg",
    "portraitF_008.jpg" => "avatarF_003.jpg",
    "portraitM_001.jpg" => "avatarM_001.jpg",
    "portraitM_002.jpg" => "avatarM_007.jpg",
    "portraitM_003.jpg" => "avatarM_004.jpg",
    "portraitM_004.jpg" => "avatarM_003.jpg",
    "portraitM_005.jpg" => "avatarM_005.jpg",
    "portraitM_006.jpg" => "avatarM_006.jpg",
    "portraitM_007.jpg" => "avatarM_002.jpg",
    "portraitM_008.jpg" => "avatarM_004.jpg",
    "portraitR_001.jpg" => "avatarF_002.jpg",
    "portraitR_002.jpg" => "avatarM_002.jpg",
    "portraitR_003.jpg" => "avatarM_006.jpg",
    "portraitR_004.jpg" => "avatarM_005.jpg"
  }

  @doc "The classic (original artwork) portrait filenames."
  def classic, do: @classic

  @doc "AI portrait filename => its classic stand-in."
  def aigc, do: @aigc

  def aigc?(avatar), do: Map.has_key?(@aigc, avatar)

  @doc """
  The portrait to show someone who has not opted in to AI-generated
  portraits, or when the viewer is unknown: the classic stand-in for an
  AI portrait, anything else unchanged.
  """
  def public_avatar(avatar), do: Map.get(@aigc, avatar, avatar)
end
