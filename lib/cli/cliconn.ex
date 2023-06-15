defmodule CliConn do
  use GenServer

  def start(params) do
    GenServer.start(__MODULE__, params)
  end

  def init(params) do
    packet_queue = :ets.new(:packet_queue, [:public, :ordered_set])
    state = Map.merge(params, %{packet_queue: packet_queue, offset: 0})
    {:ok, state}
  end

  def handle_info({:pass_socket, clientSocket}, state) do
    # IO.inspect {__MODULE__, "got client connection"}

    # TODO: bad, don't default from non existent here
    listener_type = Map.get(state, :listener_type, :sock5)
    # validate at system entry

    {destAddrBin, destPort} =
      case listener_type do
        :nat ->
          get_original_destionation(clientSocket)

        :sock5 ->
          {cli_type, d, p} = sock5_handshake(clientSocket)

          case cli_type do
            :socks5 ->
              sock5_notify_connected(clientSocket)

            :https ->
              https_notify_connected(clientSocket)
          end

          {d, p}
      end

    # IO.inspect {__MODULE__, :got_socket_dest, destAddrBin, destPort}

    :inet.setopts(clientSocket, [{:active, false}, :binary])

    send(state.session, {:tcp_add, self(), destAddrBin, destPort})

    state =
      Map.merge(state, %{
        socket: clientSocket,
        sent: 0
      })

    {:noreply, state}
  end

  def handle_info(:connected, state) do
    :inet.setopts(state.socket, [{:active, true}, :binary])
    {:noreply, state}
  end

  def handle_info({:close_conn, offset}, state = %{sent: sent}) do
    if state.sent >= offset do
      IO.inspect({__MODULE__, :close_conn, [sent: sent, received: state.offset]})
      :gen_tcp.close(state.socket)
      send(state.session, {:tcp_closed, self(), offset})
      {:stop, :normal, state}
    else
      IO.inspect({__MODULE__, :ignoring_close, [sent: sent, received: state.offset]})
      state = Map.put(state, :close_at, offset)
      {:noreply, state}
    end
  end

  def handle_info({:queue, offset, bin}, state = %{sent: sent}) when offset < sent do
    IO.inspect {:discarted_queue_packet, :offset, offset, :sent, sent, :size, byte_size(bin)}
    {:noreply, state}
  end

  def handle_info({:queue, offset, bin}, state) do
     IO.inspect {__MODULE__, :queing_data, state.sent, offset, byte_size(bin)}
     state =
      if offset == state.sent do
        :gen_tcp.send(state.socket, bin)
        state = Map.merge(state, %{sent: offset + byte_size(bin)})
        unfold_queue(state)
      else
        # IO.inspect {__MODULE__, :queing_data, state.sent, offset, byte_size(bin)}
        :ets.insert(state.packet_queue, {offset, bin})
        state
      end

    if state.sent >= state[:close_at] do
      IO.inspect({__MODULE__, :close_reached, state.sent})
      :gen_tcp.close(state.socket)
      send(state.session, {:tcp_closed, self(), state[:close_at]})
      {:stop, :normal, state}
    else
      {:noreply, state}
    end
  end

  def handle_info({:tcp, socket, bin}, state) do
    offset = state.offset

    # FIXME: info not available yet 
    conn_id = nil
    send(state.session, {:tcp_data, conn_id, offset, bin, self()})

    state = Map.put(state, :offset, offset + byte_size(bin))

    {:noreply, state}
  end

  def handle_info({:tcp_closed, socket}, state) do
    send(state.session, {:tcp_closed, self(), Map.get(state, :offset, 0)})

    {:stop, :normal, nil}
  end

  def unfold_queue(state) do
    case :ets.lookup(state.packet_queue, state.sent) do
      [] ->
        state

      [{offset, bin}] ->
        # IO.inspect {__MODULE__, :unfolding_queue, offset, byte_size(bin)}
        :ets.delete(state.packet_queue, offset)
        :gen_tcp.send(state.socket, bin)
        state = Map.merge(state, %{sent: offset + byte_size(bin)})
        unfold_queue(state)
    end
  end

  def http_handshake(clientSocket) do
    {:ok, res} = :gen_tcp.recv(clientSocket, 0)
    res = :binary.list_to_bin(res)

    'NECT repo.hex.pm:443 HTTP/1.1\r\ncontent-length: 0\r\nte: \r\nhost: repo.hex.pm\r\npragma: no-cache\r\nconnection: keep-alive\r\nProxy-Connection:  Keep-Alive\r\n\r\n'
    [[_, host, port]] = Regex.scan(~r/NECT (.*):(.*) HTTP/, res)
    IO.inspect({host, String.to_integer(port)})
    {:https, host, String.to_integer(port)}
  end

  def sock5_handshake(clientSocket) do
    res = :gen_tcp.recv(clientSocket, 3)

    case res do
      {:ok, [5, 1, 0]} ->
        sock5_handshake_1(clientSocket)

      {:ok, [5, 2, 0]} ->
        sock5_handshake_1(clientSocket)

      {:ok, 'CON'} ->
        http_handshake(clientSocket)
    end
  end

  def sock5_handshake_1(clientSocket) do
    # {:ok, [5, 1, 0]} = :gen_tcp.recv(clientSocket, 3)

    :gen_tcp.send(clientSocket, <<5, 0>>)

    {:ok, moredata} = :gen_tcp.recv(clientSocket, 0)

    {destAddr, destPort, ver, moredata} =
      case :binary.list_to_bin(moredata) do
        <<5, v, 0, 3, len, addr::binary-size(len), port::integer-size(16)>> ->
          {addr, port, v, <<5, 1, 0, 3, len, addr::binary-size(len), port::integer-size(16)>>}

        <<5, v, 0, 1, a, b, c, d, port::integer-size(16)>> ->
          addr = :unicode.characters_to_binary(:inet_parse.ntoa({a, b, c, d}))

          {addr, port, v, <<5, 1, 0, 1, a, b, c, d, port::integer-size(16)>>}
      end

    {:socks5, destAddr, destPort}
  end

  def https_notify_connected(clientSocket) do
    # custom version, for fast hooks
    :gen_tcp.send(clientSocket, "HTTP/1.1 200 OK\r\n\r\n")
  end

  def sock5_notify_connected(clientSocket) do
    # custom version, for fast hooks
    :gen_tcp.send(clientSocket, <<5, 0, 0, 1, 0, 0, 0, 0, 0, 0>>)
  end

  def get_original_destionation(clientSocket) do
    # get SO_origdestination
    {:ok, [{:raw, 0, 80, info}]} = :inet.getopts(clientSocket, [{:raw, 0, 80, 16}])

    <<l::integer-size(16), destPort::big-integer-size(16), a::integer-size(8), b::integer-size(8),
      c::integer-size(8), d::integer-size(8), _::binary>> = info

    destAddr = {a, b, c, d}
    destAddrBin = :unicode.characters_to_binary(:inet_parse.ntoa(destAddr))
    {destAddrBin, destPort}
  end
end
