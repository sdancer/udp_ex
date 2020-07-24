defmodule Gateway do
  # listen tcp and udp
  # retransfer tcp to dest
  # retransfer udp to dest

  # simple fixed dest
  dest = ".."

  def start_link(port \\ 443) do
    pid =
      spawn_link(fn ->
        :ssl.start()

        {:ok, listenSocket} =
          :ssl.listen(port, [
            {:certfile, 'private/end_cert/end.crt'},
            {:keyfile, 'private/end_cert/end.key'},
            {:reuseaddr, true}
          ])

        loop(listenSocket)
      end)

    {:ok, pid}
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
    :ssl.setopts(socket, [{:active, false}, :binary])
    {:ok, data} = :ssl.recv(socket, 0)
    IO.inspect(data)

    case data do
      <<"newsession#"::binary, keysize::32-little, key::binary-size(keysize),
        session_id::64-little>> ->
        {:ok, pid} =
          DynamicSupervisor.start_child(
            MyApp.DynamicSupervisor,
            {ServerSess, [session_id, self()]}
          )

        {:ok, port_num} =
          receive do
            {:port_num, pnum} ->
              pnum
          after
            5000 ->
              {:error, :time_out}
          end

        :ssl.send(socket, <<"ok#", port_num::32-little>>)
        :timer.sleep(1000)
        :ssl.close(socket)

      "gw" ->
        # connect to dest
        # forward 
        nil
        :ssl.close(socket)

      _ ->
        reply = fake_http()
        :ssl.send(socket, reply)
        # simulate nginx empty page
        :timer.sleep(1000)
        :ssl.close(socket)
    end
  end

  def fake_http() do
    "HTTP/2.0 200 OK
cache-control: private, max-age=0
content-type: text/html; charset=utf-8
content-encoding: br
vary: Accept-Encoding
p3p: CP='NON UNI COM NAV STA LOC CURa DEVa PSAa PSDa OUR IND'
set-cookie: SNRHOP=I=&TS=; domain=.bing.com; path=/
set-cookie: DUP=Q=RP2bfjE7DpAQ-qRoJQRP0g2&T=396455174&A=2&IG=504098507AF5458385F323FE1767BEC2; domain=.bing.com; path=/search
strict-transport-security: max-age=31536000; includeSubDomains; preload
x-msedge-ref: Ref A: 47BFA535C4B848C090FA9B5471AEF83C Ref B: HKGEDGE0317 Ref C: 2020-07-24T14:26:14Z
date: Fri, 24 Jul 2020 14:26:13 GMT
X-Firefox-Spdy: h2
"
  end
end

defmodule GatewayClient do
  def newsession(remote_host, session_id) do
    :ssl.start()

    remote_host =
      if is_binary(remote_host) do
        :binary.bin_to_list(remote_host)
      else
        remote_host
      end

    IO.inspect("connecting to gw #{remote_host}")

    {:ok, socket} = :ssl.connect(remote_host, 443, [])
    :ssl.setopts(socket, [{:active, false}, :binary])
    key = "123"

    IO.inspect("connected")

    :ssl.send(
      socket,
      <<"newsession#", byte_size(key)::32-little, key::binary, session_id::64-little>>
    )

    res = :ssl.recv(socket, 0)
    IO.inspect(res)
    :ssl.close(socket)

    res
  end
end
