defmodule ClientSess do
  use GenServer

  def gateways() do
    [:something, :something, :something]
  end

  def start_link(args \\ %{}) do
    GenServer.start_link(__MODULE__, args)
  end

  def init(args) do
    {a, b, c} = :erlang.now()
    session_id = a * 1000 + b

    remotehost = args.remotehost
    # udp port
    {:ok, portnum} = GatewayClient.newsession(args.remotehost, session_id)

    # {:ok, tcpuplink} = TcpUplink.start({remotehost, remoteport}, session_id, self())
    channels =
      Enum.map(portnum, fn portnum ->
        {:ok, udpchannel, socket, send_queue} =
          UdpChannel.client(args.remotehost, portnum, session_id)

        %{channel: udpchannel, udpsocket: socket, send_queue: send_queue, port_num: portnum}
      end)

    Mitme.Acceptor.start_link(%{port: args.port, module: CliConn, session: self()})

    state = %{
      remotehost: remotehost,
      channels: channels,
      tcp_procs: %{},
      next_conn_id: 0,
      session_id: session_id,
      lastpong: :os.system_time(1000)
    }

    send(self(), :tick)
    {:ok, state}
  end

  def handle_info(:tick, state) do
    :erlang.send_after(5000, self(), :tick)

    Enum.each(state.channels, fn channel ->
      UdpChannel.queue_app(channel.channel, ServerSess.encode_cmd({:ping, :os.system_time(1000)}))
    end)

    # state =
    #  if :os.system_time(1000) - state.lastpong > 30000 do
    #    IO.puts("refreshing_udpsocket")
    #    :gen_udp.close(state.udpsocket)
    #    {:ok, udpsocket} = UdpClient.start(0, self())
    #    state = Map.put(state, :lastpong, :os.system_time(1000))
    #    Map.put(state, :udpsocket, udpsocket)
    #  else
    #    state
    #  end

    # send udp ping with session id
    # :gen_udp.send(
    #  state.udpsocket,
    #  :binary.bin_to_list(state.remotehost),
    #  state.remoteport,
    #  <<curtime::64-little>>
    # )

    # print_stats(state)

    {:noreply, state}
  end

  def handle_info({:ssl_closed, _}, state) do
    {:noreply, state}
  end

  def handle_info({:tcp_data, _, offset, data, proc}, state) do
    fproc = Enum.find(state.tcp_procs, fn {_, aconn} -> aconn.proc == proc end)
    # send to tcp uplink
    case fproc do
      {_, %{conn_id: conn_id}} ->
        IO.inspect({:sending_tcp_data, conn_id, byte_size(data)})

        channel = Enum.random(state.channels)

        UdpChannel.queue_data(
          channel.channel,
          {:con_data, conn_id, offset, data}
        )

      _ ->
        Process.exit(proc, :normal)
        IO.inspect({__MODULE__, :zombi_conn_data, proc})
    end

    {:noreply, state}
  end

  def handle_info({:tcp_add, proc, dest_host, dest_port}, state) do
    conn_id = state.next_conn_id

    # add a monitor to the tcp proc
    IO.inspect({:tcp_add, conn_id, dest_host, dest_port})

    tcp_procs =
      Map.put(state.tcp_procs, conn_id, %{
        proc: proc,
        conn_id: conn_id
      })

    channel = Enum.random(state.channels)

    UdpChannel.queue_app(
      channel.channel,
      ServerSess.encode_cmd({:add_con, conn_id, dest_host, dest_port})
    )

    state = %{state | next_conn_id: conn_id + 1, tcp_procs: tcp_procs}
    {:noreply, state}
  end

  def handle_info({:tcp_closed, proc, sent_bytes}, state) do
    s = Enum.find(state.tcp_procs, fn {_, aconn} -> aconn.proc == proc end)

    case s do
      {_, %{conn_id: conn_id}} ->
        IO.inspect({:tcp_closed, conn_id, sent_bytes})

        channel = Enum.random(state.channels)

        UdpChannel.queue_app(
          channel.channel,
          ServerSess.encode_cmd({:rm_con, conn_id, sent_bytes})
        )

        tcp_procs = Map.delete(state.tcp_procs, Conn_id)
        state = %{state | tcp_procs: tcp_procs}

      _ ->
        nil
    end

    {:noreply, state}
  end

  def handle_info({:udp_channel_data, data}, state) do
    decoded = ServerSess.decode_cmd(data)
    #IO.inspect (case decoded do
    #  {:con_data, x, y, z} -> {:con_data, x, y, byte_size(z)}
    #  _ -> decoded
    #end)
    state = proc_udp_packet(decoded, state)

    {:noreply, state}
  end

  def proc_udp_packet({:con_data, conn_id, offset, bytes}, state) do
    proc = Map.get(state.tcp_procs, conn_id, nil)

    case proc do
      %{proc: pid} ->
        send(pid, {:queue, offset, bytes})

      _ ->
        IO.inspect({__MODULE__, :PROC_NOT_FOUND, state.tcp_procs})
        nil
    end

    state
  end

  def proc_udp_packet({:rm_con, conn_id, sent}, state) do
    proc = Map.get(state.tcp_procs, conn_id, nil)

    case proc do
      %{proc: pid} ->
        IO.inspect({__MODULE__, :connection_closed, conn_id, sent})
        send(pid, {:close_conn, sent})

      _ ->
        IO.inspect({__MODULE__, :PROC_NOT_FOUND, state.tcp_procs})
        nil
    end

    state
  end

  def proc_udp_packet({:connected, conn_id}, state) do
    proc = Map.get(state.tcp_procs, conn_id, nil)

    case proc do
      %{proc: pid} ->
        IO.inspect({__MODULE__, :connected, conn_id})
        send(pid, :connected)

      _ ->
        IO.inspect({__MODULE__, :PROC_NOT_FOUND, state.tcp_procs})
        nil
    end

    state
  end

end

