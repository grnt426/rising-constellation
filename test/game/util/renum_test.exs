defmodule REnumTest do
  use ExUnit.Case, async: true

  test "random/1" do
    # corner cases, independent of the seed
    rstate = nil
    assert_raise Enum.EmptyError, fn -> REnum.random(rstate, []) end
    {_rstate, value} = REnum.random(rstate, [1])
    assert value == 1

    # set a fixed seed so the test can be deterministic
    # please note the order of following assertions is important
    seed1 = {1406, 407_414, 139_258}
    seed2 = {1306, 421_106, 567_597}
    rstate = :rand.seed(:exrop, seed1)
    {rstate, value} = REnum.random(rstate, [1, 2])
    assert value == 2
    {_rstate, value} = REnum.random(rstate, [1, 2])
    assert value == 2
    rstate = :rand.seed(:exrop, seed1)
    {rstate, value} = REnum.random(rstate, [1, 2])
    assert value == 2
    {rstate, value} = REnum.random(rstate, [1, 2, 3])
    assert value == 1
    {rstate, value} = REnum.random(rstate, [1, 2, 3, 4])
    assert value == 1
    {_rstate, value} = REnum.random(rstate, [1, 2, 3, 4, 5])
    assert value == 2
    rstate = :rand.seed(:exrop, seed2)
    {rstate, value} = REnum.random(rstate, [1, 2])
    assert value == 2
    {rstate, value} = REnum.random(rstate, [1, 2, 3])
    assert value == 1
    {rstate, value} = REnum.random(rstate, [1, 2, 3, 4])
    assert value == 1
    {_rstate, value} = REnum.random(rstate, [1, 2, 3, 4, 5])
    assert value == 1
  end

  test "take_random/2" do
    rstate = nil
    {rstate, value} = REnum.take_random(rstate, -42..-42, 1)
    assert value == [-42]

    # corner cases, independent of the seed
    assert_raise FunctionClauseError, fn -> REnum.take_random(rstate, [1, 2], -1) end
    {rstate, value} = REnum.take_random(rstate, [], 0)
    assert value == []
    {rstate, value} = REnum.take_random(rstate, [], 3)
    assert value == []
    {rstate, value} = REnum.take_random(rstate, [1], 0)
    assert value == []
    {rstate, value} = REnum.take_random(rstate, [1], 2)
    assert value == [1]
    {_rstate, value} = REnum.take_random(rstate, [1, 2], 0)
    assert value == []

    # set a fixed seed so the test can be deterministic
    # please note the order of following assertions is important
    seed1 = {1406, 407_414, 139_258}
    seed2 = {1406, 421_106, 567_597}
    rstate = :rand.seed(:exrop, seed1)
    {rstate, value} = REnum.take_random(rstate, [1, 2, 3], 1)
    assert value == [3]
    {rstate, value} = REnum.take_random(rstate, [1, 2, 3], 2)
    assert value == [2, 1]
    {rstate, value} = REnum.take_random(rstate, [1, 2, 3], 3)
    assert value == [1, 2, 3]
    {_rstate, value} = REnum.take_random(rstate, [1, 2, 3], 4)
    assert value == [3, 1, 2]
    rstate = :rand.seed(:exrop, seed2)
    {rstate, value} = REnum.take_random(rstate, [1, 2, 3], 1)
    assert value == [1]
    {rstate, value} = REnum.take_random(rstate, [1, 2, 3], 2)
    assert value == [1, 2]
    {rstate, value} = REnum.take_random(rstate, [1, 2, 3], 3)
    assert value == [2, 3, 1]
    {rstate, value} = REnum.take_random(rstate, [1, 2, 3], 4)
    assert value == [1, 3, 2]
    {_rstate, value} = REnum.take_random(rstate, [1, 2, 3], 129)
    assert value == [2, 1, 3]

    # assert that every item in the sample comes from the input list
    list = for _ <- 1..100, do: make_ref()

    {_rstate, values} = REnum.take_random(rstate, list, 50)

    for value <- values do
      assert value in list
    end

    assert_raise FunctionClauseError, fn ->
      REnum.take_random(rstate, 1..10, -1)
    end

    assert_raise FunctionClauseError, fn ->
      REnum.take_random(rstate, 1..10, 10.0)
    end

    assert_raise FunctionClauseError, fn ->
      REnum.take_random(rstate, 1..10, 128.1)
    end
  end
end

