defmodule Hordetest.Cluster do
  @connect_env "HORDE_TEST_NODE"

  require Logger

  def start_link(opts \\ []) do
    sup = start_supervisor()
    connect_initial_nodes(opts)
    {:ok, sup}
  end

  def stop() do
    Supervisor.stop(Hordetest.Cluster.Supervisor)
  end

  def start_payload_process(payload_spec, payload_id) do
    {:ok, supervisor_pid} = Horde.Supervisor.start_child(Hordetest.HordeSupervisor, payload_spec)
    {:ok, supervisor_pid}
  end

  def stop_game(game_id) do
    Hordetest.Game.down(Hordetest.Cluster.game_process(game_id))
    Horde.Registry.unregister(Hordetest.HordeRegistry, game_id)

    Horde.Supervisor.terminate_child(
      Hordetest.HordeSupervisor,
      Hordetest.Game.supervisor_process_id(game_id)
    )

    :ok
  end

  def list_game_ids() do
    Hordetest.HordeRegistry
    |> Horde.Registry.processes()
    |> Map.keys()
  end

  def load_game_meta(game_ids) do
    Enum.map(game_ids, fn game_id ->
      try do
        game_id
        |> game_process()
        |> GenServer.call({:meta})
        |> case do
          {:ok, meta} -> meta
          {:error, _} -> nil
        end
      catch
        :exit, {:noproc, _} -> nil
      end
    end)
  end

  def game_alive?(game_id) do
    Horde.Registry.lookup(Hordetest.HordeRegistry, game_id) != :undefined
  end

  def list_nodes() do
    {:ok, members} = Horde.Cluster.members(Hordetest.HordeSupervisor)
    members |> Map.keys() |> Enum.sort()
  end

  def update_nodes() do
    nodes = Enum.sort([Node.self() | Node.list()])
    Logger.info("**** Node list updated to #{inspect(nodes)}")
    Horde.Cluster.set_members(Hordetest.HordeHandoff,
                              Enum.map(nodes, fn n -> {Hordetest.HordeHandoff, n} end))
    Horde.Cluster.set_members(Hordetest.HordeSupervisor,
                              Enum.map(nodes, fn n -> {Hordetest.HordeSupervisor, n} end))
    Horde.Cluster.set_members(Hordetest.HordeRegistry,
                              Enum.map(nodes, fn n -> {Hordetest.HordeRegistry, n} end))
    nodes
  end

  @spec game_process(any) :: {:via, Horde.Registry, {Hordetest.HordeRegistry, any}}
  def game_process(game_id), do: {:via, Horde.Registry, {Hordetest.HordeRegistry, game_id}}

  def list_live_game_ids() do
    GenServer.call(Hordetest.Cluster.Tracker, {:list_live_game_ids})
  end

  def add_receiver(receiver, message) do
    GenServer.call(Hordetest.Cluster.Tracker, {:add_receiver, receiver, message})
  end


  defp start_supervisor() do
    children = [
      {Hordetest.Handoff, name: Hordetest.HordeHandoff},
      {Horde.Supervisor, name: Hordetest.HordeSupervisor, strategy: :one_for_one, children: []},
      {Horde.Registry, name: Hordetest.HordeRegistry, keys: :unique},
      {Hordetest.Cluster.Tracker, []}
    ]

    {:ok, sup} =
      Supervisor.start_link(children, strategy: :one_for_one, name: Hordetest.Cluster.Supervisor)
    sup
  end

  defp connect_initial_nodes(opts) do
    default_connect = String.split(System.get_env(@connect_env) || "", ",")

    opts
    |> Keyword.get(:connect, default_connect)
    |> Enum.each(fn node ->
      node |> String.to_atom() |> Node.connect()
    end)

    :ok
  end


  defmodule Tracker do
    @interval_millis 1000
    @expiration_millis 60000

    require Logger
    use GenServer

    def start_link({}) do
      GenServer.start_link(__MODULE__, {}, name: __MODULE__)
    end

    defmodule State do
      defstruct(
        instance_ids: [],
        dead_instances_ids: %{},
        nodes: [],
        receivers: []
      )
    end

    def child_spec(_args) do
      %{
        id: __MODULE__,
        start: {__MODULE__, :start_link, [{}]},
        restart: :transient
      }
    end

    def init({}) do
      Logger.info("**** Starting tracker")
      :net_kernel.monitor_nodes(true, []) # notwendig damit Prozess benachrichtigt wird wenn ein knoten hinzu kommt
      Hordetest.Cluster.update_nodes()
      Process.flag(:trap_exit, true)
      Process.send_after(self(), :update_trader_ids, @interval_millis)
      {:ok, %State{nodes: [Node.self()]}}
    end

    def handle_info({:EXIT, _pid, reason}, state) do
      Logger.info("**** Tracker received exit because #{inspect(reason)}")
      {:stop, reason, state}
    end

    def handle_info(:update_trader_ids, state) do
      # Logger.info("**** Starting update_game_ids")
      {alive, dead} = Enum.split_with(Hordetest.Cluster.list_game_ids(), &Hordetest.Cluster.game_alive?/1)
      dgi = update_dead_instance_ids(dead, state.dead_instances_ids)
      agi = Enum.sort(alive)
      receivers = send_update(state.receivers, agi, state.instance_ids)
      Process.send_after(self(), :update_trader_ids, @interval_millis)
      {:noreply, %State{state | instance_ids: agi, dead_instances_ids: dgi, receivers: receivers}}
    end

    def handle_info({node_event, _node}, state) when node_event == :nodeup or node_event == :nodedown do
      nodes = Hordetest.Cluster.update_nodes()
      {:noreply, %State{state | nodes: nodes}}
    end

    def handle_info(request, state) do
      Logger.warn("Unexpected message in tracker: #{inspect(request)}")
      {:noreply, state}
    end

    def handle_call({:add_receiver, receiver, message}, _from, state) do
      {:reply, :ok, %State{state | receivers: [{receiver, message} | state.receivers]}}
    end

    def handle_call({:list_live_game_ids}, _from, state) do
      {:reply, state.game_ids, state}
    end

    def terminate(reason, _state) do
      Logger.info("**** Terminating tracker due to #{inspect(reason)}")
      :ok
    end

    defp update_dead_instance_ids(dead, old_dgi) do
      # Logger.info("**** Starting update_dead_instance_ids")
      time = System.monotonic_time(:millisecond)

      Enum.reduce(dead, %{}, fn g, d ->
        if Map.has_key?(old_dgi, g) do
          old_time = old_dgi[g]

          if time - old_time > @expiration_millis do
            Horde.Registry.unregister(Hordetest.HordeRegistry, g)
            Logger.warn("**** Unregistered stale game #{inspect(g)}")
            d
          else
            Map.put(d, g, old_time)
          end
        else
          Map.put(d, g, time)
        end
      end)
    end

    defp send_update(receivers, agi, agi) do
      # Logger.info("**** No cluster update to send")
      receivers
    end

    defp send_update(receivers, agi, _old_agi) do
      Logger.info("**** Sending cluster update #{inspect(agi)}")

      Enum.filter(receivers, fn {receiver, message} ->
        if Process.alive?(receiver) do
          send(receiver, {message, agi})
          true
        else
          false
        end
      end)
    end
  end

end
