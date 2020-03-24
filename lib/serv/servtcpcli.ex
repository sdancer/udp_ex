defmodule ServTcpCli do

    def start {remotehost, remoteport}, conn_id, session do
        GenServer.start __MODULE__, %{
            remotehost: remotehost,
            remoteport: remoteport,
            conn_id: conn_id,
            session: session
        }
    end

    def init(args) do
        send self(), :connect
        state = Map.merge args, %{socket: nil}
        {:ok, state}
    end

    def handle_info(:connect, state) do
        IO.inspect {__MODULE__, :connecting, state.remotehost, state.remoteport}

        result = :gen_tcp.connect :binary.bin_to_list(state.remotehost), state.remoteport, [{:active, :once}, :binary]
        case result do
            {:error, _} ->
                send state.session, {:tcp_closed, state.conn_id, 0}

                {:stop, :normal, state}
            {:ok, socket} ->
                send state.session, {:tcp_connected, state.conn_id}

                {:noreply, %{state | socket: socket}}
        end
    end

    def handle_info({:tcp_closed, socket}, state) do
        offset = Map.get state, :offset, 0

        IO.inspect {__MODULE__, :closed,  state.conn_id, offset}

        send state.session, {:tcp_closed, state.conn_id, offset}

        {:stop, :normal, state}
    end

    def handle_info({:tcp, socket, bin}, state) do
        offset = Map.get state, :offset, 0

        send state.session, {:tcp_data, state.conn_id, offset, bin, self()}

        state = Map.put state, :offset, offset + byte_size(bin)

        {:noreply, state}
    end

    def handle_info({:send, data}, state) do

        :gen_tcp.send state.socket, data

        {:noreply, state}
    end

    def handle_info(:continue_reading, state) do
        :inet.setopts state.socket, {:active, :once}
        
        {:noreply, state}
    end
end
