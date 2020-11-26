defmodule PacketQueue do
  # datastructure 
  def new() do
    send_queue = :ets.new(:send_queue, [:ordered_set, :public])
  end

  def insert_close(send_queue, {send_counter, conn_id, offset}) do
    data = <<3, conn_id::64-little, offset::64-little>>

    :ets.insert(send_queue, {send_counter, {conn_id, data}})

    send_counter + 1
  end

  def crystalize_from_smalls_buffer(send_queue, send_counter) do
    conns_small_buffer = Process.get :conns_small_buffer, %{}
	
    case Map.keys(conns_small_buffer) do
      [] -> 
        send_counter

      [conn_id | _ ] ->
        {offset, d} = Map.get conns_small_buffer, conn_id, nil 
        conns_sb = Map.delete conns_small_buffer, conn_id 
	Process.put :conns_small_buffer, conns_sb

        data = ServerSess.encode_cmd({:con_data, conn_id, offset, d})

        :ets.insert(send_queue, {send_counter, {conn_id, data}})

        send_counter + 1
    end
  end

  def insert_chunks(send_queue, {send_counter, {conn_id, offset, ""}}) do
    send_counter
  end

  def insert_chunks(send_queue, {send_counter, {conn_id, offset, d}}) do
    channel_size = 1440 

    case d do
        <<d::binary-size(channel_size), rest::binary>> ->
          data = ServerSess.encode_cmd({:con_data, conn_id, offset, d})

          :ets.insert(send_queue, {send_counter, {conn_id, data}})

          insert_chunks(send_queue, {send_counter + 1, {conn_id, offset + byte_size(d), rest}})
        d ->
	  conns_small_buffer = Process.get :conns_small_buffer, %{}
	 
	  conns_small_buffer = Map.put conns_small_buffer, conn_id, {offset, d}

          Process.put :conns_small_buffer, conns_small_buffer 

	  send_counter

          #data = ServerSess.encode_cmd({:con_data, conn_id, offset, d})

          #:ets.insert(send_queue, {send_counter, {conn_id, data}})

          #insert_chunks(send_queue, {send_counter + 1, {conn_id, offset + byte_size(d), ""}})

    end
  end

  def insert_appdata(send_queue, {send_counter, data}) do
    :ets.insert(send_queue, {send_counter, {0, data}})

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
end
