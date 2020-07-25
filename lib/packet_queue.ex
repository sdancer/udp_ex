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

  def insert_chunks(send_queue, {send_counter, {conn_id, offset, ""}}) do
    send_counter
  end

  def insert_chunks(
        send_queue,
        {send_counter, {conn_id, offset, <<d::binary-size(800), rest::binary>>}}
      ) do
    data = ServerSess.encode_cmd {:con_data, conn_id, offset, d}
     
    :ets.insert(send_queue, {send_counter, {conn_id, data}})
    insert_chunks(send_queue, {send_counter + 1, {conn_id, offset + 800, rest}})
  end

  def insert_chunks(send_queue, {send_counter, {conn_id, offset, d}}) do
    data = ServerSess.encode_cmd {:con_data, conn_id, offset, d}

    if byte_size(data) > 1000 do
      throw({:oversize, byte_size(data), d})
    end

    :ets.insert(send_queue, {send_counter, {conn_id, data}})

    send_counter + 1
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
