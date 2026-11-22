defmodule Robo.Web do
  @moduledoc "TCPリスナ。接続ごとに Robo.Conn プロセスを起動する（外部HTTPサーバ不要）。"

  def child_spec(port), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [port]}, restart: :permanent}

  def start_link(port) do
    parent = self()
    ref = make_ref()

    {:ok, pid} =
      Task.start_link(fn ->
        opts = [:binary, packet: :http_bin, active: false, reuseaddr: true, backlog: 128, nodelay: true]

        case :gen_tcp.listen(port, opts) do
          {:ok, lsock} ->
            send(parent, {ref, :ok})
            accept_loop(lsock)

          {:error, reason} ->
            send(parent, {ref, {:error, reason}})
        end
      end)

    receive do
      {^ref, :ok} -> {:ok, pid}
      {^ref, {:error, reason}} -> {:error, {:cannot_listen, port, reason}}
    after
      5_000 -> {:error, :listen_timeout}
    end
  end

  defp accept_loop(lsock) do
    case :gen_tcp.accept(lsock) do
      {:ok, sock} ->
        {:ok, pid} =
          Task.Supervisor.start_child(Robo.ConnSup, fn ->
            receive do
              {:go, s} -> Robo.Conn.serve(s)
            end
          end)

        :ok = :gen_tcp.controlling_process(sock, pid)
        send(pid, {:go, sock})
        accept_loop(lsock)

      {:error, :closed} ->
        :ok

      {:error, _} ->
        Process.sleep(50)
        accept_loop(lsock)
    end
  end
end
