defmodule ServerSess do
    def init() do
        #send self(), :tick
        #has a uid
        #holds upstream tcp connections
        #holds a table for packets to send
        Mitme.Acceptor.start_link %{port: 9099, module: ServTcp, session: self()}
        {:ok, udpsocket} = ServerUdp.start 9099, self()


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
                case data do
                    <<
                    sessionid::64-little,
                    ackmin::64-little,
                    buckets::32-little,
                    rest::binary>> ->
                        buckets = if buckets == 0, do: [], else: (
                                {b,""} = Enum.reduce 1..buckets, {[], rest}, fn(x, {acc, rest})->
                                    <<bend::64-little, bstart::64-little, rest::binary>> = rest
                                    {[{bend, bstart} | acc], rest}
                                end
                                b
                            )
                        Enum.each buckets, fn({send, start})->
                            delete_entries(state.send_queue, send+1, start)
                        end
                        #IO.inspect {:got_buckets, buckets}
                        %{state | remote_udp_endpoint: {host, port}}
                    _ ->
                        %{state | remote_udp_endpoint: {host, port}}
                end


            a ->
                IO.inspect {:received, a}
                state

        after 2 ->
            state
        end

        __MODULE__.loop(state)
    end

    def delete_entries(_send_queue, :"$end_of_table", _start) do
    end

    def delete_entries(_send_queue, send, start) when send < start do
    end

    def delete_entries(send_queue, send, start) do
        tsend = :ets.prev send_queue, send
        if (tsend != :"$end_of_table") and (tsend >= start) do
            #IO.inspect {:deleting, tsend, send, start}
            :ets.delete send_queue, tsend
        end
        delete_entries(send_queue, tsend, start)
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

    def insert_chunks send_queue, {send_counter, {conn_id, offset, <<d::binary-size(800), rest::binary>>}} do
        data = <<1, conn_id::64-little,
                   offset::64-little, d::binary>>

        :ets.insert send_queue, {send_counter, {conn_id, data}}
        insert_chunks(send_queue, {send_counter + 1, {conn_id, offset+800, rest}})
    end

    def insert_chunks send_queue, {send_counter, {conn_id, offset, d}} do
        data = <<1, conn_id::64-little,
                   offset::64-little, d::binary>>

        if byte_size(data) > 1000 do
            throw {:oversize, byte_size(data), d}
        end

       :ets.insert send_queue, {send_counter, {conn_id, data}}

        send_counter + 1
    end

    def insert_close send_queue, {send_counter, conn_id, offset} do
        data = <<3, conn_id::64-little, offset::64-little,>>

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
        state = if (state.last_send == :"$end_of_table") and (:timer.now_diff(now, last_reset) > 300000) do
            #IO.inspect {__MODULE__, :reset, :ets.first(state.send_queue)}
            %{state | last_reset: now, last_send: :ets.first(state.send_queue)}
        else
            state
        end
        if (state.last_send < state.send_counter) do

            case (:ets.lookup state.send_queue, state.last_send) do
                [{packet_id, {conn_id, data}}] ->
                    #IO.inspect {__MODULE__, :sending, state.last_send, state.send_counter, conn_id, byte_size(data)}
                    sdata = << packet_id::64-little, data :: binary>>

                    key = Process.get(:key)
                    key = if key == nil do
                        k = Enum.reduce 1..128, "", fn(x, acc)->
                            acc <> <<x, "BCDEFGH">>
                        end
                        Process.put(:key, k)
                        k
                    else
                        key
                    end
                    sdata = :crypto.exor sdata, :binary.part(key, 0, byte_size(sdata))

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
