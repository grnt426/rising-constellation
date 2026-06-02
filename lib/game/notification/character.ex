defmodule Notification.Character do
  @moduledoc """
  Notification-payload variant of character obfuscation.

  Stage 8 (info disclosure) follow-up. The optional
  `viewer_faction_key` arg is passed through to
  `Instance.Faction.Character.obfuscate/3` so that:

    * When the notification is going to the OWNER of the character
      (e.g. the attacker viewing their own admiral in `attacker_data`),
      the caller supplies `attacker.owner.faction` and the obfuscation
      keeps the full struct (action_status + skills + doctrine details).

    * When the notification is going to a non-owner (the defender of
      a raid/conquest/loot/etc), the caller omits the argument (or
      passes a lower `visibility`), and the obfuscation strips
      `:action_status` + Core.Value.details.

  Defaulting `viewer_faction_key` to `nil` ON THIS CALL SITE means a
  caller that forgets to pass it gets the *safer* behavior — under-
  exposed, not over-exposed. The attacker-side helpers in this file's
  callers now explicitly pass the owner faction key for own-view paths.
  """
  def convert(character, visibility \\ 5, viewer_faction_key \\ nil) do
    Instance.Faction.Character.obfuscate(character, visibility, viewer_faction_key)
  end

  def diff(previous, current, visibility \\ 5, viewer_faction_key \\ nil) do
    %{
      previous: Notification.Character.convert(previous, visibility, viewer_faction_key),
      current: Notification.Character.convert(current, visibility, viewer_faction_key)
    }
  end
end
