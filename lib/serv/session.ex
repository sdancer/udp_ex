defmodule ServerSess do
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :temporary,
      shutdown: 500
    }
  end

  def start_link([session_id, parent]) do
    # has a uid
    # holds upstream tcp connections
    # holds a table for packets to send

    pid =
      spawn(fn ->
        channels =
          Enum.map(1..10, fn _ ->
            {:ok, channel, udpsocket, send_queue} = UdpChannel.server(0, session_id)

            pnum = :inet.port(udpsocket)

            %{channel: channel, udpsocket: udpsocket, send_queue: send_queue, port_num: pnum}
          end)

        state = %{
          procs: %{},
          channels: channels,
          reading_queue: [],
          session: session_id,
          last_packet: :os.system_time(1000)
        }

        send(parent, {:port_num, Enum.map(channels, & &1.port_num)})

        loop(state)
      end)

    {:ok, pid}
  end

  # def print_report(state) do
  #  now = :erlang.timestamp()

  #  if :timer.now_diff(now, Process.get(:last_report, {0, 0, 0})) > 1_000_000 do
  #    Process.put(:last_report, now)

  #    {:value, {:size, pressure}} = :lists.keysearch(:size, 1, :ets.info(state.send_queue))

  #    udp_data = Process.put({:series, :udp_data}, 0)

  #    IO.puts(
  #      "serv stats: #{
  #        inspect(
  #          {:presure, pressure, :last_send, state.last_send, :send_counter, state.send_counter,
  #           :received_udp_data, udp_data}
  #        )
  #      }"
  #    )
  #  end
  # end

  def loop(state) do
    pressure =
      Enum.sum(
        Enum.map(state.channels, fn channel ->
          {:value, {:size, pressure}} = :lists.keysearch(:size, 1, :ets.info(channel.send_queue))
          pressure
        end) / 10
      )

    if :os.system_time(1000) - state.last_packet > 300_000 do
      throw(:time_out)
    end

    state =
      if pressure <= 5000 do
        case state.reading_queue do
          [] ->
            state

          [a | b] ->
            send(a, :continue_reading)
            %{state | reading_queue: b}
        end
      else
        state
      end

    # print_report(state)

    state = receive_loop(state)

    __MODULE__.loop(state)
  end

  def receive_loop(state) do
    result =
      receive do
        {:DOWN, _ref, :process, pid, _reason} ->
          # proc = Map.get(state.procs, conn_id, nil)
          proc =
            Enum.find(state.procs, fn {_key, aproc} ->
              aproc.proc == pid
            end)

          case proc do
            nil ->
              state

            {conn_id, _} ->
              state = remove_conn(conn_id, state)

              # pick a random channel
              channel = Enum.random(state.channels)

              UdpChannel.queue_app(channel.channel, encode_cmd({:rm_con, conn_id, 0}))

              state
          end

        {:tcp_data, conn_id, offset, d, proc} ->
          {:value, {:size, pressure}} = :lists.keysearch(:size, 1, :ets.info(state.send_queue))

          reading_queue =
            if pressure > 5000 do
              state.reading_queue ++ [proc]
            else
              send(proc, :continue_reading)

              state.reading_queue
            end

          # IO.inspect {__MODULE__, "tcp data", conn_id, state.send_counter, offset, byte_size(d)}
          # add to the udp list

          channel = Enum.random(state.channels)

          UdpChannel.queue_data(channel.channel, {:con_data, conn_id, offset, d})

          %{state | reading_queue: reading_queue}

        {:tcp_connected, conn_id} ->
          # notify the other side
          state

        {:tcp_closed, conn_id, offset} ->
          # notify the other side
          # IO.inspect({__MODULE__, :conn_closed, conn_id})
          state = remove_conn(conn_id, state)

          channel = Enum.random(state.channels)
          UdpChannel.queue_app(channel.channel, encode_cmd({:rm_con, conn_id, offset}))

          state

        {:udp_channel_data, data} ->
          state = %{state | last_packet: :os.system_time(1000)}
          process_udp_data(data, state)

        a ->
          IO.inspect({:received, a})
          state
      after
        1 ->
          :timeout
      end

    case result do
      :timeout -> state
      _ -> receive_loop(result)
    end
  end

  def encode_cmd(data) do
    case data do
      {:add_con, conn_id, dest_host, dest_port} ->
        dsize = byte_size(dest_host)
        <<1, conn_id::32-little, dsize, dest_host::binary-size(dsize), dest_port::16-little>>

      {:con_data, conn_id, offset, send_bytes} ->
        <<2, conn_id::32-little, offset::64-little, send_bytes::binary>>

      {:rm_con, conn_id, offset} ->
        <<3, conn_id::32-little, offset::64-little>>

      {:ping, time} ->
        <<4, time::64-little>>

      {:pong, time} ->
        <<5, time::64-little>>

      _ ->
        IO.inspect({:encode_cmd_error, data})
    end
  end

  def decode_cmd(data) do
    case data do
      <<1, conn_id::32-little, dsize::8, dest_host::binary-size(dsize), dest_port::16-little>> ->
        {:add_con, conn_id, dest_host, dest_port}

      <<2, conn_id::32-little, offset::64-little, send_bytes::binary>> ->
        {:con_data, conn_id, offset, send_bytes}

      <<3, conn_id::32-little, offset::64-little>> ->
        {:rm_con, conn_id, offset}

      <<4, time::64-little>> ->
        {:ping, time}

      <<5, time::64-little>> ->
        {:pong, time}

      _ ->
        IO.inspect({:decode_cmd_error, data})
    end
  end

  def process_udp_data(data, state) do
    Process.put({:series, :udp_data}, Process.get({:series, :udp_data}, 0) + 1)
    # IO.inspect {:udp_data, Process.get {:series, :udp_data}}

    decoded = decode_cmd(data)
    # IO.inspect {__MODULE__, :proccess_udp, decoded}
    case decoded do
      {:add_con, conn_id, dest_host, dest_port} ->
        # launch a connection
        {:ok, pid} =
          DynamicSupervisor.start_child(
            MyApp.DynamicSupervisor,
            {ServTcpCli, [{dest_host, dest_port}, conn_id, self()]}
          )

        ref = :erlang.monitor(:process, pid)
        procs = Map.put(state.procs, conn_id, %{proc: pid, conn_id: conn_id})
        %{state | procs: procs}

      {:con_data, conn_id, offset, sent_bytes} ->
        # IO.inspect {__MODULE__, :con_data, conn_id, offset, byte_size(sent_bytes)}
        # send bytes to the tcp conn
        proc = Map.get(state.procs, conn_id, nil)

        case proc do
          %{proc: proc} ->
            send(proc, {:queue, offset, sent_bytes})

          _ ->
            nil
        end

        state

      {:rm_con, conn_id, offset} ->
        IO.inspect("received remove conn #{conn_id} #{offset}")
        # kill a connection
        close_conn(conn_id, offset, state)

      {:ping, time} ->
        # send pong
        state
    end
  end

  def close_conn(conn_id, offset, state) do
    proc = Map.get(state.procs, conn_id, nil)

    case proc do
      %{proc: proc} ->
        send(proc, {:close_conn, offset})

      # should add a timer to kill it in 30 sec or so

      _ ->
        IO.inspect("close conn #{conn_id} not found")
    end

    state
  end

  def remove_conn(conn_id, state) do
    proc = Map.get(state.procs, conn_id, nil)

    case proc do
      %{proc: proc} ->
        Process.exit(proc, :kill)

      _ ->
        IO.inspect("close conn #{conn_id} not found")
    end

    procs = Map.delete(state.procs, conn_id)

    %{state | procs: procs}
  end

  def update_lastsend(state = %{last_send: :"$end_of_table"}, send_queue) do
    # IO.inspect {__MODULE__, :reset, send_queue}
    Map.put(state, :last_send, send_queue - 1)
  end

  def update_lastsend(state, send_queue) do
    # IO.inspect {__MODULE__, :noreset, send_queue}
    state
  end
end
