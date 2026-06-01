defmodule RC.Instances.RegistrationStateMachine do
  alias Ecto.Multi
  alias RC.Accounts
  alias RC.Instances.Registration
  alias RC.Instances.RegistrationState
  alias RC.Repo

  require Logger

  use Machinery,
    states: ["joined", "playing", "resigned", "dead"],
    transitions: %{
      "joined" => ["playing"],
      "playing" => ["resigned", "dead"]
    }

  def log_transition(%Registration{id: rid} = registration, next_state) do
    {:ok, _registration_state} = create_registration_state(%{registration_id: rid, state: next_state})
    registration
  end

  def after_transition(%Registration{} = registration, _state) do
    profile = Accounts.get_profile(registration.profile_id)

    case profile do
      {:error, reason} -> Logger.error("#{reason}")
      _ -> nil
    end

    registration
  end

  defp create_registration_state(%{registration_id: rid, state: state} = attrs) do
    registration_state = RegistrationState.changeset(%RegistrationState{}, attrs)

    # Rotate the registration token on terminal transitions so a captured
    # token can never re-authorize a channel join after the player has
    # resigned or been killed. The new value is never returned to the
    # client — the registration is dead — so it's effectively unrecoverable.
    registration_attrs =
      if state in ["resigned", "dead"] do
        %{state: state, token: Registration.generate_token()}
      else
        %{state: state}
      end

    registration =
      Repo.get_by(Registration, id: rid)
      |> Registration.changeset(registration_attrs)

    Multi.new()
    |> Multi.insert(:registration_state, registration_state)
    |> Multi.update(:registration, registration)
    |> Repo.transaction()
  end
end
