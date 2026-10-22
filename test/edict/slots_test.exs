defmodule Edict.SlotsTest do
  use ExUnit.Case, async: true

  alias Edict.Slots

  defp key, do: {:slots_test, make_ref()}

  defp eventually(check, tries \\ 50) do
    cond do
      check.() -> true
      tries == 0 -> false
      true -> Process.sleep(10) && eventually(check, tries - 1)
    end
  end

  # a holder that keeps its slot until told to let go
  defp hold(limits) do
    parent = self()

    pid =
      spawn(fn ->
        Slots.run(limits, fn ->
          send(parent, {:holding, self()})

          receive do
            :let_go -> :ok
          end
        end)
      end)

    assert_receive {:holding, ^pid}
    pid
  end

  test "a slot is held while the work runs and given back after" do
    k = key()
    holder = hold([{k, 1}])
    assert Slots.held(k) == 1
    assert Slots.run([{k, 1}], fn -> :never end, 0) == {:error, :busy}

    send(holder, :let_go)
    assert eventually(fn -> Slots.held(k) == 0 end)
    assert Slots.run([{k, 1}], fn -> :again end, 0) == {:ok, :again}
  end

  test "the limit counts holders: two may work at once, the third waits" do
    k = key()
    a = hold([{k, 2}])
    _b = hold([{k, 2}])
    assert Slots.run([{k, 2}], fn -> :third end, 0) == {:error, :busy}

    # a slot that frees up while the third waits is taken
    spawn(fn -> Process.sleep(100) && send(a, :let_go) end)
    assert Slots.run([{k, 2}], fn -> :third end, 2_000) == {:ok, :third}
  end

  test "every limit needs room: a full global slot stops another account" do
    global = key()
    hold([{{:account, 1}, 2}, {global, 1}])
    assert Slots.run([{{:account, 2}, 2}, {global, 1}], fn -> :x end, 0) == {:error, :busy}
  end

  test "a request that dies or raises doesn't keep its slot" do
    k = key()
    killed = hold([{k, 1}])
    Process.exit(killed, :kill)
    assert eventually(fn -> Slots.held(k) == 0 end)

    assert_raise RuntimeError, fn -> Slots.run([{k, 1}], fn -> raise "boom" end, 0) end
    assert eventually(fn -> Slots.held(k) == 0 end)
  end
end