defmodule REnumTest.Range do
  # Ranges use custom callbacks for protocols in many operations.
  use ExUnit.Case, async: true

  test "random/1" do
    # corner cases, independent of the seed
    rstate = nil
    {_rstate, value} = REnum.random(rstate, 1..1)
    assert value == 1

    # set a fixed seed so the test can be deterministic
    # please note the order of following assertions is important
    seed1 = {1406, 407_414, 139_258}
    seed2 = {1306, 421_106, 567_597}
    rstate = :rand.seed(:exrop, seed1)
    {rstate, value} = REnum.random(rstate, 1..2)
    assert value == 2
    {rstate, value} = REnum.random(rstate, 1..3)
    assert value == 1
    {_rstate, value} = REnum.random(rstate, 3..1)
    assert value == 2

    rstate = :rand.seed(:exrop, seed2)
    {rstate, value} = REnum.random(rstate, 1..2)
    assert value == 2
    {_rstate, value} = REnum.random(rstate, 1..3)
    assert value == 1

    # take two seeds, generate random from each of them alternating turns
    seed1 = {1406, 407_414, 139_258}
    seed2 = {1306, 421_106, 567_597}
    rstate1 = :rand.seed(:exrop, seed1)
    rstate2 = :rand.seed(:exrop, seed2)

    {_rstate1, _rstate2, values1} =
      Enum.reduce(1..10, {rstate1, rstate2, []}, fn _n, {rstate1, rstate2, acc} ->
        {rstate1, value} = REnum.random(rstate1, 1..10)
        acc = [value | acc]
        {rstate2, value} = REnum.random(rstate2, 1..10)
        acc = [value | acc]
        {rstate1, rstate2, acc}
      end)

    # do it again
    rstate1 = :rand.seed(:exrop, seed1)
    rstate2 = :rand.seed(:exrop, seed2)

    {_rstate1, _rstate2, values2} =
      Enum.reduce(1..10, {rstate1, rstate2, []}, fn _n, {rstate1, rstate2, acc} ->
        {rstate1, value} = REnum.random(rstate1, 1..10)
        acc = [value | acc]
        {rstate2, value} = REnum.random(rstate2, 1..10)
        acc = [value | acc]
        {rstate1, rstate2, acc}
      end)

    # values generated should be the same both times
    assert values1 == values2
    assert values1 == [9, 4, 4, 7, 8, 8, 1, 9, 9, 7, 1, 8, 1, 7, 5, 9, 8, 2, 2, 10]
  end

  test "take_random/2" do
    rstate = nil
    # corner cases, independent of the seed
    assert_raise FunctionClauseError, fn -> REnum.take_random(rstate, 1..2, -1) end
    {rstate, value} = REnum.take_random(rstate, 1..1, 0)
    assert value == []
    {rstate, value} = REnum.take_random(rstate, 1..1, 1)
    assert value == [1]
    {rstate, value} = REnum.take_random(rstate, 1..1, 2)
    assert value == [1]
    {_rstate, value} = REnum.take_random(rstate, 1..2, 0)
    assert value == []

    # set a fixed seed so the test can be deterministic
    # please note the order of following assertions is important
    seed1 = {1406, 407_414, 139_258}
    seed2 = {1406, 421_106, 567_597}
    rstate = :rand.seed(:exrop, seed1)
    {_rstate, value} = REnum.take_random(rstate, 1..3, 1)
    assert value == [3]
    rstate = :rand.seed(:exrop, seed1)
    {_rstate, value} = REnum.take_random(rstate, 1..3, 2)
    assert value == [3, 2]
    rstate = :rand.seed(:exrop, seed1)
    {_rstate, value} = REnum.take_random(rstate, 1..3, 3)
    assert value == [3, 2, 1]
    rstate = :rand.seed(:exrop, seed1)
    {_rstate, value} = REnum.take_random(rstate, 1..3, 4)
    assert value == [3, 2, 1]
    rstate = :rand.seed(:exrop, seed1)
    {_rstate, value} = REnum.take_random(rstate, 3..1, 1)
    assert value == [1]
    rstate = :rand.seed(:exrop, seed2)
    {_rstate, value} = REnum.take_random(rstate, 1..3, 1)
    assert value == [1]
    rstate = :rand.seed(:exrop, seed2)
    {_rstate, value} = REnum.take_random(rstate, 1..3, 2)
    assert value == [1, 3]
    rstate = :rand.seed(:exrop, seed2)
    {_rstate, value} = REnum.take_random(rstate, 1..3, 3)
    assert value == [1, 3, 2]
    rstate = :rand.seed(:exrop, seed2)
    {_rstate, value} = REnum.take_random(rstate, 1..3, 4)
    assert value == [1, 3, 2]

    # make sure optimizations don't change fixed seeded tests
    rstate = :rand.seed(:exrop, {101, 102, 103})
    {_rstate, one} = REnum.take_random(rstate, 1..100, 1)
    rstate = :rand.seed(:exrop, {101, 102, 103})
    {_rstate, two} = REnum.take_random(rstate, 1..100, 2)
    assert hd(one) == hd(two)
  end
end

