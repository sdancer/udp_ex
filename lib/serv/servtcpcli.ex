defmodule ServTcpCli do
  def start({remotehost, remoteport}, conn_id, session) do
    GenServer.start(__MODULE__, %{
      remotehost: remotehost,
      remoteport: remoteport,
      conn_id: conn_id,
      session: session
    })
  end

  def init(args) do
    send(self(), :connect)
    packet_queue = :ets.new(:packet_queue, [:public, :ordered_set])

    state =
      Map.merge(args, %{
        socket: nil,
        packet_queue: packet_queue,
        sent: 0,
        close_at: nil
      })

    {:ok, state}
  end

  def handle_info(:connect, state) do
    IO.inspect({__MODULE__, :connecting, state.remotehost, state.remoteport})

    result =
      :gen_tcp.connect(:binary.bin_to_list(state.remotehost), state.remoteport, [
        {:active, :once},
        :binary
      ])

    case result do
      {:error, _} ->
        send(state.session, {:tcp_closed, state.conn_id, 0})

        {:stop, :normal, state}

      {:ok, socket} ->
        send(state.session, {:tcp_connected, state.conn_id})

        {:noreply, %{state | socket: socket}}
    end
  end

  def handle_info({:tcp_closed, socket}, state) do
    offset = Map.get(state, :offset, 0)

    IO.inspect({__MODULE__, :closed, state.conn_id, offset})

    send(state.session, {:tcp_closed, state.conn_id, offset})

    {:stop, :normal, state}
  end

  def handle_info({:tcp, socket, bin}, state) do
    offset = Map.get(state, :offset, 0)

    send(state.session, {:tcp_data, state.conn_id, offset, bin, self()})

    state = Map.put(state, :offset, offset + byte_size(bin))

    {:noreply, state}
  end

  def handle_info({:close_conn, offset}, state = %{sent: sent}) do
    if state.sent == offset do
      IO.inspect({__MODULE__, :close_conn, sent})
      :gen_tcp.close(state.socket)
      send(state.session, {:tcp_closed, self()})
      {:stop, :normal, state}
    else
      IO.inspect({__MODULE__, :ignoring_close, offset, sent})
      state = Map.put(state, :close_at, offset)
      {:noreply, state}
    end
  end

  def handle_info({:queue, offset, _bin}, state = %{sent: sent}) when offset < sent do
    # IO.inspect {:discarted_queue_packet, offset, sent}
    {:noreply, state}
  end

  def handle_info({:queue, offset, bin}, state) do
    state =
      if offset == state.sent do
        :gen_tcp.send(state.socket, bin)
        state = Map.merge(state, %{sent: offset + byte_size(bin)})
        unfold_queue(state)
      else
        # IO.inspect {__MODULE__, :queing_data, state.sent, offset, byte_size(bin)}
        :ets.insert(state.packet_queue, {offset, bin})
        state
      end

    cond do
      !!state[:close_at] && state.sent >= state[:close_at] ->
        IO.inspect({__MODULE__, :close_reached, state.sent})
        :gen_tcp.close(state.socket)
        send(state.session, {:tcp_closed, self()})
        {:stop, :normal, state}

      true ->
        {:noreply, state}
    end
  end

  def handle_info(:continue_reading, state) do
    :inet.setopts(state.socket, [{:active, :once}])

    {:noreply, state}
  end

  def unfold_queue(state) do
    case :ets.lookup(state.packet_queue, state.sent) do
      [] ->
        state

      [{offset, bin}] ->
        # IO.inspect {__MODULE__, :unfolding_queue, offset, byte_size(bin)}
        :ets.delete(state.packet_queue, offset)
        :gen_tcp.send(state.socket, bin)
        state = Map.merge(state, %{sent: offset + byte_size(bin)})
        unfold_queue(state)
    end
  end
end
