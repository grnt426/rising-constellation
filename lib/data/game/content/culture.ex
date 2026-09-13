defmodule Data.Game.Culture.Content do
  def data do
    [
      %Data.Game.Culture{
        key: :tetrarchic,
        firstname_repo: %{
          male: "male-firstname",
          female: "female-firstname"
        },
        lastname_repo: "tetrarchic-foundation"
      },
      %Data.Game.Culture{
        key: :myrmeziriannic,
        firstname_repo: %{
          male: "male-firstname",
          female: "female-firstname"
        },
        lastname_repo: "myrmeziriannic-foundation"
      },
      %Data.Game.Culture{
        key: :cardanic,
        firstname_repo: %{
          male: "male-firstname",
          female: "female-firstname"
        },
        lastname_repo: "cardanic-foundation"
      },
      %Data.Game.Culture{
        key: :syn,
        firstname_repo: %{
          male: "male-firstname",
          female: "female-firstname"
        },
        lastname_repo: "syn-foundation"
      },
      %Data.Game.Culture{
        key: :stelloliberalism,
        firstname_repo: %{
          male: "male-firstname",
          female: "female-firstname"
        },
        lastname_repo: "stelloliberalism-foundation"
      },
      # The Rebellion's culture. It has no name corpus of its own yet: both
      # repos alias the stelloliberalism lists in Data.Picker.index/0, so rebel
      # characters and rebel-sector system names read as fringe//corporate
      # frontier rather than as any of the four states. Give it dedicated
      # `priv/data/name/{place,foundation}/rebel.txt` files when the lore lands
      # — only the two Picker entries change.
      %Data.Game.Culture{
        key: :rebel,
        firstname_repo: %{
          male: "male-firstname",
          female: "female-firstname"
        },
        lastname_repo: "rebel-foundation"
      }
    ]
  end
end
