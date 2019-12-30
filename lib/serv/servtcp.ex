defmodule ServTcp do
    use GenServer

    def start(params) do
        GenServer.start __MODULE__, params
    end

    def handle_info({:pass_socket, clientSocket}, state) do
        IO.inspect "#{__MODULE__} got client connection"

        rc4stream_d = :crypto.stream_init :rc4, "some_random_pass"

        {:ok, data} = :gen_tcp.recv clientSocket, 0

        {rc4stream_d, decoded} = :crypto.stream_encrypt rc4stream_d, data
        <<
            0, sessionid ::64-little, 0::64, 0::64, 0::64, 0::64,
        >> = decoded
        IO.inspect {__MODULE__, :got_session, sessionid, decoded}
        :gen_tcp.send clientSocket, "hello world"


        :inet.setopts(clientSocket, [{:active, :true}, :binary])

        state = Map.merge state, %{rc4stream_d: rc4stream_d, socket: clientSocket, queue: nil,}
        {:noreply, state}
    end

    def handle_info {:tcp, socket, bin}, state do
        {rc4stream_d, decoded} = :crypto.stream_encrypt state.rc4stream_d, bin

        IO.inspect {__MODULE__, "got data", socket, decoded}

        #send state.session, {:tcp_data, self(), decoded}

        state = Map.merge state, %{rc4stream_d: rc4stream_d}

        buff = Map.get state, :buff, ""

        state = proc_data buff <> decoded, state

        {:noreply, state}
    end

    def proc_data("", state) do
        state = Map.put state, :buff, ""
    end

    def proc_data(data, state = %{queue: {remaining, conn_id}}) do
        tosend = if byte_size(data) >= remaining do remaining else byte_size(data) end

        <<send_bytes::binary-size(tosend), rest::binary>> = data

        send state.session, {:con_data, conn_id, send_bytes}

        queue = if tosend < remaining do
            {remaining - byte_size(data), conn_id}
        end

        proc_data(rest, %{state | queue: queue})
    end

    def proc_data(data, state) do
        case data do
            <<
                1, #connect
                next_conn_id :: 64-little,
                dest_host_size,
                dest_host::binary-size(dest_host_size),
                dest_port::16-little,
                rest :: binary
            >> ->
                send state.session, {:add_con, next_conn_id, dest_host, dest_port}
                proc_data(rest, state)
            <<
                2, #data
                next_conn_id :: 64-little,
                count::32-little,
                rest:: binary
            >> ->
                proc_data(rest, %{state | queue: {count, next_conn_id}})

            <<
                3, #close
                next_conn_id :: 64-little,
                rest::binary
            >> ->
                send state.session, {:rm_con, next_conn_id}
                proc_data(rest, state)

            <<
                4, #ack data
                conn_id :: 64-little,
                data_frame :: 64-little,
                rest::binary
            >> ->
                send state.session, {:ack_data, conn_id, data_frame}
                proc_data(rest, state)

            other ->
                state = Map.put state, :buff, other
        end
    end

    def handle_info {:tcp_closed, socket}, state do
        send state.session, {:tcp_closed, self()}

        {:stop, :normal, nil}
    end

end
