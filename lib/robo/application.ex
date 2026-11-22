defmodule Robo.Application do
  @moduledoc """
  起動（どのノードも同じ。ホスト/クライアントの区別はない）
    ROBO_PORT=3000                      ブラウザ向けHTTP/WebSocketポート
    ROBO_JOIN=robo@192.168.1.10,...     すでにいるピアのノード名（最初の1台以外は指定する）
    ROBO_NAME=たろう                     ロビーでの初期名
    ROBO_SPEED=0.3                      演出と待ち時間の短縮（開発・テスト用）
  """
  use Application

  @impl true
  def start(_type, _args) do
    port = "ROBO_PORT" |> System.get_env("3000") |> String.to_integer()
    joins = "ROBO_JOIN" |> System.get_env("") |> String.split(",", trim: true) |> Enum.map(&String.trim/1)

    # :pg(全ピア共通のグループ)と接続用の監督だけ先に。Peerは、クラスタに繋いでから起動する
    # （そうすれば起動時に既存ピアから状態をもらって追いつける）
    with {:ok, sup} <-
           Supervisor.start_link(
             [%{id: :pg, start: {:pg, :start_link, []}}, {Task.Supervisor, name: Robo.ConnSup}],
             strategy: :one_for_one,
             name: Robo.Supervisor
           ),
         :ok <- join_cluster(joins),
         {:ok, _} <- Supervisor.start_child(sup, Robo.Peer),
         {:ok, _} <- Supervisor.start_child(sup, {Robo.Web, port}) do
      banner(port, joins)
      {:ok, sup}
    end
  end

  defp join_cluster([]), do: :ok

  defp join_cluster(targets) do
    unless Node.alive?() do
      fatal("分散Erlangが無効です。 elixir --name 名前@IP --cookie robo ... で起動してください")
    end

    connected = Enum.filter(targets, &connect(String.to_atom(&1), 10))
    if connected == [], do: fatal("ピア #{Enum.join(targets, ", ")} に接続できません（IP・cookie・Firewall(4369/9100-9105)を確認）")

    :global.sync()
    wait_pg(30)
    IO.puts("✅ ピアに接続: #{Enum.join(connected, ", ")}")
    :ok
  end

  defp connect(_t, 0), do: false
  defp connect(t, tries), do: Node.connect(t) == true or (Process.sleep(1_000) && connect(t, tries - 1))

  # 既存ピアが :pg で見えるまで少し待つ
  defp wait_pg(0), do: :ok
  defp wait_pg(n), do: if(:pg.get_members(Robo.Peer.group()) == [], do: (Process.sleep(100) && wait_pg(n - 1)), else: :ok)

  defp fatal(msg) do
    IO.puts(:stderr, "❌ " <> msg)
    System.halt(1)
  end

  defp banner(port, joins) do
    IO.puts("\n🤖 ロボ箱庭すごろく (C2C)  node=#{Node.self()}  #{if joins == [], do: "[最初のピア]", else: "[参加]"}")
    IO.puts("   このPCのブラウザで開く:")
    for ip <- ["localhost" | lan_ips()], do: IO.puts("     http://#{ip}:#{port}/")
    IO.puts("")
  end

  defp lan_ips do
    {:ok, ifs} = :inet.getifaddrs()

    for {_name, opts} <- ifs, {:addr, {a, b, _, _} = ip} <- opts, a != 127 and not (a == 169 and b == 254),
        do: ip |> Tuple.to_list() |> Enum.join(".")
  end
end
