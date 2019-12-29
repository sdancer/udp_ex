defmodule ClientSess do
    use GenServer

    def init() do
        state = %{
            remote_udp_endpoint: nil,
            tcp_procs: %{},
            next_conn_id: 0,
        }
        send self(), :tick
        {:ok, state}
    end

    def handle_info({:udp_data, data}, state) do
        #get tcp process from id
        #send to tcp process
        {:noreply, state}
    end

    def handle_info({:tcp_data, proc, data}, state) do
        #get id from proc
        #send to tcp uplink

        send state.tcpuplink, <<
            2, #data
            next_conn_id :: 64-little,
            byte_size(data)::32-little,
        >> <> data

        {:noreply, state}
    end

    def handle_info({:tcp_add, proc, dest_host, dest_port}, state) do
        next_conn_id = state.next_conn_id

        #add a monitor to the tcp proc

        tcp_procs = Map.put state.tcp_procs, next_conn_id, %{
            proc: proc, conn_id: next_conn_id
        }

        send state.tcpuplink, <<
            1, #connect
            next_conn_id :: 64-little,
            byte_size(dest_host),
            dest_host::binary,
            dest_port::16-little
        >>

        state = %{next_conn_id: next_conn_id + 1, tcp_procs: tcp_procs}
        {:noreply, state}
    end

    def handle_info({:tcp_close, proc}, state) do
        send state.tcpuplink, <<
            3, #close
            next_conn_id :: 64-little,
        >>

        {:noreply, state}
    end
end
