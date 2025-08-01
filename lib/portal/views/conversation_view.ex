defmodule Portal.ConversationView do
  use Portal, :view
  import Phoenix.View, only: [render_one: 3, render_many: 3, render_one: 4, render_many: 4]
  alias Portal.ConversationView

  def render("index.json", %{conversations: conversations}) do
    render_many(conversations, ConversationView, "conversation.json")
  end

  def render("show.json", %{conversation: conversation}) do
    render_one(conversation, ConversationView, "conversation.json")
  end

  def render("conversation.json", %{conversation: conversation}) do
    view = %{
      id: conversation.id,
      iid: conversation.instance_id,
      name: conversation.name,
      is_group: conversation.is_group,
      is_faction: conversation.is_faction,
      unread: conversation.unread,
      last_message_update: conversation.last_message_update
    }

    if Ecto.assoc_loaded?(conversation.conversation_members),
      do:
        Map.put(
          view,
          :members,
          render_many(conversation.conversation_members, Portal.ConversationMemberView, "conversation_member.json")
        ),
      else: view
  end
end
