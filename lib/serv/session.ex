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
            last_reset: {0,0,0},
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
                #IO.inspect {__MODULE__, :con_data, conn_id, byte_size(send_bytes)}
                #send bytes to the tcp conn
                proc = Map.get state.procs, conn_id, nil
                case proc do
                    %{proc: proc} ->
                        send proc, {:send, send_bytes}
                    _ ->
                        nil
                end

                state

            {:ack_data, conn_id, data_frame} ->
                :ets.delete state.send_queue, data_frame
                state

            {:req_again, conn_id, data_frame} ->
                IO.inspect {__MODULE__, :req_again, conn_id, data_frame}
                %{state | last_send: data_frame}

            {:rm_con, conn_id} ->
                #kill a connection
                remove_conn conn_id, state

            {:tcp_data, conn_id, offset, d} ->
                #IO.inspect {__MODULE__, "tcp data", conn_id, state.send_counter, offset, byte_size(d)}
                #add to the udp list
                send_counter = insert_chunks state.send_queue, {state.send_counter, {conn_id, offset, d}}
                state = update_lastsend state, send_counter
                %{state | send_counter: send_counter}

            {:tcp_connected, conn_id} ->
                #notify the other side
                state

            {:tcp_closed, conn_id, offset} ->
                #notify the other side
                IO.inspect {__MODULE__, :conn_closed, conn_id}
                state = remove_conn conn_id, state
                send_counter = insert_close state.send_queue, {state.send_counter, conn_id, offset}
                state = update_lastsend state, send_counter
                %{state | send_counter: send_counter}

            {:udp_data, host, port, data} ->
                #TODO: verify the sessionid?
                #TODO: decrypt
                %{state | remote_udp_endpoint: {host, port}}

            a ->
                IO.inspect {:received, a}
                state

        after 1 ->
            state
        end

        __MODULE__.loop(state)
    end

    def remove_conn conn_id, state do
        proc = Map.get state.procs, conn_id, nil
        case proc do
            %{proc: proc} ->
                Process.exit proc, :normal
            _ ->
                nil
        end
        procs = Map.delete state.procs, conn_id

        %{state | procs: procs}
    end

    def insert_chunks send_queue, {send_counter, {conn_id, offset, ""}} do
        send_counter
    end


    def insert_close send_queue, {send_counter, conn_id, offset} do
        data = <<3, conn_id::64-little, offset::64-little,>>

       :ets.insert send_queue, {send_counter, {conn_id, data}}

        send_counter + 1
    end

    def insert_chunks send_queue, {send_counter, {conn_id, offset, <<d::binary-size(1000), rest::binary>>}} do
        data = <<1, conn_id::64-little,
                   offset::64-little, d::binary>>

        :ets.insert send_queue, {send_counter, {conn_id, data}}
        insert_chunks(send_queue, {send_counter + 1, {conn_id, offset+1000, rest}})
    end

    def insert_chunks send_queue, {send_counter, {conn_id, offset, d}} do
        data = <<1, conn_id::64-little,
                   offset::64-little, d::binary>>

       :ets.insert send_queue, {send_counter, {conn_id, data}}

        send_counter + 1
    end

    def dispatch_packets(nil, state) do
        state
    end
    def dispatch_packets({host, port}, state) do
        #do we have packets to send?
        #last ping?
        #pps ?
        #IO.inspect {state.last_send, state.send_counter}
        last_reset = Map.get state, :last_reset, {0,0,0}
        now = :erlang.timestamp
        state = if (state.last_send == :"$end_of_table") and (:timer.now_diff(now, last_reset) > 200000) do
            #IO.inspect {__MODULE__, :reset, :ets.first(state.send_queue)}
            %{state | last_reset: now, last_send: :ets.first(state.send_queue)}
        else
            state
        end
        if (state.last_send < state.send_counter) do

            case (:ets.lookup state.send_queue, state.last_send) do
                [{packet_id, {conn_id, data}}] ->
                    IO.inspect {__MODULE__, :sending, state.last_send, state.send_counter, conn_id, byte_size(data)}
                    sdata = << packet_id::64-little, data :: binary>>
                    :gen_udp.send(state.udpsocket, :inet.ntoa(host), port, sdata)
                [] ->
                    nil
            end

            last_send = :ets.next(state.send_queue, state.last_send)

            %{state | last_send: last_send}
        else
            state
        end
    end

    def update_lastsend(state = %{last_send: :"$end_of_table"}, send_queue) do
        #IO.inspect {__MODULE__, :reset, send_queue}
        Map.put state, :last_send, send_queue - 1
    end
    def update_lastsend(state, send_queue) do
        #IO.inspect {__MODULE__, :noreset, send_queue}
        state
    end
end
