defmodule UdpServer do

    def start(port, client_session) do
        server(port, client_session)
    end

    def server(port, client_session) do
       {:ok, socket} = :gen_udp.open(port, [:binary, {:active, false}])
       spawn UdpServer, :loop, [socket, client_session]

       {:ok, socket}
    end

    def loop(socket, client_session) do
       :inet.setopts(socket, [{:active, :once}])
       receive do
          {:udp, socket, host, port, bin} ->
              IO.inspect {"received", bin}
              send client_session, {:udp_data, bin}
       end
       loop(socket, client_session)
    end
end

defmodule UdpClient do
    def client(data) do
       {:ok, socket} = :gen_udp.open(0, [:binary])
       :ok = :gen_udp.send(socket, "localhost", 4000, data)
       receive do
          {:udp, socket, _, _, bin} ->
              IO.puts "got data"
         after 2000 ->
             IO.puts "timeout"
       end

       :gen_udp.close(socket)
    end
end
