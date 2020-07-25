defmodule Mitme.Acceptor do
  use GenServer

  def start_link(%{port: port} = args) do
    GenServer.start_link(__MODULE__, args, [])
  end

  def init(%{port: port, module: module} = args) do
    params = args

    IO.puts("listen on port #{port} ")

    {:ok, listenSocket} =
      :gen_tcp.listen(port, [
        {:ip, {0, 0, 0, 0}},
        {:active, false},
        {:reuseaddr, true},
        {:nodelay, true}
      ])

    {:ok, _} = :prim_inet.async_accept(listenSocket, -1)

    {:ok, %{listen_socket: listenSocket, clients: [], params: params}}
  end

  def handle_info(
        {:inet_async, listenSocket, _, {:ok, clientSocket}},
        state = %{params: %{} = params}
      ) do
    :prim_inet.async_accept(listenSocket, -1)
    module = state.params.module
    {:ok, pid} = module.start(params)
    :inet_db.register_socket(clientSocket, :inet_tcp)
    :gen_tcp.controlling_process(clientSocket, pid)

    send(pid, {:pass_socket, clientSocket})

    Process.monitor(pid)

    {:noreply, %{state | clients: [pid | state.clients]}}
  end

  def handle_call(:get_clients, _from, state) do
    {:reply, state.clients, state}
  end

  def handle_info({:inet_async, _listenSocket, _, error}, state) do
    IO.puts(
      "#{inspect(__MODULE__)}: Error in inet_async accept, shutting down. #{inspect(error)}"
    )

    {:stop, error, state}
  end

  def handle_info(_, state) do
    {:noreply, state}
  end
end
