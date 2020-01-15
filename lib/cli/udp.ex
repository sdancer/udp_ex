defmodule UdpClient do

    def start(port, client_session) do
        server(port, client_session)
    end

    def server(port, client_session) do
       {:ok, socket} = :gen_udp.open(port, [:binary, {:active, false}])
       proc = spawn __MODULE__, :loop, [socket, client_session]
       :inet.setopts(socket, [{:active, :true}])
       :gen_udp.controlling_process socket, proc

       {:ok, socket}
    end

    def loop(socket, client_session) do
       receive do
          {:udp, socket, host, port, data} ->
              #IO.inspect {__MODULE__, "received", host, port, bin}
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
              data = :crypto.exor data, :binary.part(key, 0, byte_size(data))

              send client_session, {:udp_data, host, port, data}
       end
       __MODULE__.loop(socket, client_session)
    end
end
