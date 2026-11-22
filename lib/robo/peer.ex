defmodule Robo.Peer do
  @moduledoc """
  各ノードに1つだけいる「ピア」アクタ。中央サーバの代わりに、全ピアが対等に動く。

  やること
  1. 入力(input)を `:pg` グループ `:robo_peers` の**全ピアへブロードキャスト**（自分自身にも届く）。
     受け取った入力は全ピアが同じ `Robo.Engine` に適用する → 全員が同じ状態になる。
  2. 自分が担当(host)するプレイヤー（自分の人間＋自分が作ったCPU＋引き継いだCPU）の入力待ちを実行する。
     CPUの手、制限時間切れのランダム手、乱数の commit / reveal（自動）。
  3. ブラウザ（WebSocket）との橋渡し。状態が変わるたび `update {state, events}` を送る。
  4. **ノードが落ちたら**、次の担当ノードがそのプレイヤーを CPU として引き継ぐ（耐障害性）。
  5. 後から参加したピアには、既存ピアから状態をもらって追いつく。
  """
  use GenServer
  alias Robo.{Engine, JSON}

  @group :robo_peers
  @turn_timeout 25_000
  @hand_timeout 14_000
  @grace_ms 5_000

  # ---- 公開API（ブラウザ接続プロセス・テストから） ----
  def start_link(_), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  def group, do: @group
  def attach(pid), do: GenServer.call(__MODULE__, {:attach, pid})
  def command(cmd, arg), do: GenServer.cast(__MODULE__, {:command, cmd, arg})
  def snapshot, do: GenServer.call(__MODULE__, :snapshot)

  # ---- 起動 ----
  @impl true
  def init(:ok) do
    me = to_string(node())
    :ok = :pg.join(@group, self())
    if Node.alive?(), do: :net_kernel.monitor_nodes(true)

    name = (System.get_env("ROBO_NAME") || "") |> env_utf8()
    name = if name == "", do: "ロボ_" <> Base.encode16(:crypto.strong_rand_bytes(2), case: :lower), else: name

    s = %{
      me: me, name: name, engine: Engine.new(), clients: %{}, timers: %{}, secrets: %{}, sent: MapSet.new(),
      synced: true, buffer: [], grace: nil, joining: false
    }

    # すでに他のピアがいれば、状態をもらって追いつく
    case :pg.get_members(@group) -- [self()] do
      [] ->
        {:ok, s}

      others ->
        for pid <- others, do: send(pid, {:sync_req, self()})
        Process.send_after(self(), :sync_timeout, 1_500)
        {:ok, %{s | synced: false}}
    end
  end

  # ロケール未設定の環境では、Erlangが環境変数のUTF-8バイト列をlatin1として読んで文字化けする。
  # 全コードポイントが255以下で、バイト列として見るとUTF-8になる場合だけ元に戻す。
  defp env_utf8(v) do
    cps = String.to_charlist(v)

    with true <- Enum.all?(cps, &(&1 < 256)),
         bin = :erlang.list_to_binary(cps),
         true <- String.valid?(bin) do
      bin
    else
      _ -> v
    end
  end

  # ---- ブラウザの接続 ----
  @impl true
  def handle_call({:attach, pid}, _from, s) do
    ref = Process.monitor(pid)
    s = cancel_grace(%{s | clients: Map.put(s.clients, pid, ref)})
    send(pid, {:push, JSON.encode(%{t: "hello", id: s.me})})
    send(pid, {:push, update_json(s.engine, [])})
    {:reply, :ok, maybe_join(s)}
  end

  def handle_call(:snapshot, _from, s), do: {:reply, Engine.snapshot(s.engine), s}

  @impl true
  def handle_cast({:command, cmd, arg}, s), do: {:noreply, command(s, cmd, arg)}

  # 非リーダーからの「開始して」依頼（開始の提案者はロビーのリーダーだけ）
  def handle_cast(:please_start, s), do: {:noreply, request_start(s)}

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _}, s) do
    if Map.has_key?(s.clients, pid) do
      s = %{s | clients: Map.delete(s.clients, pid)}

      s =
        if map_size(s.clients) == 0 and s.grace == nil,
          do: %{s | grace: Process.send_after(self(), :grace_over, @grace_ms)},
          else: s

      {:noreply, s}
    else
      {:noreply, s}
    end
  end

  # ブラウザが全部閉じたまま猶予が過ぎたら、自分のロボをCPUに任せる（ロビーなら退出）
  def handle_info(:grace_over, s) do
    s = %{s | grace: nil}

    if map_size(s.clients) == 0 do
      case {s.engine.phase, s.engine.players[s.me]} do
        {_, nil} -> :ok
        {:lobby, _} -> bcast({:leave, s.me})
        {_, %{bot: false}} -> bcast({:takeover, s.me, s.me})
        _ -> :ok
      end
    end

    {:noreply, s}
  end

  # ---- 入力の受信（全ピア共通） ----
  def handle_info({:input, from, input}, %{synced: false} = s), do: {:noreply, %{s | buffer: [{from, input} | s.buffer]}}
  def handle_info({:input, from, input}, s), do: {:noreply, apply_input(s, from, input)}

  # ---- 時間切れ・CPU ----
  def handle_info({:fire, key}, s) do
    s = %{s | timers: Map.delete(s.timers, key)}

    s =
      if key in Engine.awaiting(s.engine) do
        case key do
          {:dir, id, tn} -> bcast({:dir, id, tn, Enum.random(["cw", "ccw"])}) && s
          {:hand, id, seq} -> commit(s, id, seq, Enum.random(Engine.hands()))
        end
      else
        s
      end

    {:noreply, s}
  end

  # ---- 追いつき（後から参加したピア） ----
  def handle_info({:sync_req, from}, %{synced: true} = s) do
    send(from, {:sync_resp, s.engine})
    {:noreply, s}
  end

  def handle_info({:sync_resp, eng}, %{synced: false} = s), do: {:noreply, finish_sync(%{s | engine: eng})}
  def handle_info(:sync_timeout, %{synced: false} = s), do: {:noreply, finish_sync(s)}

  # ---- ノードが落ちた ----
  def handle_info({:nodedown, _node}, s), do: {:noreply, check_hosts(s)}

  def handle_info(_, s), do: {:noreply, s}

  # =================================================================== 入力の適用

  defp apply_input(s, from, input) do
    case Engine.apply_input(s.engine, from, input) do
      {:ok, eng, events} ->
        s = %{s | engine: eng}
        push_update(s, events)
        after_change(s, events)

      {:error, _} ->
        s
    end
  end

  defp after_change(s, events) do
    wait = events |> Enum.map(&Map.get(&1, :ms, 0)) |> Enum.sum()
    st = s.engine
    seq = st.round && st.round.seq
    keep = fn {_, sq, _} -> sq == seq end

    s = %{
      s
      | secrets: s.secrets |> Enum.filter(fn {{sq, _}, _} -> sq == seq end) |> Map.new(),
        sent: s.sent |> Enum.filter(keep) |> MapSet.new(),
        joining: s.joining and st.phase == :lobby and not Map.has_key?(st.players, s.me)
    }

    s |> maybe_join() |> drive(wait)
  end

  # 自分が担当する人の「入力待ち」を実行（または時間切れタイマーを仕掛ける）
  defp drive(s, wait) do
    aw = Engine.awaiting(s.engine)
    live = for {k, _, _} = key <- aw, k in [:dir, :hand], do: key

    {keep, stale} = Enum.split_with(s.timers, fn {key, _} -> key in live end)
    Enum.each(stale, fn {_, ref} -> Process.cancel_timer(ref) end)

    Enum.reduce(aw, %{s | timers: Map.new(keep)}, &drive_item(&1, &2, wait))
  end

  defp drive_item({:rand, id, seq}, s, _wait) do
    if mine?(s, id) and not MapSet.member?(s.sent, {:commit, seq, id}),
      do: commit(s, id, seq, :crypto.strong_rand_bytes(8)),
      else: s
  end

  defp drive_item({:reveal, id, seq}, s, _wait) do
    with true <- mine?(s, id),
         false <- MapSet.member?(s.sent, {:reveal, seq, id}),
         {payload, salt} <- s.secrets[{seq, id}] do
      bcast({:reveal, id, seq, payload, salt})
      %{s | sent: MapSet.put(s.sent, {:reveal, seq, id})}
    else
      _ -> s
    end
  end

  defp drive_item({kind, id, n} = key, s, wait) when kind in [:dir, :hand] do
    if mine?(s, id) and not Map.has_key?(s.timers, key) and not MapSet.member?(s.sent, {:commit, n, id}) do
      bot? = s.engine.players[id].bot
      speed = Engine.speed()
      timeout = if kind == :dir, do: @turn_timeout, else: @hand_timeout
      delay = if bot?, do: wait + round((900 + :rand.uniform(900)) * speed), else: wait + timeout
      %{s | timers: Map.put(s.timers, key, Process.send_after(self(), {:fire, key}, delay))}
    else
      s
    end
  end

  # 乱数/手を commit（ハッシュだけ公開）。中身(payload, salt)は reveal の時まで自分だけが持つ
  defp commit(s, id, seq, payload) do
    salt = :crypto.strong_rand_bytes(8)
    bcast({:commit, id, seq, Engine.commit_hash(seq, id, payload, salt)})

    %{
      s
      | secrets: Map.put(s.secrets, {seq, id}, {payload, salt}),
        sent: MapSet.put(s.sent, {:commit, seq, id})
    }
  end

  defp mine?(s, id), do: Engine.host_of(s.engine, id) == s.me

  # =================================================================== ブラウザからの操作

  defp command(s, "setName", arg) do
    name = arg |> String.trim() |> String.slice(0, 12)
    if Map.has_key?(s.engine.players, s.me), do: bcast({:set_name, s.me, arg})
    if name == "", do: s, else: %{s | name: name}
  end

  defp command(s, "addBot", _) do
    st = s.engine

    if st.phase == :lobby and Map.has_key?(st.players, s.me) and length(st.order) < Engine.max_players() do
      id = "bot-" <> Base.encode16(:crypto.strong_rand_bytes(3), case: :lower)
      bcast({:add_bot, id, System.os_time(:millisecond), s.me})
    end

    s
  end

  defp command(s, "removeBot", _) do
    st = s.engine

    if st.phase == :lobby and Map.has_key?(st.players, s.me) do
      case st.order |> Enum.reverse() |> Enum.find(&st.players[&1].bot) do
        nil -> :ok
        id -> bcast({:remove_bot, id})
      end
    end

    s
  end

  defp command(s, "startGame", _), do: request_start(s)

  defp command(s, "chooseDirection", dir) do
    key = Enum.find(Engine.awaiting(s.engine), &match?({:dir, _, _}, &1))

    with {:dir, id, tn} <- key, true <- id == s.me and mine?(s, id) and not s.engine.players[id].bot do
      bcast({:dir, id, tn, dir})
      cancel_timer(s, key)
    else
      _ -> s
    end
  end

  defp command(s, "chooseHand", hand) do
    key = Enum.find(Engine.awaiting(s.engine), &match?({:hand, id, _} when id == s.me, &1))

    with {:hand, id, seq} <- key,
         true <- hand in Engine.hands() and mine?(s, id) and not s.engine.players[id].bot,
         false <- MapSet.member?(s.sent, {:commit, seq, id}) do
      s |> cancel_timer(key) |> commit(id, seq, hand)
    else
      _ -> s
    end
  end

  defp command(s, "backToLobby", _) do
    if s.engine.phase == :over, do: bcast(:back_to_lobby)
    s
  end

  defp command(s, _, _), do: s

  # ゲーム開始の提案者はロビーのリーダー（名簿先頭の人間）だけ。他の人の「開始」はリーダーへ転送する
  defp request_start(s) do
    st = s.engine

    if st.phase == :lobby and Map.has_key?(st.players, s.me) and length(st.order) >= 2 do
      case Engine.leader_host(st) do
        nil -> :ok
        leader when leader == s.me -> bcast({:start, Engine.roster(st)})
        leader -> GenServer.cast({__MODULE__, String.to_atom(leader)}, :please_start)
      end
    end

    s
  end

  # =================================================================== 参加・離脱・同期

  defp maybe_join(s) do
    st = s.engine

    if map_size(s.clients) > 0 and s.synced and not s.joining and st.phase == :lobby and
         not Map.has_key?(st.players, s.me) do
      bcast({:join, s.me, s.name, System.os_time(:millisecond), s.me})
      %{s | joining: true}
    else
      s
    end
  end

  defp finish_sync(s) do
    s = %{s | synced: true}
    s = s.buffer |> Enum.reverse() |> Enum.reduce(%{s | buffer: []}, fn {from, input}, s -> apply_input(s, from, input) end)
    push_update(s, [])
    s |> maybe_join() |> drive(0)
  end

  # 担当ノードが落ちているプレイヤーを探し、「次の担当ノード」が自分なら引き継ぐ
  defp check_hosts(%{synced: false} = s), do: s

  defp check_hosts(s) do
    st = s.engine
    alive = MapSet.new([s.me | Enum.map(Node.list(), &to_string/1)])
    hosts = Engine.hosts(st)

    for id <- st.order, host = st.players[id].host, not MapSet.member?(alive, host) do
      if successor(hosts, host, alive) == s.me do
        if st.phase == :lobby, do: bcast({:leave, id}), else: bcast({:takeover, id, s.me})
      end
    end

    s
  end

  # 名簿順で、落ちたノードの「次」にいる生存ノード（全ピアが同じ式で同じ答えを出す）
  defp successor(hosts, dead, alive) do
    {before, [_ | after_]} = Enum.split_while(hosts, &(&1 != dead))
    Enum.find(after_ ++ before, &MapSet.member?(alive, &1))
  end

  defp cancel_grace(%{grace: nil} = s), do: s
  defp cancel_grace(s) do
    Process.cancel_timer(s.grace)
    %{s | grace: nil}
  end

  defp cancel_timer(s, key) do
    case Map.pop(s.timers, key) do
      {nil, _} -> s
      {ref, timers} ->
        Process.cancel_timer(ref)
        %{s | timers: timers}
    end
  end

  # =================================================================== 通信

  defp bcast(input) do
    msg = {:input, to_string(node()), input}
    for pid <- :pg.get_members(@group), do: send(pid, msg)
    :ok
  end

  defp push_update(%{clients: clients} = s, events) when map_size(clients) > 0 do
    json = update_json(s.engine, events)
    for {pid, _} <- clients, do: send(pid, {:push, json})
    :ok
  end

  defp push_update(_s, _events), do: :ok

  defp update_json(engine, events), do: JSON.encode(%{t: "update", state: Engine.snapshot(engine), events: events})
end
