defmodule Robo.Conn do
  @moduledoc """
  1接続=1プロセス。静的ファイル(priv/public: 3Dフロント一式)を返すか、/ws をWebSocketにする。
  ブラウザ→ノード: テキスト "コマンド 引数"（例: "chooseDirection cw"）
  ノード→ブラウザ: JSON  {"t":"hello","id":自分のプレイヤーID} / {"t":"update","state":…,"events":[…]}
  """
  alias Robo.{Peer, WS}

  @types %{
    ".html" => "text/html; charset=utf-8", ".js" => "text/javascript; charset=utf-8", ".css" => "text/css; charset=utf-8",
    ".png" => "image/png", ".txt" => "text/plain; charset=utf-8", "" => "text/plain; charset=utf-8"
  }

  def serve(sock) do
    with {:ok, {:http_request, :GET, {:abs_path, path}, _}} <- :gen_tcp.recv(sock, 0, 5_000),
         {:ok, headers} <- read_headers(sock, %{}) do
      route(sock, URI.parse(path).path, headers)
    else
      _ -> :gen_tcp.close(sock)
    end
  end

  defp read_headers(sock, acc) do
    case :gen_tcp.recv(sock, 0, 5_000) do
      {:ok, {:http_header, _, name, _, value}} -> read_headers(sock, Map.put(acc, name |> to_string() |> String.downcase(), value))
      {:ok, :http_eoh} -> {:ok, acc}
      other -> {:error, other}
    end
  end

  defp route(sock, "/ws", %{"sec-websocket-key" => key}), do: upgrade(sock, key)
  defp route(sock, "/", _), do: static(sock, "index.html")
  defp route(sock, "/" <> rel, _), do: static(sock, URI.decode(rel))
  defp route(sock, _, _), do: respond(sock, 404, "text/plain", "not found")

  # priv/public 配下のファイルだけを返す（.. や拡張子の制限でパストラバーサルを防ぐ）
  defp static(sock, rel) do
    segs = String.split(rel, "/")
    ext = Path.extname(rel)
    safe? = Enum.all?(segs, &(&1 not in ["..", "."] and not String.contains?(&1, ["\\", <<0>>])))

    with true <- safe?,
         {:ok, type} <- Map.fetch(@types, if(Path.basename(rel) == "LICENSE", do: "", else: ext)),
         {:ok, body} <- File.read(Path.join(root(), rel)) do
      respond(sock, 200, type, body, if(String.starts_with?(rel, "vendor/"), do: "max-age=86400", else: "no-cache"))
    else
      _ -> respond(sock, 404, "text/plain", "not found")
    end
  end

  defp root, do: Application.app_dir(:robo, "priv/public")

  defp respond(sock, code, type, body, cache \\ "no-cache") do
    reason = if code == 200, do: "OK", else: "Not Found"

    :gen_tcp.send(sock, [
      "HTTP/1.1 #{code} #{reason}\r\nContent-Type: #{type}\r\nContent-Length: #{byte_size(body)}\r\n",
      "Cache-Control: #{cache}\r\nConnection: close\r\n\r\n",
      body
    ])

    :gen_tcp.close(sock)
  end

  # ---- WebSocket ----
  defp upgrade(sock, key) do
    :inet.setopts(sock, packet: :raw)

    :gen_tcp.send(sock, [
      "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n",
      "Sec-WebSocket-Accept: #{WS.accept_key(key)}\r\n\r\n"
    ])

    attach_peer(50)
    loop(sock, <<>>)
  end

  # Peer(アクタ)を監視する。Peerが落ちて監督木に再起動されたら、同じブラウザ接続を付け直す。
  defp attach_peer(0), do: :ok

  defp attach_peer(tries) do
    case Process.whereis(Peer) do
      nil ->
        Process.sleep(100)
        attach_peer(tries - 1)

      pid ->
        Process.put(:peer_ref, Process.monitor(pid))

        try do
          Peer.attach(self())
        catch
          :exit, _ ->
            Process.sleep(100)
            attach_peer(tries - 1)
        end
    end
  end

  defp loop(sock, buf) do
    :inet.setopts(sock, active: :once)

    receive do
      {:tcp, ^sock, data} ->
        case WS.decode(buf <> data) do
          {:error, _} -> close(sock)
          {frames, rest} -> if handle_frames(frames, sock) == :close, do: close(sock), else: loop(sock, rest)
        end

      {:push, json} ->
        :gen_tcp.send(sock, WS.encode(1, json))
        loop(sock, buf)

      {:DOWN, ref, :process, _, _} ->
        if ref == Process.get(:peer_ref), do: attach_peer(50)
        loop(sock, buf)

      {:tcp_closed, ^sock} -> :ok
      {:tcp_error, ^sock, _} -> :ok
    end
  end

  defp handle_frames(frames, sock) do
    Enum.reduce_while(frames, :ok, fn
      {1, text}, _ ->
        case String.split(text, " ", parts: 2) do
          [cmd, arg] -> Peer.command(cmd, arg)
          [cmd] -> Peer.command(cmd, "")
        end

        {:cont, :ok}

      {9, payload}, _ -> :gen_tcp.send(sock, WS.encode(10, payload)) && {:cont, :ok}
      {8, _}, _ -> {:halt, :close}
      _, _ -> {:cont, :ok}
    end)
  end

  defp close(sock) do
    :gen_tcp.send(sock, WS.encode(8, <<>>))
    :gen_tcp.close(sock)
  end
end
