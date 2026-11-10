defmodule RC.PortraitsTest do
  use ExUnit.Case, async: true

  alias RC.Portraits

  test "AI portraits map to a classic stand-in; everything else passes through" do
    assert Portraits.public_avatar("portraitF_001.jpg") == "avatarF_006.jpg"
    assert Portraits.public_avatar("avatarM_003.jpg") == "avatarM_003.jpg"
    assert Portraits.public_avatar("todo") == "todo"
    assert Portraits.public_avatar(nil) == nil
  end

  test "every stand-in is a classic portrait the server can read" do
    avatars = Path.join(to_string(:code.priv_dir(:rc)), "data/avatars")

    for {aigc, stand_in} <- Portraits.aigc() do
      assert stand_in in Portraits.classic(), "#{aigc} -> #{stand_in} is not classic"
      assert File.exists?(Path.join(avatars, stand_in)), "#{stand_in} missing from priv"
    end
  end

  test "the two sets don't overlap" do
    for avatar <- Portraits.classic(), do: refute(Portraits.aigc?(avatar))
    assert map_size(Portraits.aigc()) == 20
  end
end
