defmodule UdpChannel do
  def client(host, port, session_id) do
    {:ok, socket} = :gen_udp.open(0, [:binary, {:active, false}])

    state = new_state(socket, session_id, {host, port})

    proc = spawn(__MODULE__, :start_loop, [state])
    :gen_udp.controlling_process(socket, proc)
    send(proc, :can_start)

    send_queue =
      receive do
        {:send_queue, ^proc, send_queue} ->
          send_queue
      end

    {:ok, proc, socket, send_queue}
  end

  def new_state(socket, session_id, remote_udp_point) do
    %{
      session_id: session_id,
      remote_udp_endpoint: remote_udp_point,
      udpsocket: socket,
      parent: self(),
      send_queue: PacketQueue.new(),
      last_send: :"$end_of_table",
      last_reset: {0, 0, 0},
      # os.system_time 1000
      last_req_again: 0,
      last_send_buckets: 0,
      send_counter: 0,
      counter: 0,
      buckets: []
    }
  end

  def server(port, session_id) do
    {:ok, socket} = :gen_udp.open(port, [:binary, {:active, false}])

    state = new_state(socket, session_id, nil)

    proc = spawn(__MODULE__, :start_loop, [state])
    :gen_udp.controlling_process(socket, proc)
    send(proc, :can_start)

    send_queue =
      receive do
        {:send_queue, ^proc, send_queue} ->
          send_queue
      end

    {:ok, proc, socket, send_queue}
  end

  def queue_app(chan, data) do
    send(chan, {:queue_app, data})
  end

  def queue_data(chan, data) do
     send(chan, {:queue_data, data})
  end

  def start_loop(state) do
    receive do
      :can_start ->
        nil
    after
      5000 ->
        throw(:time_out)
    end

    send(state.parent, {:send_queue, self(), state.send_queue})

    :inet.setopts(state.udpsocket, [{:active, true}])

    loop(state)
  end

  def loop(state) do
    state = receive_loop(state.udpsocket, state)

    state = dispatch_packets(state.remote_udp_endpoint, state)

    __MODULE__.loop(state)
  end

  def receive_loop(socket, state) do
    receive do
      {:queue_app, data} ->
        IO.inspect({:queueing_data, data})

        send_counter =
          PacketQueue.insert_chunks(state.send_queue, {state.send_counter, {0, 0, data}})

        state = %{state | send_counter: send_counter}
        receive_loop(socket, state)

      {:queue_data, {:con_data, conn_id, offset, send_bytes}} ->
        IO.inspect({:queueing_data, {:con_data, conn_id, offset, send_bytes}})

        send_counter =
          PacketQueue.insert_chunks(state.send_queue, {state.send_counter, {conn_id, offset, send_bytes}})

        state = %{state | send_counter: send_counter}
        receive_loop(socket, state)


      {:udp, socket, host, port, bin} ->
        # IO.inspect {"received", session_id, host, port, bin}
        {:noreply, state} = handle_info({:udp_data, host, port, bin}, state)
        receive_loop(socket, state)
    after
      1 ->
        state
    end
  end

  def req_again() do
    """
       {:req_again, conn_id, data_frame} ->
              case :ets.lookup(state.send_queue, data_frame) do
                [] ->
                  IO.puts("req_again_not_exists!!!!!!")

                _ ->
                  nil
              end

              {:value, {:size, pressure}} = :lists.keysearch(:size, 1, :ets.info(state.send_queue))

              IO.inspect({__MODULE__, :req_again, conn_id, data_frame, pressure})
              %{state | last_send: data_frame}
    """
  end

  def handle_info({:udp_data, host, port, bin}, state) do
    session_id = state.session_id

    key = get_key()

    sdata = :crypto.exor(bin, :binary.part(key, 0, byte_size(bin)))

    #IO.inspect {__MODULE__, :udp_data, host, port, sdata}

    state =
      case sdata do
        # types of packets:
        # bucket list
        # data
        <<^session_id::64-little, 99, _ackmin::64-little, buckets_count::32-little, rest::binary>> ->
          buckets =
            if rest == "" do
              []
            else
              {b, ""} =
                Enum.reduce(1..buckets_count, {[], rest}, fn x, {acc, rest} ->
                  <<bend::64-little, bstart::64-little, rest::binary>> = rest
                  {[{bend, bstart} | acc], rest}
                end)

              b
            end

          Enum.each(buckets, fn {send, start} ->
            PacketQueue.delete_entries(state.send_queue, send + 1, start)
          end)

          # IO.inspect {:got_buckets, buckets}
          IO.inspect({:buckets_data, buckets})
          %{state | remote_udp_endpoint: {host, port}}

        <<^session_id::64-little, 0, packet_id::64-little, data::binary>> ->
          pbuckets = state.buckets
          {is_new, nbuckets} = Sparse.add_to_sparse([], state.buckets, packet_id)

          #IO.inspect {:packet_data, is_new, packet_id, data}

          case is_new do
            :ok ->
              # ack_data state, packet_id
              newpackets = Process.get(:news, 0)
              Process.put(:news, newpackets + 1)

              send(state.parent, {:udp_channel_data, data})
              IO.inspect({:data_sent_to_parent, data})

            _ ->
              if pbuckets != nbuckets do
                IO.inspect({:error, pbuckets, nbuckets})
              end

              dups = Process.get(:dups, 0)
              Process.put(:dups, dups + 1)
          end

          state = Map.put(state, :buckets, nbuckets)

          # if congestion too high, make the retry req 1 s
          state =
            if :os.system_time(1000) - state.last_req_again > 1_000 do
              # IO.inspect state.buckets
              # IO.inspect {:req_again, now,
              #         Process.get(:dups, 0),
              #         Process.get(:news, 0)
              #         }
              case state.buckets do
                [{_x, 0}] ->
                  :nothing

                other ->
                  {last, start} = :lists.last(other)

                  last =
                    if start != 0 do
                      0
                    else
                      last + 1
                    end

                  last

                  # req_again(state, last)
              end

              state = Map.put(state, :last_req_again, :os.system_time(1000))
              state
            else
              state
            end

          state = send_buckets(state)

          %{state | remote_udp_endpoint: {host, port}}

        _ ->
          IO.inspect({:discarted_data})
          state
      end

    {:noreply, state}
  end

  def send_buckets(state = %{remote_udp_endpoint: nil}) do
    state
  end

  def send_buckets(state) do
    if :os.system_time(1000) - state.last_send_buckets > 100 do
      {host, port} = state.remote_udp_endpoint

      # :gen_udp.send state.udpsocket, :binary.bin_to_list(state.remotehost), state.remoteport, <<curtime::64-little>>
      b = Enum.slice(Enum.shuffle(state.buckets), 0, 50)

      if b != [] do
        IO.inspect({"sending buckets", b})

        buckets_data =
          Enum.reduce(b, "", fn {send, start}, acc ->
            acc <> <<send::64-little, start::64-little>>
          end)

        count = Enum.count(b)

        data =
          <<state.session_id::64-little, 99, 0::64-little, count::32-little,
            buckets_data::binary>>

        # :binary.bin_to_list(host)

        key = get_key()

        sdata = :crypto.exor(data, :binary.part(key, 0, byte_size(data)))

        :ok =
          :gen_udp.send(
            state.udpsocket,
            host,
            port,
            sdata
          )
      end

      state = Map.put(state, :last_send_buckets, :os.system_time(1000))
      state
    else
      state
    end
  end

  def dispatch_packets(nil, state) do
    state
  end

  def dispatch_packets({host, port}, state) do
    # do we have packets to send?
    # last ping?
    # pps ?
    if :os.system_time(1000) - Process.get(:print_dispatch, 0) > 1000 do
      Process.put(:print_dispatch, :os.system_time(1000))
      #IO.inspect({state.last_send, state.send_counter})
    end

    #    IO.inspect({:dispatch_packets, state.last_send, state.send_counter})
     
    last_reset = Map.get(state, :last_reset, {0, 0, 0})
    now = :erlang.timestamp()

    state =
      if state.last_send == :"$end_of_table" and :timer.now_diff(now, last_reset) > 250_000 do
        #IO.inspect({__MODULE__, :reset, :ets.first(state.send_queue)})
        %{state | last_reset: now, last_send: :ets.first(state.send_queue)}
      else
        state
      end

    if state.last_send < state.send_counter do
      case :ets.lookup(state.send_queue, state.last_send) do
        [{packet_id, {_conn_id, data}}] ->
          # IO.inspect {__MODULE__, :sending, state.last_send, state.send_counter, conn_id, byte_size(data)}
          sdata = <<state.session_id::64-little, 0, packet_id::64-little, data::binary>>

          key = get_key()

          sdata = :crypto.exor(sdata, :binary.part(key, 0, byte_size(sdata)))

          host =
            if is_binary(host) do
              :binary.bin_to_list(host)
            else
              host
            end

          # IO.inspect {host, :inet.ntoa(host)}

          :ok = :gen_udp.send(state.udpsocket, host, port, sdata)

        [] ->
          nil
      end

      last_send = :ets.next(state.send_queue, state.last_send)

      %{state | last_send: last_send}
    else
      state
    end
  end

  def get_key() do
    key = Process.get(:key)

    if key == nil do
      k =
        Enum.reduce(1..256, "", fn x, acc ->
          acc <> <<x, 151, 93, 29, 133, 47, 79, 63>>
        end)

      Process.put(:key, k)
      k
    else
      key
    end
  end
end
