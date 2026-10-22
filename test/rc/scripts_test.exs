defmodule RC.ScriptsTest do
  use RC.DataCase, async: true

  import RC.Fixtures

  alias RC.Scripts

  defp account!(n \\ 1) do
    {:ok, account} =
      create_account(%{
        "email" => "scripter#{n}-#{System.unique_integer([:positive])}@user",
        "role" => "user",
        "name" => "Scripter#{n}#{System.unique_integer([:positive])}",
        "password" => "a long enough password",
        "hashed_password" => "x",
        "status" => "active"
      })

    account
  end

  defp source(name, body \\ "score player.credit"),
    do: ~s|setup {\n  name = "#{name}"\n  description = "About #{name}."\n}\n\n#{body}\n|

  test "a saved script keeps its canonical text, digest, name and error count" do
    account = account!()
    {:ok, script} = Scripts.create(account.id, %{"source" => source("Tithe") <> "\n\n", "layout" => %{"pos" => %{}}})

    assert script.name == "Tithe"
    assert script.description == "About Tithe."
    assert script.source == source("Tithe")
    assert script.digest == Scripts.digest(script.source)
    assert script.error_count == 0
    assert %{"decls" => [_ | _]} = script.program

    {:ok, broken} = Scripts.create(account.id, %{"source" => source("Typo", "score player.credt")})
    assert broken.error_count == 1

    # the editor's tree works as well as text, and keeps its node ids
    {:ok, from_tree} = Scripts.create(account.id, %{"program" => script.program})
    assert from_tree.source == script.source
    assert from_tree.program == script.program

    assert {:error, {:invalid, _}} = Scripts.create(account.id, %{"source" => "setup {"})
    assert {:error, {:invalid, _}} = Scripts.create(account.id, %{})
  end

  test "an account keeps ten scripts at most" do
    account = account!()
    for i <- 1..10, do: {:ok, _} = Scripts.create(account.id, %{"source" => source("S#{i}")})
    assert {:error, :limit} = Scripts.create(account.id, %{"source" => source("S11")})
    assert length(Scripts.list_mine(account.id)) == 10

    # another account is unaffected
    assert {:ok, _} = Scripts.create(account!(2).id, %{"source" => source("Other")})
  end

  test "publishing: clean scripts only, never a copy of another published one, always the saved version" do
    alice = account!(1)
    bob = account!(2)
    {:ok, broken} = Scripts.create(alice.id, %{"source" => source("Typo", "score player.credt")})
    assert {:error, :has_errors} = Scripts.publish(broken)

    {:ok, tithe} = Scripts.create(alice.id, %{"source" => source("Tithe")})
    {:ok, tithe} = Scripts.publish(tithe)
    assert tithe.published_at
    assert [%{id: id}] = Scripts.list_published()
    assert id == tithe.id

    # bob copies it unchanged: saving is fine, publishing is not
    {:ok, copy} = Scripts.create(bob.id, %{"source" => tithe.source})
    assert {:error, {:duplicate, %{id: ^id}}} = Scripts.publish(copy)

    # a changed copy publishes
    {:ok, changed} = Scripts.update(copy, %{"source" => source("Bob's tithe")})
    assert {:ok, _} = Scripts.publish(changed)

    # what others see is what the author saved last; a published script stays clean
    {:ok, tithe} = Scripts.update(tithe, %{"source" => source("Tithe", "score player.credit * 2")})
    assert Scripts.get(tithe.id).source =~ "player.credit * 2"
    assert {:error, :has_errors} = Scripts.update(tithe, %{"source" => source("Tithe", "score player.credt")})
    assert {:error, {:duplicate, _}} = Scripts.update(tithe, %{"source" => source("Bob's tithe")})

    {:ok, tithe} = Scripts.unpublish(tithe)
    refute tithe.published_at
    assert Enum.map(Scripts.list_published(), & &1.name) == ["Bob's tithe"]
    assert [_] = Scripts.list_published(search: "bob")
    assert [] = Scripts.list_published(search: "%")
  end

  test "who sees what: your own scripts, and published ones" do
    alice = account!(1)
    bob = account!(2)
    {:ok, private} = Scripts.create(alice.id, %{"source" => source("Mine")})
    {:ok, public} = Scripts.create(alice.id, %{"source" => source("Ours")})
    {:ok, public} = Scripts.publish(public)

    assert Scripts.get_visible(private.id, alice.id)
    refute Scripts.get_visible(private.id, bob.id)
    assert Scripts.get_visible(public.id, bob.id)
    refute Scripts.get_visible("nope", bob.id)
  end

  test "attaching freezes the current version, and keeps a copy that is no longer available" do
    alice = account!(1)
    bob = account!(2)
    {:ok, mine} = Scripts.create(bob.id, %{"source" => source("Bob's")})
    {:ok, theirs} = Scripts.create(alice.id, %{"source" => source("Alice's")})
    {:ok, theirs} = Scripts.publish(theirs)
    {:ok, hidden} = Scripts.create(alice.id, %{"source" => source("Hidden")})

    frozen = Scripts.attach([mine.id, %{"id" => theirs.id, "source" => "evil"}, hidden.id, "x"], bob.id)
    assert Enum.map(frozen, & &1["name"]) == ["Bob's", "Alice's"]
    assert Enum.at(frozen, 1)["source"] == theirs.source
    assert Enum.at(frozen, 1)["author"] == alice.name

    # alice unpublishes: bob's scenario keeps the copy it had
    {:ok, _} = Scripts.unpublish(theirs)
    previous = %{"scripts" => frozen}
    assert Scripts.attach([mine.id, theirs.id], bob.id, previous) == frozen

    # three at most
    more = for i <- 1..4, do: elem(Scripts.create(bob.id, %{"source" => source("More #{i}")}), 1).id
    assert length(Scripts.attach(more, bob.id)) == Edict.Attachment.max_scripts()
  end

  test "deleting removes the script; names reject direction-override characters" do
    account = account!()
    {:ok, script} = Scripts.create(account.id, %{"source" => source("Gone")})
    {:ok, _} = Scripts.delete(script)
    refute Scripts.get(script.id)

    rlo = <<0x202E::utf8>>
    assert {:error, _} = Scripts.create(account.id, %{"source" => source("evil" <> rlo <> "txt")})
    assert Scripts.list_mine(account.id) == []
  end
end
