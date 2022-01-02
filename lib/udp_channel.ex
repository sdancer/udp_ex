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

  def stats_inc_udp_packets(state), do: :counters.add(state.stat_counters, 1, 1)
  def stats_inc_new_packets(state), do: :counters.add(state.stat_counters, 2, 1)
  def stats_inc_dup_packets(state), do: :counters.add(state.stat_counters, 3, 1)
  def stats_inc_ticks(state), do: :counters.add(state.stat_counters, 4, 1)
  def stats_inc_sent_acks(state), do: :counters.add(state.stat_counters, 5, 1)
  def stats_inc_recv_acks(state), do: :counters.add(state.stat_counters, 6, 1)

  def stats5(state) do
    seconds = 1

    if :os.system_time(1000) - Process.get(:prev_stats, 0) > 1000 do
      Process.put(:prev_stats, :os.system_time(1000))
      newpackets = :counters.get(state.stat_counters, 2)
      dups = :counters.get(state.stat_counters, 3)

      {_packets, oldnew, olddups} = Process.get(:old_stats, {0, 0, 0})

      ticks = :counters.get(state.stat_counters, 4)
      :counters.put(state.stat_counters, 4, 0)

      sent_acks = :counters.get(state.stat_counters, 5)
      :counters.put(state.stat_counters, 5, 0)

      recv_acks = :counters.get(state.stat_counters, 6)
      :counters.put(state.stat_counters, 6, 0)

      {:value, {:size, pressure}} = :lists.keysearch(:size, 1, :ets.info(state.send_queue))

      IO.inspect(
        {:stats5,
         [
           queue: pressure,
           ticks: ticks / seconds,
           new: (newpackets - oldnew) / seconds,
           dup: (dups - olddups) / seconds,
           acks_s_r: {recv_acks, sent_acks}
         ]}
      )

      Process.put(:old_stats, {0, newpackets, dups})
    end
  end

  def new_state(socket, session_id, remote_udp_point) do
    stat_counters = :counters.new(10, [:write_concurrency])

    %{
      stat_counters: stat_counters,
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
    stats_inc_ticks(state)

    stats5(state)

    state = receive_loop(state.udpsocket, state)

    # 500 ticks per second
    state = dispatch_packets(state.remote_udp_endpoint, state)
    state = dispatch_packets(state.remote_udp_endpoint, state)
    state = dispatch_packets(state.remote_udp_endpoint, state)
    state = dispatch_packets(state.remote_udp_endpoint, state)

    __MODULE__.loop(state)
  end

  def receive_loop(socket, state) do

    state = send_acks state

    receive do
      {:queue_app, data} ->
        # IO.inspect({:queueing_app_data, data})

        send_counter = PacketQueue.insert_appdata(state.send_queue, {state.send_counter, data})

        state = %{state | send_counter: send_counter}
        receive_loop(socket, state)

      {:queue_data, {:con_data, conn_id, offset, send_bytes}} ->
        # IO.inspect({:queueing_data, {:con_data, conn_id, offset, send_bytes}})
        conns_small_buffer = Process.get(:conns_small_buffer, %{})

        {offset, send_bytes} =
          case Map.get(conns_small_buffer, conn_id, nil) do
            nil ->
              {offset, send_bytes}

            {prev_offset, d} ->
              {prev_offset, d <> send_bytes}
          end

        conns_sb = Map.delete(conns_small_buffer, conn_id)
        Process.put(:conns_small_buffer, conns_sb)

        send_counter =
          PacketQueue.insert_chunks(
            state.send_queue,
            {state.send_counter, {conn_id, offset, send_bytes}}
          )

        state = %{state | send_counter: send_counter}
        receive_loop(socket, state)

      {:udp, socket, host, port, bin} ->
        stats_inc_udp_packets(state)
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

  def proc_ack_list(<<>>, state) do
    nil
  end

  def proc_ack_list(<<seq_id::64-little, rest::binary>>, state) do
    :ets.delete(state.send_queue, seq_id)

    proc_ack_list(rest, state)
  end

  def delete_before(seq_id, state) do
    case :ets.first(state.send_queue) do
      :"$end_of_table" ->
        :ok

      x when x > seq_id ->
        :ok

      s ->
        :ets.delete(state.send_queue, s)
        delete_before(seq_id, state)
    end
  end

  def handle_info({:udp_data, host, port, bin}, state) do
    session_id = state.session_id

    key = get_key()

    sdata = :crypto.exor(bin, :binary.part(key, 0, byte_size(bin)))

    # IO.inspect {__MODULE__, :udp_data, host, port, sdata}

    state =
      case sdata do
        # types of packets:
        # 100 acks list
        # 99 bucket list
        # 0 data
        <<^session_id::64-little, 100, ack_min::64-little, buckets_count::32-little,
          rest::binary>> ->
          stats_inc_recv_acks(state)
          delete_before(ack_min, state)
          proc_ack_list(rest, state)

          # IO.inspect {:got_buckets, Enum.count(buckets)}
          %{state | remote_udp_endpoint: {host, port}}

        <<^session_id::64-little, 99, _ackmin::64-little, buckets_count::32-little,
          rest::binary>> ->
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

          # IO.inspect {:got_buckets, Enum.count(buckets)}
          %{state | remote_udp_endpoint: {host, port}}

        <<^session_id::64-little, 0, packet_id::64-little, data::binary>> ->
          pbuckets = state.buckets
          {is_new, nbuckets} = Sparse.add_to_sparse([], state.buckets, packet_id)

          # IO.inspect {:packet_data, is_new, packet_id, data}

          case is_new do
            :ok ->
              # ack_data state, packet_id

              send(state.parent, {:udp_channel_data, data})
              # IO.inspect({:data_sent_to_parent, data})

              stats_inc_new_packets(state)

            _ ->
              if pbuckets != nbuckets do
                IO.inspect({:error, pbuckets, nbuckets})
              end

              stats_inc_dup_packets(state)
              # IO.inspect packet_id
          end

          state = Map.put(state, :buckets, nbuckets)

          state = enqueue_ack(packet_id, state)

          %{state | remote_udp_endpoint: {host, port}}

        _ ->
          IO.inspect({:discarted_data})
          state
      end

    {:noreply, state}
  end

  def enqueue_ack(seq_id, state = %{}) do
    acks_time_delta = :os.system_time(1000) - Process.get(:acks_time, 0)

    {base, _} = List.last(state.buckets)

    ack_list = Process.get(:ack_list_2, [])

    ack_list = Enum.filter(ack_list, fn x -> x > base end)

    ack_list =
      if Enum.count(ack_list) > 20 do
        [_ | ack_list] = ack_list
        ack_list
      else
        ack_list
      end

    ack_list =
      cond do
        seq_id in ack_list ->
          #IO.inspect({"discarding ack", base, seq_id, acks_time_delta})
          ack_list

        seq_id < base ->
          IO.inspect({"discarding ack", base, seq_id, acks_time_delta})
          ack_list

        seq_id == base ->
          ack_list

        true ->
          ack_list ++ [seq_id]
      end

    Process.put(:ack_list_2, ack_list)

    acks_not_sent = Process.get(:acks_not_sent, 0)
    Process.put(:acks_not_sent, acks_not_sent)

    state
  end

  def send_acks(state = %{remote_udp_endpoint: nil}) do
    state
  end

  def send_acks(state = %{}) do
    acks_time_delta = :os.system_time(1000) - Process.get(:acks_time, 0)

    {base, _} = case List.last(state.buckets) do
      nil ->
        {0, 0}
      x -> x
    end

    ack_list = Process.get(:ack_list_2, [])

    ack_list = Enum.filter(ack_list, fn x -> x > base end)

    Process.put(:ack_list_2, ack_list)


    acks_not_sent = Process.get(:acks_not_sent, 0)

    last_base = Process.get(:last_base, 0)

    if (last_base != base or ack_list != []) and (acks_not_sent >= 5 or acks_time_delta > 50) do
      Process.put(:last_base, base)

      Process.put(:acks_time, :os.system_time(1000))
      {host, port} = state.remote_udp_endpoint

      IO.inspect({"sending acks", base, last_base, ack_list})

      ack_list =
        Enum.map(ack_list, fn x ->
          <<x::64-little>>
        end)

      data =
        [
          <<state.session_id::64-little, 100, base::64-little, 0::32-little>>,
          ack_list
        ]
        |> IO.iodata_to_binary()

      key = get_key()

      sdata = :crypto.exor(data, :binary.part(key, 0, byte_size(data)))

      res =
        :gen_udp.send(
          state.udpsocket,
          host,
          port,
          sdata
        )

      case res do
        {:error, :eagain} -> nil
        :ok -> nil
      end

      Process.put(:acks_not_sent, 0)
      stats_inc_sent_acks(state)
    end

    state
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
        # IO.inspect({"sending buckets", Enum.count(b)})

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

    last_reset = Map.get(state, :last_reset, {0, 0, 0})
    now = :erlang.timestamp()

    state =
      cond do
        :"$end_of_table" != state.last_send and :timer.now_diff(now, last_reset) < 1_000_000 ->
          state

        :timer.now_diff(now, last_reset) < 50_000 ->
          state

        true ->
          # IO.inspect({__MODULE__, :reset, :ets.first(state.send_queue)})
          %{state | last_reset: now, last_send: :ets.first(state.send_queue)}
      end

    state =
      if state.last_send >= state.send_counter do
        send_counter =
          PacketQueue.crystalize_from_smalls_buffer(state.send_queue, state.send_counter)

        %{state | last_send: state.send_counter, send_counter: send_counter}
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

          :gen_udp.send(state.udpsocket, host, port, sdata)

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
      k = :binary.copy(<<151, 93, 29, 133, 47, 79, 63>>, 1024)

      Process.put(:key, k)
      k
    else
      key
    end
  end
end
