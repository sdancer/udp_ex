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
        pid = spawn(ServerSess, :init, [])
        {:ok, pid}

      !!:os.getenv('CLIENT') ->
        ClientSess.start()

      true ->
        nil
    end

    UdpEx.Supervisor.start_link([])
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
