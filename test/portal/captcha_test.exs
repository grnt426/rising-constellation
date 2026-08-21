defmodule Portal.CaptchaTest do
  # async: false — mutates the global Portal.Captcha config.
  use ExUnit.Case, async: false

  alias Portal.Captcha

  setup do
    previous = Application.get_env(:rc, Portal.Captcha)

    Application.put_env(:rc, Portal.Captcha, hmac_key: "unit-test-key", max_number: 200, expires_s: 60)
    on_exit(fn -> Application.put_env(:rc, Portal.Captcha, previous) end)

    :ok
  end

  defp solve(challenge) do
    %{number: number} =
      Altcha.V1.solve_challenge(
        challenge["challenge"],
        challenge["salt"],
        :sha256,
        challenge["maxnumber"]
      )

    %{
      algorithm: challenge["algorithm"],
      challenge: challenge["challenge"],
      number: number,
      salt: challenge["salt"],
      signature: challenge["signature"],
      took: 1
    }
  end

  defp encode(map), do: map |> Jason.encode!() |> Base.encode64()

  test "enabled? follows the hmac_key" do
    assert Captcha.enabled?()

    Application.put_env(:rc, Portal.Captcha, hmac_key: nil)
    refute Captcha.enabled?()
  end

  test "a solved challenge verifies exactly once" do
    payload = Captcha.create_challenge() |> solve() |> encode()

    assert Captcha.verify(payload) == :ok
    # replay of the same one-time token
    assert Captcha.verify(payload) == {:error, :captcha_failed}
  end

  test "a wrong number fails" do
    solved = Captcha.create_challenge() |> solve()
    payload = solved |> Map.put(:number, solved.number + 1) |> encode()

    assert Captcha.verify(payload) == {:error, :captcha_failed}
  end

  test "an expired challenge fails even when correctly solved" do
    Application.put_env(:rc, Portal.Captcha, hmac_key: "unit-test-key", max_number: 200, expires_s: -1)
    payload = Captcha.create_challenge() |> solve() |> encode()

    assert Captcha.verify(payload) == {:error, :captcha_failed}
  end

  test "a salt without our expires param fails" do
    challenge =
      %Altcha.V1.ChallengeOptions{hmac_key: "unit-test-key", max_number: 200}
      |> Altcha.V1.create_challenge()
      |> Jason.encode!()
      |> Jason.decode!()

    assert Captcha.verify(challenge |> solve() |> encode()) == {:error, :captcha_failed}
  end

  test "a payload signed with a different key fails" do
    challenge =
      %Altcha.V1.ChallengeOptions{
        hmac_key: "somebody-elses-key",
        max_number: 200,
        expires: DateTime.to_unix(DateTime.utc_now()) + 60
      }
      |> Altcha.V1.create_challenge()
      |> Jason.encode!()
      |> Jason.decode!()

    assert Captcha.verify(challenge |> solve() |> encode()) == {:error, :captcha_failed}
  end

  test "payloads with unexpected keys are rejected before reaching the lib" do
    payload = Captcha.create_challenge() |> solve() |> Map.put(:garbage_key_9137, "x") |> encode()

    assert Captcha.verify(payload) == {:error, :captcha_failed}
  end

  test "garbage payloads fail" do
    assert Captcha.verify(nil) == {:error, :captcha_failed}
    assert Captcha.verify(123) == {:error, :captcha_failed}
    assert Captcha.verify("not base64!!") == {:error, :captcha_failed}
    assert Captcha.verify(Base.encode64("[1,2,3]")) == {:error, :captcha_failed}
    assert Captcha.verify(String.duplicate("A", 10_000)) == {:error, :captcha_failed}
  end
end