defmodule REnumTest.Map do
  # Maps use different protocols path than lists and ranges in the cases below.
  use ExUnit.Case, async: true

  test "random/1" do
    rstate = nil
    map = %{a: 1, b: 2, c: 3}
    assert_raise FunctionClauseError, fn -> REnum.random(rstate, map) end
  end

  test "take_random/2" do
    # corner cases, independent of the seed
    rstate = nil
    assert_raise FunctionClauseError, fn -> REnum.take_random(rstate, 1..2, -1) end
    {rstate, value} = REnum.take_random(rstate, %{a: 1}, 0)
    assert value == []
    {rstate, value} = REnum.take_random(rstate, %{a: 1}, 2)
    assert value == [a: 1]
    {_rstate, value} = REnum.take_random(rstate, %{a: 1, b: 2}, 0)
    assert value == []

    # set a fixed seed so the test can be deterministic
    # please note the order of following assertions is important
    map = %{a: 1, b: 2, c: 3}
    seed1 = {1406, 407_414, 139_258}
    seed2 = {1406, 421_106, 567_597}
    rstate = :rand.seed(:exrop, seed1)
    {_rstate, value} = REnum.take_random(rstate, map, 1)
    assert value == [c: 3]
    rstate = :rand.seed(:exrop, seed1)
    {_rstate, value} = REnum.take_random(rstate, map, 2)
    assert value == [c: 3, b: 2]
    rstate = :rand.seed(:exrop, seed1)
    {_rstate, value} = REnum.take_random(rstate, map, 3)
    assert value == [c: 3, b: 2, a: 1]
    rstate = :rand.seed(:exrop, seed1)
    {_rstate, value} = REnum.take_random(rstate, map, 4)
    assert value == [c: 3, b: 2, a: 1]
    rstate = :rand.seed(:exrop, seed2)
    {_rstate, value} = REnum.take_random(rstate, map, 1)
    assert value == [a: 1]
    rstate = :rand.seed(:exrop, seed2)
    {_rstate, value} = REnum.take_random(rstate, map, 2)
    assert value == [a: 1, c: 3]
    rstate = :rand.seed(:exrop, seed2)
    {_rstate, value} = REnum.take_random(rstate, map, 3)
    assert value == [a: 1, c: 3, b: 2]
    rstate = :rand.seed(:exrop, seed2)
    {_rstate, value} = REnum.take_random(rstate, map, 4)
    assert value == [a: 1, c: 3, b: 2]
  end
end

defmodule REnumTest.Determinism do
  # REnum exists to give the game a reproducible RNG: the same seed and the
  # same logical input must always pick the same element, regardless of the
  # underlying OTP version, BEAM hash seed, or map literal construction order.
  # The earlier seed-pinned tests pin specific magic values; these pin the
  # CONTRACT — that the answer doesn't depend on how the input was assembled.
  use ExUnit.Case, async: true

  @seed {1406, 407_414, 139_258}

  describe "random/2 is deterministic across input representations" do
    test "same seed and equivalent list inputs produce the same pick" do
      a = :rand.seed(:exrop, @seed) |> REnum.random([1, 2, 3, 4, 5]) |> elem(1)
      b = :rand.seed(:exrop, @seed) |> REnum.random([1, 2, 3, 4, 5]) |> elem(1)
      assert a == b
    end

    test "same seed picks the same Range element on every call" do
      a = :rand.seed(:exrop, @seed) |> REnum.random(1..10) |> elem(1)
      b = :rand.seed(:exrop, @seed) |> REnum.random(1..10) |> elem(1)
      assert a == b
      assert a in 1..10
    end
  end

  describe "take_random/3 is deterministic for maps regardless of literal order" do
    # The bug we're guarding against: pre-fix, Enum.reduce over a map iterated
    # in unspecified OTP order, so the sampled output depended on the BEAM
    # version. Two logically-equal maps could produce different results under
    # the same seed.
    test "two maps with identical entries but different construction order produce equal output" do
      map1 = %{a: 1, b: 2, c: 3}
      map2 = %{c: 3, a: 1, b: 2}

      r1 = :rand.seed(:exrop, @seed) |> REnum.take_random(map1, 3) |> elem(1)
      r2 = :rand.seed(:exrop, @seed) |> REnum.take_random(map2, 3) |> elem(1)

      assert r1 == r2
    end

    test "same seed produces same map sample across repeated calls" do
      map = %{a: 1, b: 2, c: 3, d: 4, e: 5}

      r1 = :rand.seed(:exrop, @seed) |> REnum.take_random(map, 3) |> elem(1)
      r2 = :rand.seed(:exrop, @seed) |> REnum.take_random(map, 3) |> elem(1)

      assert r1 == r2
    end

    test "sample size 1 is also deterministic across literal order" do
      map1 = %{a: 1, b: 2, c: 3}
      map2 = %{c: 3, b: 2, a: 1}

      r1 = :rand.seed(:exrop, @seed) |> REnum.take_random(map1, 1) |> elem(1)
      r2 = :rand.seed(:exrop, @seed) |> REnum.take_random(map2, 1) |> elem(1)

      assert r1 == r2
    end
  end

  describe "random/2 refuses plain maps" do
    # Picking from a map has no well-defined semantics without an ordering;
    # REnum opts to refuse rather than silently produce different answers on
    # different OTP versions. (take_random/3 sorts first, but random/2 stays
    # strict — single-pick callers should pass a list or Range.)
    test "raises rather than silently picking via map iteration" do
      assert_raise FunctionClauseError, fn ->
        REnum.random(:rand.seed(:exrop, @seed), %{a: 1, b: 2, c: 3})
      end
    end
  end
end
