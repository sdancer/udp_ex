defmodule UdpServer do

    def start() do
       spawn fn()->
        server(4000)
        end
    end

    def server(port) do
       {ok, socket} = :gen_udp.open(port, [:binary, {:active, false}])
       loop(socket)
    end

    def loop(socket) do
       :inet.setopts(socket, [{:active, :once}])
       receive
          {:udp, socket, host, port, bin} ->
              :gen_udp.send(socket, host, port, bin)
              IO.inspect {"received", bin}
       end
       loop(socket)
    end
end

defmodule UdpClient do
    def client(data) do
       {:ok, socket} = :gen_udp.open(0, [:binary])
       :ok = :gen_udp.send(socket, "localhost", 4000, data)
       receive
          {:udp, socket, _, _, bin} ->

         after 2000 ->

       end

       :gen_udp.close(socket)
    end
end
