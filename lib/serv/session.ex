defmodule ServerSess do
    def init() do
        #send self(), :tick
        #has a uid
        #holds upstream tcp connections
        #holds a table for packets to send
        Mitme.Acceptor.start_link %{port: 9090, module: ServTcp, session: self()}
        {:ok, udpsocket} = ServerUdp.start 9090, self()


        send_queue = :ets.new :send_queue, [:ordered_set, :public, :named_table]

        state = %{
            remote_udp_endpoint: nil,
            send_queue: send_queue,
            send_counter: 0,
            last_send: 0,
            procs: %{},
            udpsocket: udpsocket,
        }

        #{:ok, state}
        loop state
    end

    def loop(state) do
        state = dispatch_packets(state.remote_udp_endpoint, state)

        state = receive do
            {:add_con, conn_id, dest_host, dest_port} ->
                #launch a connection
                {:ok, pid} = ServTcpCli.start {dest_host, dest_port}, conn_id, self()
                procs = Map.put state.procs, conn_id, %{proc: pid}
                %{state | procs: procs}

            {:con_data, conn_id, send_bytes} ->
                #send bytes to the tcp conn
                proc = Map.get state.procs, conn_id, nil
                case proc do
                    %{proc: proc} ->
                        send proc, {:send, send_bytes}
                    _ ->
                        nil
                end

                state

            {:ack_data, conn_id, data_num} ->
                :ets.delete state.send_queue, data_num
                state

            {:rm_con, conn_id} ->
                #kill a connection
                proc = Map.get state.procs, conn_id, nil
                case proc do
                    %{proc: proc} ->
                        Process.exit proc, :normal
                    _ ->
                        nil
                end
                procs = Map.delete state.procs, conn_id

                %{state | procs: procs}

            {:tcp_data, conn_id, offset, d} ->
                IO.inspect {__MODULE__, "tcp data", conn_id, d}
                #add to the udp list
                send_counter = insert_chunks state.send_queue, {state.send_counter, {conn_id, offset, d}}
                %{state | send_counter: send_counter}

            {:tcp_connected, conn_id} ->
                #notify the other side
                state

            {:tcp_closed, conn_id} ->
                #notify the other side
                state

            {:udp_data, host, port, data} ->
                #TODO: verify the sessionid?
                #TODO: decrypt
                %{state | remote_udp_endpoint: {host, port}}

            a ->
                IO.inspect {:received, a}
                state

        after 100 ->
            state
        end

        __MODULE__.loop(state)
    end

    def insert_chunks send_queue, {send_counter, {conn_id, offset, ""}} do
        send_counter
    end



    def insert_chunks send_queue, {send_counter, {conn_id, offset, <<d::binary-size(1000), rest::binary>>}} do
        :ets.insert send_queue, {send_counter, {conn_id, offset, d}}
        insert_chunks(send_queue, {send_counter + 1, {conn_id, offset+1000, rest}})
    end

    def insert_chunks send_queue, {send_counter, {conn_id, offset, d}} do
        :ets.insert send_queue, {send_counter, {conn_id, offset, d}}

        send_counter
    end

    def dispatch_packets(nil, state) do
        state
    end
    def dispatch_packets({host, port}, state) do
        #do we have packets to send?
        #last ping?
        #pps ?
        #IO.inspect {state.last_send, state.send_counter}

        if (state.last_send < state.send_counter) do
            case (:ets.lookup state.send_queue, state.last_send) do
                [{packet_id, {conn_id, offset, data}}] ->
                    sdata = << packet_id::64-little, conn_id::64-little,
                               offset::64-little, data :: binary>>
                    :gen_udp.send(state.udpsocket, :inet.ntoa(host), port, sdata)
                nil ->
                    nil
            end
            %{state | last_send: state.last_send + 1}
        else
            state
        end
    end
end
