defmodule RC.Repo.Migrations.RemoveCalculatorBetaFlag do
  use Ecto.Migration

  # The in-game calculator graduated from beta to a standard feature; the
  # key is gone from AccountFeature.known/0, so opt-in rows are now inert.
  def up do
    execute("DELETE FROM account_features WHERE feature = 'calculator'")
  end

  def down do
    :ok
  end
end
