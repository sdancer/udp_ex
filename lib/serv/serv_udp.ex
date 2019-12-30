defmodule ServerUdp do

    def start(port, client_session) do
        server(port, client_session)
    end

    def server(port, client_session) do
       {:ok, socket} = :gen_udp.open(port, [:binary, {:active, false}])
       proc = spawn UdpServer, :loop, [socket, client_session]
       :gen_udp.controlling_process socket, proc

       {:ok, socket}
    end

    def loop(socket, client_session) do
       :inet.setopts(socket, [{:active, :once}])

       receive do
          {:udp, socket, host, port, bin} ->
              #IO.inspect {"received", client_session, host, port, bin}
              send client_session, {:udp_data, host, port, bin}
              IO.inspect :sent_sucess
       end

       __MODULE__.loop(socket, client_session)
    end
end
