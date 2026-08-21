defmodule Portal.FallbackControllerTest do
  use Portal.APIConnCase

  alias RC.Accounts.Account

  test "a non-changeset transaction failure renders 500 JSON instead of crashing", %{conn: conn} do
    # Regression: format_errors/1 only accepts changesets, so this used to
    # raise FunctionClauseError (opaque 500 crash) for mail-provider
    # failures bubbling out of Multi.run steps.
    conn = Portal.FallbackController.call(conn, {:error, :send_email, {:ses, "rejected"}, %{}})

    assert json_response(conn, 500)["message"] == "general_error"
  end

  test "a changeset transaction failure still renders 400 field errors", %{conn: conn} do
    changeset = Account.changeset_password(%Account{}, %{})
    conn = Portal.FallbackController.call(conn, {:error, :account, changeset, %{}})

    assert json_response(conn, 400)["message"]["email"] == ["can't be blank"]
  end
end
