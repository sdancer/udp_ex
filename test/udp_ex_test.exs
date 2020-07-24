defmodule UdpExTest do
  use ExUnit.Case
  # doctest UdpEx

  test "udp channel" do
    session_id = 1337
    {:ok, server, serversocket} = UdpChannel.server(0, session_id)
    {:ok, servport} = :inet.port(serversocket)

    {:ok, client, _clientsocket} = UdpChannel.client("127.0.0.1", servport, session_id)

    send(client, {:send_data, "hello"})

    :timer.sleep(1000)

    res =
      receive do
        x -> x
      after
        1000 -> :timeout
      end

    IO.inspect(res)

    IO.inspect(Process.alive?(server))

    assert res == :world
  end
end
