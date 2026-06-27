defmodule Data.Game.Speed.Content do
  def data do
    [
      %Data.Game.Speed{
        key: :fast,
        value: 1,
        factor: 120
      },
      %Data.Game.Speed{
        key: :medium,
        value: 2,
        factor: 20
      },
      %Data.Game.Speed{
        key: :slow,
        value: 3,
        factor: 1
      },
      # Daily-challenge speed. Content-wise it's identical to :slow ("Legacy"):
      # no speed-branching Data module defines a :daily variant, so each falls
      # back to its last spec, which is the :slow one (locked by
      # test/daily/speed_test.exs). The factor, though, is a fast clock so a
      # ~30-minute daily covers a meaningful economic arc (240 = 2x :fast).
      # selectable: false keeps it out of the scenario editor's speed picker.
      %Data.Game.Speed{
        key: :daily,
        value: 4,
        factor: 240,
        selectable: false
      }
    ]
  end
end
