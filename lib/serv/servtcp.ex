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

        state = Map.merge state, %{rc4stream_d: rc4stream_d, socket: clientSocket}
        {:noreply, state}
    end

    def handle_info {:tcp, socket, bin}, state do
        {rc4stream_d, decoded} = :crypto.stream_encrypt state.rc4stream_d, bin

        IO.inspect {__MODULE__, "got data", socket, decoded}

        #send state.session, {:tcp_data, self(), decoded}

        state = Map.merge state, %{rc4stream_d: rc4stream_d}

        {:noreply, state}
    end

    def handle_info {:tcp_closed, socket}, state do
        send state.session, {:tcp_closed, self()}

        {:stop, :normal, nil}
    end

end
