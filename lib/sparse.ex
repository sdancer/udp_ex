defmodule Sparse do
  def add_to_sparse(h, [], packetid) do
    {:ok, merge_sparse(h, [{packetid, packetid}])}
  end

  def add_to_sparse(h, [{s0, s1} | t] = origt, packetid) when packetid <= s0 and packetid >= s1 do
    {:already_exists, merge_sparse(h, origt)}
  end

  def add_to_sparse(h, [{s0, s1} | t], packetid) when packetid == s0 + 1 do
    {:ok, merge_sparse(h, [{packetid, s1} | t])}
  end

  def add_to_sparse(h, [{s0, s1} | t], packetid) when packetid > s0 do
    {:ok, merge_sparse(h, [{packetid, packetid}, {s0, s1} | t])}
  end

  def add_to_sparse(h, [{s0, s1} | t], packetid) when packetid < s1 do
    add_to_sparse([{s0, s1} | h], t, packetid)
  end

  def merge_sparse([], rest) do
    rest
  end

  def merge_sparse([{big0, small0} | resth], [{big1, small1} | restl]) when small0 == big1 + 1 do
    :lists.reverse([{big0, small1} | resth]) ++ restl
  end

  def merge_sparse(h, l) do
    :lists.reverse(h) ++ l
  end

  def test() do
    {:ok, [{0, 0}]} = ClientSess.add_to_sparse([], [], 0)

    {:ok, s} = ClientSess.add_to_sparse([], [], 1)
    IO.inspect(s)
    {:ok, s} = ClientSess.add_to_sparse([], s, 3)
    IO.inspect(s)
    {:ok, s} = ClientSess.add_to_sparse([], s, 4)
    IO.inspect(s)
    {:ok, s} = ClientSess.add_to_sparse([], s, 7)
    IO.inspect(s)
    {:ok, s} = ClientSess.add_to_sparse([], s, 10)
    IO.inspect(s)

    {:ok, s} = ClientSess.add_to_sparse([], s, 5)
    IO.inspect(s)

    {:ok, s} = ClientSess.add_to_sparse([], s, 6)
    IO.inspect(s)

    {:already_exists, s} = ClientSess.add_to_sparse([], s, 6)
    IO.inspect(s)

    {:already_exists, s} = ClientSess.add_to_sparse([], s, 1)
    IO.inspect(s)

    {:ok, s} = ClientSess.add_to_sparse([], s, 2)
    IO.inspect(s)

    {:ok, s} = ClientSess.add_to_sparse([], s, 8)
    IO.inspect(s)

    {:ok, s} = ClientSess.add_to_sparse([], s, 9)
    IO.inspect(s)

    {:ok, s} = ClientSess.add_to_sparse([], s, 0)
    IO.inspect(s)
  end
end
