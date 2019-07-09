defmodule HordeTest.Application do
  @moduledoc false
  use Application
  use Supervisor
  def start(_type, _args) do
    topologies =[
      example: [
        strategy: Cluster.Strategy.Epmd,
        config: [hosts: [:"hordetest@h2778741", :"hordetest@BlackWidow"]],
      ]
    ]
    children=[
      {Cluster.Supervisor, [topologies, [name: Hordetest.ClusterSupervisor]]},
      {HordeSupervisor, [name: Hordetest.DistributedSupervisor, strategy: :one_for_one]}
    ]

    hordechilds=[

    ]

    opts=[strategy: :one_for_one, name: {:global, Hordetest.Supervisor}]
    Supervisor.start_link(children, opts)
  end
end
