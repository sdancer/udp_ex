defmodule UdpEx do
  @moduledoc """
  Documentation for UdpEx.
  """

  @doc """
  Hello world.

  ## Examples

      iex> UdpEx.hello()
      :world

  """
  def start(_, _) do
    cond do
      !!:os.getenv('SERVER') ->
        children = [
          {DynamicSupervisor, strategy: :one_for_one, name: MyApp.DynamicSupervisor},
          %{
            id: Gateway,
            start: {Gateway, :start_link, [443]}
          }
        ]

        Supervisor.start_link(children, strategy: :one_for_one)

      !!:os.getenv('CLIENT') ->
        IO.inspect("initializing client")

        #remotehost = "35.221.206.207"

        remotehost = "95.217.38.33"

        children = [
          {DynamicSupervisor, strategy: :one_for_one, name: MyApp.DynamicSupervisor},
          %{
            id: ClientSess,
            start: {ClientSess, :start_link, [%{remotehost: remotehost, port: 9081}]}
          },
        ]

        Supervisor.start_link(children, strategy: :one_for_one)

        
      true ->
        UdpEx.Supervisor.start_link([])
    end
  end
end

defmodule UdpEx.Supervisor do
  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, :ok, opts)
  end

  @impl true
  def init(:ok) do
    children = []

    Supervisor.init(children, strategy: :one_for_one)
  end
end
