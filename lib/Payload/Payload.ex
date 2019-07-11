defmodule Payload do
  def start_link(game_id, opts \\ []) do
    children = [
      {Payload.Updater, Payload.updater_process_id(game_id)},
      {Payload.Manager, {game_id, opts}}
    ]

    Supervisor.start_link(children, strategy: :one_for_all)
  end

  def up(game, data) do
    game |> resolve_payload() |> GenServer.call({:up, data})
  end

  def down(game) do
    game |> resolve_payload() |> GenServer.call({:down})
  end

  def get_meta(game) do
    game |> resolve_payload() |> GenServer.call({:meta})
  end

  def add_callback(game, type, name \\ nil, callback) do
    game |> resolve_payload() |> GenServer.call({:add_callback, type, name, callback})
  end

  def remove_callback(game, type, name) do
    game |> resolve_payload() |> GenServer.call({:remove_callback, type, name})
  end

  def control(game, params) do
    game |> resolve_payload() |> GenServer.call({:control, params})
  end

  defmodule Meta do
    @derive Jason.Encoder
    defstruct(
      id: nil,
      running: false,
      node: nil,
      settings: %{},
      stats: %{}
    )
  end

  def child_spec({game_id, opts}) do
    %{
      id: supervisor_process_id(game_id),
      type: :supervisor,
      start: {__MODULE__, :start_link, [game_id, opts]}
    }
  end

  def updater_process_id(game_id), do: :"Payload.Updater.#{game_id}"

  def manager_process_id(game_id), do: :"Payload.Manager.#{game_id}"

  def supervisor_process_id(game_id), do: :"Payload.Supervisor.#{game_id}"

  def resolve_payload({:via, Horde.Registry, {Tanx.HordeRegistry, _}} = game), do: game

  def resolve_payload(game_id) when is_binary(game_id) do
    {:via, Horde.Registry, {Tanx.HordeRegistry, game_id}}
  end

  def resolve_payload(game_pid) when is_pid(game_pid), do: game_pid
end
