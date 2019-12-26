defmodule UdpExTest do
  use ExUnit.Case
  doctest UdpEx

  test "greets the world" do
    assert UdpEx.hello() == :world
  end
end
