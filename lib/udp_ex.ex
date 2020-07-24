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
        pid = spawn(Gateway, :start, [443])
        {:ok, pid}

      !!:os.getenv('CLIENT') ->
        IO.inspect("initializing client")

        remotehost = "35.221.206.207"

        remotehost = "95.217.38.33"

        ClientSess.start_link(%{remotehost: remotehost})

      true ->
        nil
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
