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
          pid = spawn ServerSess, :init, []
          {:ok, pid}
      end
  end
end
