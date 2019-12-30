defmodule Mitme.Acceptor do
  use GenServer
  def start_link %{port: port} = args do
    GenServer.start __MODULE__, args, []
  end

  def init(%{port: port} = args) do

    params = %{}


    IO.puts "listen on port #{port} "
    {:ok, listenSocket} = :gen_tcp.listen port, [
      {:ip, {0, 0, 0, 0}}, {:active, false}, {:reuseaddr, true}, {:nodelay, true}]
    {:ok, _} = :prim_inet.async_accept(listenSocket, -1)

    {:ok, %{listen_socket: listenSocket, clients: [], params: params}}
  end

  def handle_info {:inet_async, listenSocket, _, {:ok, clientSocket}}, state=%{params: %{} = params} do
    :prim_inet.async_accept(listenSocket, -1)
    {:ok, pid} = CliConn.start(params)
    :inet_db.register_socket(clientSocket, :inet_tcp)
    :gen_tcp.controlling_process(clientSocket, pid)

    send pid, {:pass_socket, clientSocket}

    Process.monitor pid

    {:noreply, %{state | clients: [pid | state.clients]}}
  end

  def handle_call :get_clients, _from, state do

    {:reply, state.clients, state}
  end

  def handle_info {:inet_async, _listenSocket, _, error}, state do
    IO.puts "#{inspect __MODULE__}: Error in inet_async accept, shutting down. #{inspect error}"
    {:stop, error, state}
  end

  def handle_info _, state do
    {:noreply, state}
  end
end

defmodule CliConn do
    use GenServer

    def start(params) do
        GenServer.start __MODULE__, params
    end

    def handle_info({:pass_socket, clientSocket}, state) do
        #what to do with the socket?
        #notify the so orig dest to the session
        {destAddrBin, destPort} = case state.listener_type do
            :nat ->
                get_original_destionation clientSocket
            :sock5 ->
                sock5_handshake clientSocket
        end

        IO.inspect {:got_socket_dest, destAddrBin, destPort}

        {:no_reply, state}
    end

    def handle_info {:tcp, socket, bin}, state do
        #send to session
        {:no_reply, state}
    end

    def sock5_handshake clientSocket do

      {:ok, [5, 1, 0]} = :gen_tcp.recv clientSocket, 3

      :gen_tcp.send clientSocket, <<5,0>>


      {:ok, moredata} = :gen_tcp.recv clientSocket, 0

      {destAddr, destPort, ver, moredata} = case :binary.list_to_bin(moredata) do
        <<5,v,0,3, len, addr::binary-size(len), port::integer-size(16)>> ->
          {addr, port, v, <<5,1,0,3, len, addr::binary-size(len), port::integer-size(16)>>}
        <<5,v,0,1, a,b,c,d, port::integer-size(16)>> ->

          addr = :unicode.characters_to_binary(:inet_parse.ntoa({a,b,c,d}))

          {addr, port, v, <<5,1,0,1, a,b,c,d, port::integer-size(16)>>}

      end

      {destAddr, destPort}
    end

    def sock5_notify_connected clientSocket do
        #custom version, for fast hooks
        :gen_tcp.send clientSocket, <<5, 0, 0, 1, 0, 0, 0, 0, 0, 0>>
    end

    def get_original_destionation clientSocket do
        #get SO_origdestination
        {:ok, [{:raw,0,80,info}]} = :inet.getopts(clientSocket,[{:raw, 0, 80, 16}])
        <<l::integer-size(16),
          destPort::big-integer-size(16),
          a::integer-size(8),
          b::integer-size(8),
          c::integer-size(8),
          d::integer-size(8),
          _::binary>> = info
        destAddr = {a,b,c,d}
        destAddrBin = :unicode.characters_to_binary(:inet_parse.ntoa(destAddr))
        {destAddrBin, destPort}
    end

end
