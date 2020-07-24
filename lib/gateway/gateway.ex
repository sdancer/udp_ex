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

    __MODULE__.loop(listenSocket)
  end

  def new_worker(socket) do
    IO.puts("new connection")
    {:ok, socket} = :ssl.handshake(socket)
    :ssl.setopts(socket, [{:active, false}])
    data = :ssl.recv(socket, 0)
    IO.inspect(data)

    case data do
      <<"newsession#"::binary, keysize::32-little, key::binary-size(keysize),
        session_id::64-little>> ->
        {:ok, pid, port_num} = ServerSess.init(session_id)
        :ssl.send(socket, <<"ok#", port_num::32-little>>)

      "gw" ->
        # connect to dest
        # forward 
        nil
        :ssl.close(socket)

      _ ->
        # simulate nginx empty page
        nil
        :ssl.close(socket)
    end
  end
end

defmodule GatewayClient do
  def newsession(remote_host, session_id) do
    :ssl.start

    remote_host =
      if is_binary(remote_host) do
        :binary.bin_to_list(remote_host)
      else
        remote_host
      end
    
    IO.inspect "connecting to gw #{remote_host}"

    {:ok, socket} = :ssl.connect(remote_host, 443, [])
    :ssl.setopts(socket, [{:active, false}])
    key = "123"

    IO.inspect "connected"

    :ssl.send(
      socket,
      <<"newssesion#", byte_size(key)::32-little, key::binary, session_id::64-little>>
    )

    res = :ssl.recv(socket, 0)
    IO.inspect(res)
    :ssl.close(socket)

    res
  end
end
