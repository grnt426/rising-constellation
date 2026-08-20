defmodule Portal.Plug.VerificationGateTest do
  use ExUnit.Case, async: true

  import Plug.Test

  alias RC.Accounts.Account

  defp run(method, path, status) do
    conn(method, path)
    |> Plug.Conn.put_private(:guardian_default_resource, %Account{id: 1, status: status})
    |> Portal.Plug.VerificationGate.call([])
  end

  test "writes are blocked for :registered accounts" do
    conn = run(:post, "/api/instances", :registered)

    assert conn.halted
    assert conn.status == 403
    assert conn.resp_body =~ "email_unverified"
  end

  test "reads pass for :registered accounts" do
    refute run(:get, "/api/instances", :registered).halted
    refute run(:get, "/api/account", :registered).halted
  end

  test "profile setup and settings writes pass for :registered accounts" do
    refute run(:post, "/api/accounts/7/profiles", :registered).halted
    refute run(:put, "/api/profiles/9", :registered).halted
    refute run(:delete, "/api/profiles/9", :registered).halted
    refute run(:post, "/api/accounts/settings", :registered).halted
  end

  test ":active accounts are untouched" do
    refute run(:post, "/api/instances", :active).halted
    refute run(:post, "/api/account/deletion", :active).halted
  end
end
