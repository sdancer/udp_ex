defmodule PacketQueue do
  def new() do
    send_queue = :ets.new(:send_queue, [:ordered_set, :public])
  end

  def insert_close(send_queue, {send_counter, conn_id, offset}) do
    data = <<3, conn_id::64-little, offset::64-little>>

    :ets.insert(send_queue, {send_counter, {conn_id, data}})

    send_counter + 1
  end

  def insert_chunks(send_queue, {send_counter, {conn_id, offset, ""}}) do
    send_counter
  end

  def insert_chunks(
        send_queue,
        {send_counter, {conn_id, offset, <<d::binary-size(800), rest::binary>>}}
      ) do
    data = <<1, conn_id::64-little, offset::64-little, d::binary>>

    :ets.insert(send_queue, {send_counter, {conn_id, data}})
    insert_chunks(send_queue, {send_counter + 1, {conn_id, offset + 800, rest}})
  end

  def insert_chunks(send_queue, {send_counter, {conn_id, offset, d}}) do
    data = <<1, conn_id::64-little, offset::64-little, d::binary>>

    if byte_size(data) > 1000 do
      throw({:oversize, byte_size(data), d})
    end

    :ets.insert(send_queue, {send_counter, {conn_id, data}})

    send_counter + 1
  end

  def insert_close(send_queue, {send_counter, conn_id, offset}) do
    data = <<3, conn_id::64-little, offset::64-little>>

    :ets.insert(send_queue, {send_counter, {conn_id, data}})

    send_counter + 1
  end

  def delete_entries(_send_queue, :"$end_of_table", _start) do
  end

  def delete_entries(_send_queue, send, start) when send < start do
  end

  def delete_entries(send_queue, send, start) do
    tsend = :ets.prev(send_queue, send)

    if tsend != :"$end_of_table" and tsend >= start do
      # IO.inspect {:deleting, tsend, send, start}
      :ets.delete(send_queue, tsend)
    end

    delete_entries(send_queue, tsend, start)
  end

  def handle_info({:udp_data, host, port, bin}, state) do
    state =
      case bin do
        <<sessionid::64-little, 99, ackmin::64-little, buckets::32-little, rest::binary>> ->
          buckets =
            if buckets == 0,
              do: [],
              else:
                (
                  {b, ""} =
                    Enum.reduce(1..buckets, {[], rest}, fn x, {acc, rest} ->
                      <<bend::64-little, bstart::64-little, rest::binary>> = rest
                      {[{bend, bstart} | acc], rest}
                    end)

                  b
                )

          Enum.each(buckets, fn {send, start} ->
            PacketQueue.delete_entries(state.send_queue, send + 1, start)
          end)

          # IO.inspect {:got_buckets, buckets}
          %{state | remote_udp_endpoint: {host, port}}

        <<session::64-little, 0, packet_id::64-little, data::binary>> ->
          pbuckets = state.buckets
          {is_new, nbuckets} = Sparse.add_to_sparse([], state.buckets, packet_id)

          case is_new do
            :ok ->
              # ack_data state, packet_id
              newpackets = Process.get(:news, 0)
              Process.put(:news, newpackets + 1)

            _ ->
              if pbuckets != nbuckets do
                IO.inspect({:error, pbuckets, nbuckets})
              end

              dups = Process.get(:dups, 0)
              Process.put(:dups, dups + 1)
          end

          state = Map.put(state, :buckets, nbuckets)

          now = :erlang.timestamp()
          # if congestion too high, make the retry req 1 s
          state =
            if :timer.now_diff(now, state.last_req_again) > 1_000_000 do
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

                  # req_again(state, last)
              end

              state = Map.put(state, :last_req_again, now)
            else
              state
            end

          state = send_buckets(state)

          state = proc_udp_packet(data, state)

        _ ->
          %{state | remote_udp_endpoint: {host, port}}
      end

    {:noreply, state}
  end

  def send_buckets(state) do
    state =
      if :timer.now_diff(:erlang.timestamp(), state.last_send_buckets) > 100000 do
        # :gen_udp.send state.udpsocket, :binary.bin_to_list(state.remotehost), state.remoteport, <<curtime::64-little>>
        b = Enum.slice(Enum.shuffle(state.buckets), 0, 50)

        if b != [] do
          # IO.inspect {"sending buckets", b}

          buckets_data =
            Enum.reduce(b, "", fn {send, start}, acc ->
              acc <> <<send::64-little, start::64-little>>
            end)

          count = Enum.count(b)

          data =
            <<state.sessionid::64-little, 99, 0::64-little, count::32-little, buckets_data::binary>>

          :gen_udp.send(
            state.udpsocket,
            :binary.bin_to_list(state.remotehost),
            state.remoteport,
            data
          )
        end

        state = Map.put(state, :last_send_buckets, :erlang.timestamp())
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
    # IO.inspect {state.last_send, state.send_counter}
    last_reset = Map.get(state, :last_reset, {0, 0, 0})
    now = :erlang.timestamp()

    state =
      if state.last_send == :"$end_of_table" and :timer.now_diff(now, last_reset) > 250_000 do
        # IO.inspect {__MODULE__, :reset, :ets.first(state.send_queue)}
        %{state | last_reset: now, last_send: :ets.first(state.send_queue)}
      else
        state
      end

    if state.last_send < state.send_counter do
      case :ets.lookup(state.send_queue, state.last_send) do
        [{packet_id, {conn_id, data}}] ->
          # IO.inspect {__MODULE__, :sending, state.last_send, state.send_counter, conn_id, byte_size(data)}
          sdata = <<sessionid::64-little, 0, packet_id::64-little, data::binary>>

          key = get_key()

          sdata = :crypto.exor(sdata, :binary.part(key, 0, byte_size(sdata)))

          :gen_udp.send(state.udpsocket, :inet.ntoa(host), port, sdata)

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

    key =
      if key == nil do
        k =
          Enum.reduce(1..128, "", fn x, acc ->
            acc <> <<x, "BCDEFGH">>
          end)

        Process.put(:key, k)
        k
      else
        key
      end
  end
end
