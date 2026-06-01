defmodule Spatial.Supervisor do
  use Supervisor
  use DDRT.DynamicRtree
  alias DDRT.DynamicRtree

  @spec start_link(DynamicRtree.tree_config()) :: {:ok, pid}
  def start_link(opts) do
    instance_id = Keyword.get(opts, :id)

    Supervisor.start_link(__MODULE__, opts, name: Game.via_tuple({instance_id, :spatial_supervisor}))
  end

  def init(opts) do
    name = Keyword.get(opts, :name, DynamicRtree)

    children = [
      {DeltaCrdt,
       [
         crdt: DeltaCrdt.AWLWWMap,
         name: Module.concat([name, Crdt]),
         on_diffs: &on_diffs(&1, DynamicRtree, name)
       ]},
      {DynamicRtree,
       [
         conf: Keyword.put_new(opts, :mode, :distributed),
         crdt: Module.concat([name, Crdt]),
         name: name
       ]},
      {Spatial.Handoff, opts}
    ]

    Supervisor.init(children,
      strategy: :one_for_one,
      name: Module.concat([name, Supervisor]),
      # Stage 7 F14: explicit budget. Spatial.Supervisor co-locates
      # DeltaCrdt + DynamicRtree + Spatial.Handoff; a transient blip
      # in any one would otherwise consume the OTP default 3/5s budget
      # and tear down spatial state for the whole instance.
      max_restarts: 50,
      max_seconds: 60
    )
  end

  @doc false
  def on_diffs(diffs, mod, name) do
    mod.merge_diffs(diffs, name)
  end
end
