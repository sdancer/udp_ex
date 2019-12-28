defmodule ServerSess do
    def init() do
        #send self(), :tick
        #has a uid
        #holds upstream tcp connections
        #holds a table for packets to send
        send_queue = :ets.new :send_queue, [:ordered_set]

        state = %{
            remote_udp_endpoint: nil,
            send_queue: send_queue
        }

        {:ok, state}
    end

    def loop(state) do
        dispatch_packets(state.remote_udp_endpoint, state)

        state = receive do
            {:tcp, d} ->
            a ->
                IO.inspect {:received, a}
        after 1 ->
            state
        end
        loop(state)
    end

    def dispatch_packets(nil, state) do state end
    def dispatch_packets({ip, port}, state) do
        #do we have packets to send?
        #last ping?
        #pps ?
        state
    end
end

defmodule ClientSess do

    def init() do
        state = %{remote_udp_endpoint: nil}
        send self(), :tick
        {:ok, state}
    end

    def
end
