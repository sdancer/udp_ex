defmodule Gateway do
  # listen tcp and udp
  # retransfer tcp to dest
  # retransfer udp to dest

  # simple fixed dest
  dest = ".."

  def start(port \\ 443) do
    :ssl.start()

    {:ok, listenSocket} =
      :ssl.listen(port, [
        {:certfile, 'private/end_cert/end.crt'},
        {:keyfile, 'private/end_cert/end.key'},
        {:reuseaddr, true}
      ])

    loop(listenSocket)
  end

  def loop(listenSocket) do
    {:ok, socket} = :ssl.transport_accept(listenSocket)

    pid =
      spawn(fn ->
        socket =
          receive do
            {:socket, socket} ->
              socket
          end

        new_worker(socket)
      end)

    :ssl.controlling_process(socket, pid)
    send(pid, {:socket, socket})

    loop(listenSocket)
  end

  def new_worker(socket) do
    {:ok, socket} = :ssl.handshake(socket)
    :ssl.setopts(socket, [{:active, false}])
    IO.inspect(:ssl.recv(socket, 0))
    # connect to dest
    # forward 
  end
end
