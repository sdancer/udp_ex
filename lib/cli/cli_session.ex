defmodule ClientSess do
    use GenServer

    def start(args \\ %{}) do
        GenServer.start __MODULE__, args
    end

    def init(args) do
        remotehost = "52.79.227.216"
        remoteport = 9090

        {a,b,c} = :erlang.now
        sessionid = a*1000 + b

        {:ok, udpsocket} = UdpClient.start 9908, self()
        {:ok, tcpuplink} = TcpUplink.start {remotehost, remoteport}, sessionid, self()
        Mitme.Acceptor.start_link %{port: 9080, module: CliConn, session: self()}

        state = %{
            remotehost: remotehost,
            remoteport: remoteport,
            remote_udp_endpoint: nil,
            tcp_procs: %{},
            next_conn_id: 0,
            udp_proc: nil,
            udpsocket: udpsocket,
            sessionid: sessionid,
            tcpuplink: tcpuplink,
        }
        send self(), :tick
        {:ok, state}
    end

    def handle_info(:tick, state) do
        :erlang.send_after 5000, self(), :tick

        #send udp ping with session id
        {a,b,c} = :erlang.now
        curtime = a*1000000 + b
        :gen_udp.send state.udpsocket, :binary.bin_to_list(state.remotehost), state.remoteport, <<curtime::64-little>>

        {:noreply, state}
    end

    def handle_info({:tcp_data, proc, data}, state) do

        {_, %{conn_id: next_conn_id}} = Enum.find state.tcp_procs, fn({_, aconn})-> aconn.proc == proc end
        #send to tcp uplink

        send state.tcpuplink, {:send, <<
            2, #data
            next_conn_id :: 64-little,
            byte_size(data)::32-little,
        >> <> data}

        {:noreply, state}
    end

    def handle_info({:tcp_add, proc, dest_host, dest_port}, state) do
        next_conn_id = state.next_conn_id

        #add a monitor to the tcp proc

        tcp_procs = Map.put state.tcp_procs, next_conn_id, %{
            proc: proc, conn_id: next_conn_id
        }

        send state.tcpuplink, {:send, <<
            1, #connect
            next_conn_id :: 64-little,
            byte_size(dest_host),
            dest_host::binary,
            dest_port::16-little
        >>}

        state = %{state | next_conn_id: next_conn_id + 1, tcp_procs: tcp_procs}
        {:noreply, state}
    end

    def handle_info({:tcp_closed, proc}, state) do
        {_, %{conn_id: next_conn_id}} = Enum.find state.tcp_procs, fn({_, aconn})-> aconn.proc == proc end

        send state.tcpuplink, {:send, <<
            3, #close
            next_conn_id :: 64-little,
        >>}

        tcp_procs = Map.delete state.tcp_procs, next_conn_id
        state = %{state | tcp_procs: tcp_procs}

        {:noreply, state}
    end

    def handle_info({:udp_data, host, port, bin}, state) do
        # {_, %{conn_id: next_conn_id}} = Enum.find state.tcp_procs, fn({_, aconn})-> aconn.proc == proc end
        #
        # send state.tcpuplink, {:send, <<
        #     3, #close
        #     next_conn_id :: 64-little,
        # >>}

        IO.inspect {"received udp data", bin}

        << packet_id::64-little, conn_id::64-little, offset::64-little, data :: binary>> = bin

        ack_data state, packet_id

        proc = Map.get state.tcp_procs, conn_id, nil
        case proc do
            %{proc: pid} ->
                send pid, {:queue, offset, data}
            _ ->
                IO.inspect {__MODULE__, :PROC_NOT_FOUND, state.tcp_procs}
                nil
        end


        {:noreply, state}
    end

    def ack_data(state, data_frame) do
        send state.tcpuplink, {:send, <<
            4, #ack data
            0 :: 64-little,
            data_frame :: 64-little
        >>}
    end

end
