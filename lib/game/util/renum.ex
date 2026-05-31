defmodule REnum do
  @moduledoc """
  Deterministic reimplementation of Enum.random and Enum.take_random
  """
  def random(rstate, enumerable) when is_list(enumerable) do
    case length(enumerable) do
      0 ->
        raise Enum.EmptyError

      length ->
        {rstate, int} = random_integer(rstate, 0, length - 1)
        {rstate, enumerable |> Enum.drop(int) |> hd()}
    end
  end

  # Plain maps have no defined iteration order; refuse them so determinism
  # can't silently break across OTP versions. Structs (Range, MapSet, …) are
  # allowed to flow through the slice-based path below.
  def random(rstate, enumerable) when not is_map(enumerable) or is_struct(enumerable) do
    result =
      case Enumerable.slice(enumerable) do
        {:ok, 0, _} ->
          {rstate, []}

        {:ok, count, fun} when is_function(fun, 3) ->
          # modern Range: fun.(start, length, step)
          {rstate, rand} = random_integer(rstate, 0, count - 1)
          {rstate, fun.(rand, 1, 1)}

        {:ok, count, fun} when is_function(fun, 2) ->
          # legacy slice: fun.(start, length)
          {rstate, rand} = random_integer(rstate, 0, count - 1)
          {rstate, fun.(rand, 1)}

        {:error, _} ->
          take_random(rstate, enumerable, 1)
      end

    case result do
      {_rstate, []} -> raise Enum.EmptyError
      {rstate, [elem]} -> {rstate, elem}
    end
  end

  defp random_integer(rstate, limit, limit) when is_integer(limit) do
    {rstate, limit}
  end

  defp random_integer(rstate, lower_limit, upper_limit) when upper_limit < lower_limit do
    random_integer(rstate, upper_limit, lower_limit)
  end

  defp random_integer(rstate, lower_limit, upper_limit) do
    {rand, rstate} = :rand.uniform_s(upper_limit - lower_limit + 1, rstate)
    {rstate, lower_limit + rand - 1}
  end

  def take_random(rstate, _enumerable, 0), do: {rstate, []}

  def take_random(rstate, [], _), do: {rstate, []}
  def take_random(rstate, [h | t], 1), do: take_random_list_one(rstate, t, h, 1)

  # Map iteration order is unspecified across OTP versions, which would make
  # output depend on the runtime rather than the seed. Sort by key first so
  # the determinism contract holds regardless of OTP version. Plain maps only —
  # structs (Range, MapSet, …) keep their own iteration semantics.
  def take_random(rstate, enumerable, count) when is_map(enumerable) and not is_struct(enumerable) do
    take_random(rstate, Enum.sort(enumerable), count)
  end

  def take_random(rstate, enumerable, 1) do
    enumerable
    |> Enum.reduce({rstate, []}, fn
      x, {rstate, [current | index]} ->
        {rand, rstate} = :rand.uniform_s(index + 1, rstate)

        if rand == 1 do
          {rstate, [x | index + 1]}
        else
          {rstate, [current | index + 1]}
        end

      x, {rstate, []} ->
        {rstate, [x | 1]}
    end)
    |> case do
      {rstate, []} -> {rstate, []}
      {rstate, [current | _index]} -> {rstate, [current]}
    end
  end

  def take_random(rstate, enumerable, count) when is_integer(count) and count in 0..128 do
    sample = Tuple.duplicate(nil, count)

    reducer = fn elem, {rstate, idx, sample} ->
      {rstate, jdx} = random_integer(rstate, 0, idx)

      cond do
        idx < count ->
          value = elem(sample, jdx)
          {rstate, idx + 1, put_elem(sample, idx, value) |> put_elem(jdx, elem)}

        jdx < count ->
          {rstate, idx + 1, put_elem(sample, jdx, elem)}

        true ->
          {rstate, idx + 1, sample}
      end
    end

    {rstate, size, sample} = Enum.reduce(enumerable, {rstate, 0, sample}, reducer)
    {rstate, sample |> Tuple.to_list() |> Enum.take(Kernel.min(count, size))}
  end

  def take_random(rstate, enumerable, count) when is_integer(count) and count >= 0 do
    reducer = fn elem, {rstate, idx, sample} ->
      {rstate, jdx} = random_integer(rstate, 0, idx)

      cond do
        idx < count ->
          value = Map.get(sample, jdx)
          {rstate, idx + 1, Map.put(sample, idx, value) |> Map.put(jdx, elem)}

        jdx < count ->
          {rstate, idx + 1, Map.put(sample, jdx, elem)}

        true ->
          {rstate, idx + 1, sample}
      end
    end

    {rstate, size, sample} = Enum.reduce(enumerable, {rstate, 0, %{}}, reducer)
    take_random(rstate, sample, Kernel.min(count, size), [])
  end

  defp take_random(rstate, _sample, 0, acc), do: {rstate, acc}

  defp take_random(rstate, sample, position, acc) do
    position = position - 1
    take_random(rstate, sample, position, [Map.get(sample, position) | acc])
  end

  defp take_random_list_one(rstate, [h | t], current, index) do
    {rand, rstate} = :rand.uniform_s(index + 1, rstate)

    if rand == 1 do
      take_random_list_one(rstate, t, h, index + 1)
    else
      take_random_list_one(rstate, t, current, index + 1)
    end
  end

  defp take_random_list_one(rstate, [], current, _), do: {rstate, [current]}
end
