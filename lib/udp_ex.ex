defmodule UdpEx do
  @moduledoc """
  Documentation for UdpEx.
  """

  @doc """
  Hello world.

  ## Examples

      iex> UdpEx.hello()
      :world

  """
  def start(_,_) do
      if :os.getenv('CLIENT') != false do
          ClientSess.start
      else
          spawn ServerSess, :init, []
      end
  end
end
