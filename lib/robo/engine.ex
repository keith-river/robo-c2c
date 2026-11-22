defmodule Robo.Engine do
  @moduledoc """
  ロボ箱庭すごろく — 分散(C2C)版ゲームエンジン。副作用なしの純粋関数。

  中央のゲームサーバは存在せず、**全ピアがこのエンジンの複製を持つ**。
  全員が同じ「入力(input)」を適用するので、同じ状態になる（複製ステートマシン）。

      {:ok, state', events} | {:error, reason} = Engine.apply_input(state, from_host, input)

  ## 中央がなくても公平にするための仕組み
  * **乱数は全員の寄与で決める**（サイコロ・初期配置・最初の手番）。
    各参加者が「乱数のハッシュ(commit)」を出し、全員分が揃ってから「乱数と塩(reveal)」を出す。
    結果は全 reveal の SHA-256 から導く。1人でも正直なら、他の誰にも結果を操作できない。
  * **ジャンケンの手もcommit-reveal**。相手の手を見てから出すズルができない。
  * **書き込み権限は1人だけ**（自分の番の向き選択は手番の人、ジャンケンはその2人）。
    だから合意アルゴリズム（Paxos/Raft）なしでも、複製は食い違わない。
    commit/reveal は到着順に依存しない（可換）ので、ネットワークで順序が入れ替わっても同じ結果になる。

  ## 入力 (input)
      {:join, id, name, stamp, host}   {:add_bot, id, stamp, host}   {:remove_bot, id}
      {:set_name, id, name}            {:leave, id}                  {:start, roster}
      {:dir, id, "cw"|"ccw"}           {:commit, id, seq, hash}      {:reveal, id, seq, payload, salt}
      {:takeover, id, host}            :back_to_lobby

  `from_host` は送信元ノード名。プレイヤーの操作は、そのプレイヤーを担当する(host)ノードからのみ受け付ける。
  """

  @tile_count 20
  @start_lives 3
  @min_players 2
  @max_players 8
  @hands ["rock", "scissors", "paper"]
  @beats %{"rock" => "scissors", "scissors" => "paper", "paper" => "rock"}
  @dirs ["cw", "ccw"]
  @log_limit 60
  @bot_names ["ロボ太", "メカ吉", "ピコ", "ガチャ丸", "ネジ子", "ボルト", "ギア美", "サビ丸"]

  # 演出の長さ(ms)。フロントのアニメーションもこの値に従う。ROBO_SPEED=0.3 などで短縮（開発・テスト用）。
  @base_dur %{
    start: 2200, turn: 800, roll: 1700, step: 460, jankenStart: 1400, jankenRound: 3000,
    jankenEnd: 1700, eliminated: 2600, win: 6000, lobby: 100, note: 0
  }

  def tile_count, do: @tile_count
  def max_players, do: @max_players
  def hands, do: @hands

  def speed do
    case Float.parse(System.get_env("ROBO_SPEED", "1")) do
      {v, _} when v > 0 -> v
      _ -> 1.0
    end
  end

  def dur(t), do: round(Map.fetch!(@base_dur, t) * speed())

  # ------------------------------------------------------------------ 状態

  def new do
    %{
      phase: :lobby,
      # :lobby | :starting | :turn | :rolling | :moving(一時的) | :janken | :over
      players: %{},
      order: [],
      turn_id: nil,
      turn_no: 0,
      dir: nil,
      plan: nil,
      pending: nil,
      winner_id: nil,
      last_roll: nil,
      log: [],
      rseq: 0,
      round: nil,
      early: [],
      out: []
    }
  end

  # ------------------------------------------------------------------ 入力の適用

  @spec apply_input(map, String.t(), term) :: {:ok, map, [map]} | {:error, atom}
  def apply_input(st, from, input) do
    st = %{st | out: []}

    result =
      if premature?(st, input),
        do: hold(st, from, input),
        else: handle(st, from, input)

    case result do
      {:error, _} = e -> e
      %{} = st2 -> st2 = drain(st2); {:ok, %{st2 | out: []}, Enum.reverse(st2.out)}
    end
  end

  # ---- 因果順序の入れ替わりへの対処 ----
  # Erlangのメッセージは「同じ送信者から」は順序が保たれるが、「別の送信者の間」では入れ替わりうる。
  # 例: 手番の人の「向き選択」より先に、別のピアの「乱数commit」が届く。
  # 前提がまだ届いていない入力は捨てずに保留し、前提が整った時点で適用する。
  @early_limit 8192

  defp premature?(st, {:commit, _, seq, _}), do: seq > st.rseq
  defp premature?(st, {:reveal, _, seq, _, _}), do: seq > st.rseq
  defp premature?(st, {:dir, _, tn, _}), do: tn > st.turn_no
  defp premature?(st, {:takeover, _, _}), do: st.phase == :lobby
  defp premature?(st, :back_to_lobby), do: st.phase not in [:over, :lobby]
  defp premature?(_st, _), do: false

  defp hold(st, from, input), do: %{st | early: Enum.take(st.early ++ [{from, input}], -@early_limit)}

  defp drain(%{early: []} = st), do: st

  defp drain(st) do
    {ready, wait} = Enum.split_with(st.early, fn {_from, i} -> not premature?(st, i) end)

    if ready == [] do
      st
    else
      st = %{st | early: wait}

      ready
      |> Enum.reduce(st, fn {from, i}, st ->
        case handle(st, from, i) do
          %{} = st2 -> st2
          {:error, _} -> st
        end
      end)
      |> drain()
    end
  end

  # ---- ロビー（すべて可換な操作。順序が入れ替わっても同じ名簿になる） ----

  defp handle(%{phase: :lobby} = st, from, {:join, id, name, stamp, host}) do
    cond do
      from != host or id != host -> {:error, :auth}
      Map.has_key?(st.players, id) -> {:error, :exists}
      true -> add_player(st, id, name, stamp, host, false)
    end
  end

  defp handle(%{phase: :lobby} = st, from, {:add_bot, id, stamp, host}) do
    cond do
      from != host -> {:error, :auth}
      Map.has_key?(st.players, id) -> {:error, :exists}
      true ->
        used = st.players |> Map.values() |> MapSet.new(& &1.name)
        name = Enum.find(@bot_names, &(not MapSet.member?(used, &1))) || "CPU#{map_size(st.players) + 1}"
        add_player(st, id, name, stamp, host, true)
    end
  end

  defp handle(%{phase: :lobby} = st, _from, {:remove_bot, id}) do
    case st.players[id] do
      %{bot: true} -> drop_player(st, id)
      _ -> {:error, :no_bot}
    end
  end

  defp handle(%{phase: :lobby} = st, _from, {:leave, id}) do
    if Map.has_key?(st.players, id), do: drop_player(st, id), else: {:error, :unknown}
  end

  defp handle(st, from, {:set_name, id, raw}) do
    case st.players[id] do
      %{host: ^from} = p ->
        name = clean_name(raw)
        if name == "" or name == p.name, do: {:error, :unchanged}, else: put_player(st, %{p | name: name})

      _ ->
        {:error, :auth}
    end
  end

  # ---- ゲーム開始：ロビーのリーダーだけが名簿を添えて提案。全員がその名簿を採用する ----

  defp handle(%{phase: :lobby} = st, from, {:start, roster}) when is_list(roster) do
    roster = roster |> Enum.sort_by(&{&1.stamp, &1.id}) |> Enum.take(@max_players)

    cond do
      length(roster) < @min_players -> {:error, :too_few}
      not Enum.any?(roster, &(&1.host == from)) -> {:error, :auth}
      true ->
        players =
          Map.new(roster, fn r ->
            {r.id, Map.merge(r, %{lives: @start_lives, tile: nil, alive: true, left: false})}
          end)

        st = %{st | players: players, order: Enum.map(roster, & &1.id), phase: :starting}
        open_round(st, :start, st.order)
    end
  end

  # ---- commit / reveal（可換：到着順に依存しない） ----

  defp handle(%{round: %{seq: seq} = r} = st, from, {:commit, id, seq, hash}) do
    cond do
      id not in r.need -> {:error, :not_needed}
      host_of(st, id) != from -> {:error, :auth}
      Map.has_key?(r.commits, id) -> {:error, :dup}
      true -> settle(%{st | round: %{r | commits: Map.put(r.commits, id, hash)}})
    end
  end

  defp handle(%{round: %{seq: seq} = r} = st, from, {:reveal, id, seq, payload, salt})
       when is_binary(payload) and is_binary(salt) do
    cond do
      id not in r.need -> {:error, :not_needed}
      host_of(st, id) != from -> {:error, :auth}
      Map.has_key?(r.reveals, id) -> {:error, :dup}
      true -> settle(%{st | round: %{r | reveals: Map.put(r.reveals, id, {payload, salt})}})
    end
  end

  # ---- 自分の番：向きを選ぶ → 全員の乱数でサイコロが決まる ----

  defp handle(%{phase: :turn, turn_id: id, turn_no: tn} = st, from, {:dir, id, tn, dir}) do
    cond do
      host_of(st, id) != from -> {:error, :auth}
      dir not in @dirs -> {:error, :bad_dir}
      true -> open_round(%{st | dir: dir, phase: :rolling}, :dice, alive_ids(st))
    end
  end

  # ---- 切断：生き残っているピアがCPUとして引き継ぐ ----

  defp handle(%{phase: phase} = st, from, {:takeover, id, host}) when phase != :lobby do
    pl = st.players[id]

    cond do
      pl == nil -> {:error, :unknown}
      from != host or host not in hosts(st) -> {:error, :auth}
      pl.host == host and pl.bot -> {:error, :noop}
      true ->
        st = put_player(st, %{pl | host: host, bot: true, left: pl.left or pl.human})
        # 持ち主が変わったら、前の持ち主が出しかけた commit/reveal は無効（新しい持ち主が出し直す）
        st = if pl.host != host, do: drop_round_entries(st, id), else: st
        st = if pl.bot, do: st, else: push(st, :note, %{}, "📡 #{pl.name} の接続が切れたので、CPUが引き継ぎました。")
        settle(st)
    end
  end

  # ---- 後始末 ----

  defp handle(%{phase: :over} = st, _from, :back_to_lobby) do
    players =
      st.players
      |> Enum.reject(fn {_id, p} -> p.left end)
      |> Map.new(fn {id, p} -> {id, %{p | lives: @start_lives, alive: true, tile: nil}} end)

    st = %{
      st | players: players, order: sorted_order(players), phase: :lobby, turn_id: nil, plan: nil, pending: nil,
           winner_id: nil, last_roll: nil, log: [], round: nil, dir: nil
    }

    push(st, :lobby)
  end

  defp handle(_st, _from, _input), do: {:error, :invalid}

  # ------------------------------------------------------------------ 乱数ラウンド（commit-reveal）

  def commit_hash(seq, id, payload, salt) do
    :crypto.hash(:sha256, [<<seq::64, byte_size(id)::16>>, id, <<byte_size(payload)::16>>, payload, salt])
  end

  defp open_round(st, kind, need) do
    seq = st.rseq + 1
    %{st | rseq: seq, round: %{seq: seq, kind: kind, need: need, commits: %{}, reveals: %{}}}
  end

  defp drop_round_entries(%{round: nil} = st, _id), do: st

  defp drop_round_entries(%{round: r} = st, id),
    do: %{st | round: %{r | commits: Map.delete(r.commits, id), reveals: Map.delete(r.reveals, id)}}

  # 全員の commit と reveal が揃ったら結果を確定する
  defp settle(%{round: nil} = st), do: st

  defp settle(%{round: r} = st) do
    if Enum.all?(r.need, &(Map.has_key?(r.commits, &1) and Map.has_key?(r.reveals, &1))) do
      vals =
        Enum.map(r.need, fn id ->
          {payload, salt} = r.reveals[id]
          ok = r.commits[id] == commit_hash(r.seq, id, payload, salt)
          {id, if(ok, do: payload, else: nil)}
        end)

      st = %{st | round: nil}
      st = vals |> Enum.filter(fn {_, v} -> is_nil(v) end) |> Enum.reduce(st, &cheat_note/2)
      seed = seed(r.seq, vals)

      case r.kind do
        :start -> finish_start(st, seed)
        :dice -> finish_roll(st, seed)
        :janken -> finish_janken(st, seed, vals)
      end
    else
      st
    end
  end

  defp cheat_note({id, _}, st), do: push(st, :note, %{}, "⚠️ #{st.players[id].name} の乱数が不正だったので無効にしました。")

  @doc "全員の reveal から作る乱数の種（公開関数：テストでも使う）"
  def seed(seq, vals) do
    parts =
      for {id, v} <- vals do
        [<<byte_size(id)::16>>, id, if(v, do: <<1, byte_size(v)::16, v::binary>>, else: <<0>>)]
      end

    :crypto.hash(:sha256, [<<seq::64>>, parts])
  end

  def uniform(seed, tag, n) do
    <<x::64, _::binary>> = :crypto.hash(:sha256, [seed, tag])
    rem(x, n)
  end

  def dice_from(seed), do: uniform(seed, "dice", 6) + 1

  defp shuffle(list, seed) do
    n = length(list)

    Enum.reduce((n - 1)..1//-1, List.to_tuple(list), fn i, t ->
      j = uniform(seed, "sh#{i}", i + 1)
      a = elem(t, i)
      t |> put_elem(i, elem(t, j)) |> put_elem(j, a)
    end)
    |> Tuple.to_list()
  end

  # ------------------------------------------------------------------ ゲーム進行（game.js の移植）

  defp finish_start(st, seed) do
    tiles = shuffle(Enum.to_list(0..(@tile_count - 1)), seed)

    players =
      st.order
      |> Enum.with_index()
      |> Enum.reduce(st.players, fn {id, i}, acc ->
        Map.update!(acc, id, &%{&1 | tile: Enum.at(tiles, i), lives: @start_lives, alive: true})
      end)

    first = Enum.at(st.order, uniform(seed, "first", length(st.order)))

    st =
      %{st | players: players, winner_id: nil, last_roll: nil, plan: nil, pending: nil, dir: nil, log: []}

    st
    |> push(:start, %{players: Enum.map(st.order, &public_player(st, &1)), order: st.order},
      "🎮 ゲーム開始！全員ライフ3。最後まで生き残れ！")
    |> begin_turn(first)
  end

  defp begin_turn(st, id) do
    st = %{st | turn_id: id, phase: :turn, turn_no: st.turn_no + 1, dir: nil}
    push(st, :turn, %{id: id}, "🤖 #{st.players[id].name} の番")
  end

  defp end_turn(st) do
    st = %{st | plan: nil, pending: nil}

    if st.phase == :over do
      st
    else
      idx = Enum.find_index(st.order, &(&1 == st.turn_id))
      n = length(st.order)

      Enum.find_value(1..n, st, fn i ->
        nxt = Enum.at(st.order, rem(idx + i, n))
        if st.players[nxt].alive, do: begin_turn(st, nxt)
      end)
    end
  end

  defp finish_roll(st, seed) do
    dice = dice_from(seed)
    id = st.turn_id
    dir = st.dir
    p = st.players[id]
    st = %{st | last_roll: %{id: id, dir: dir, dice: dice}}
    st = push(st, :roll, %{id: id, dir: dir, dice: dice}, "🎲 #{p.name} は#{dir_label(dir)}で「#{dice}」マス進む！")
    advance(%{st | phase: :moving, plan: %{id: id, dir: dir, remaining: dice, queue: [], kind: nil}})
  end

  # 進行役：ジャンケンが必要になるか、移動が終わるまで進める
  defp advance(%{plan: plan} = st) do
    cond do
      plan.queue != [] ->
        case start_janken(st) do
          {:started, st} -> st
          {:empty, st} -> advance(st)
        end

      plan.remaining <= 0 ->
        end_turn(st)

      true ->
        mover = st.players[plan.id]
        from = mover.tile
        to = wrap(from + if(plan.dir == "cw", do: 1, else: -1))
        remaining = plan.remaining - 1
        st = put_player(st, %{mover | tile: to})
        st = push(st, :step, %{id: mover.id, from: from, to: to, remaining: remaining})

        rivals = Enum.filter(st.order, &(&1 != mover.id and st.players[&1].alive and st.players[&1].tile == to))
        plan = %{plan | remaining: remaining}

        plan =
          if rivals != [], do: %{plan | queue: rivals, kind: if(remaining == 0, do: :land, else: :pass)}, else: plan

        advance(%{st | plan: plan})
    end
  end

  defp start_janken(%{plan: plan} = st) do
    case plan.queue do
      [] ->
        {:empty, st}

      [rid | rest] ->
        st = %{st | plan: %{plan | queue: rest}}

        if st.players[rid].alive do
          a = st.players[plan.id]
          b = st.players[rid]
          st = %{st | pending: %{a: a.id, b: b.id, kind: plan.kind, tile: a.tile, round: 1}, phase: :janken}

          text =
            if plan.kind == :land,
              do: "⚔️ #{a.name} は #{b.name} と同じ石に止まった！ジャンケン！",
              else: "👟 #{a.name} は #{b.name} とすれ違った！ジャンケン！"

          st = push(st, :jankenStart, %{a: a.id, b: b.id, kind: plan.kind, tile: a.tile}, text)
          {:started, open_round(st, :janken, [a.id, b.id])}
        else
          start_janken(st)
        end
    end
  end

  defp finish_janken(st, seed, vals) do
    pd = st.pending
    a = st.players[pd.a]
    b = st.players[pd.b]
    ha = hand_of(vals, a.id, seed)
    hb = hand_of(vals, b.id, seed)
    result = cond do
      ha == hb -> :draw
      @beats[ha] == hb -> :a
      true -> :b
    end

    verdict = if result == :draw, do: "あいこ！", else: "#{if result == :a, do: a.name, else: b.name} の勝ち！"

    st =
      push(st, :jankenRound, %{a: a.id, b: b.id, ha: ha, hb: hb, result: result, round: pd.round},
        "✊ #{a.name}：#{hand_label(ha)} ／ #{b.name}：#{hand_label(hb)} → #{verdict}")

    if result == :draw do
      # あいこ：やり直し（pending は残す）
      open_round(%{st | pending: %{pd | round: pd.round + 1}}, :janken, [a.id, b.id])
    else
      {winner, loser} = if result == :a, do: {a, b}, else: {b, a}
      loser = %{loser | lives: loser.lives - 1}
      st = st |> put_player(loser) |> Map.put(:pending, nil)
      st = push(st, :jankenEnd, %{winner: winner.id, loser: loser.id, lives: loser.lives},
        "💔 #{loser.name} のライフが1減って #{loser.lives} に！")

      if loser.lives <= 0 do
        st = put_player(st, %{loser | alive: false})
        st = push(st, :eliminated, %{id: loser.id, tile: loser.tile}, "💥 #{loser.name} は脱落…")
        alive = alive_ids(st)

        cond do
          length(alive) <= 1 ->
            champ = List.first(alive)
            st = %{st | phase: :over, winner_id: champ, plan: nil}
            push(st, :win, %{id: champ}, "🏆 #{if champ, do: st.players[champ].name, else: "誰も"} が最後まで生き残った！優勝！")

          loser.id == st.plan.id ->
            end_turn(st)

          true ->
            advance(%{st | phase: :moving})
        end
      else
        advance(%{st | phase: :moving})
      end
    end
  end

  defp hand_of(vals, id, seed) do
    case List.keyfind(vals, id, 0) do
      {_, v} when v in @hands -> v
      _ -> Enum.at(@hands, uniform(seed, ["hand:", id], 3))
    end
  end

  # ------------------------------------------------------------------ 「いま誰の何待ちか」（ピアが自分の担当分を実行する）

  @doc """
  入力待ちの一覧。
    {:dir, id, turn_no}   手番の人が向きを選ぶ（人間の判断/CPU/時間切れ）
    {:hand, id, seq}      ジャンケンの手を選んで commit する（同上）
    {:rand, id, seq}      乱数を commit する（自動）
    {:reveal, id, seq}    全員の commit が揃ったので reveal する（自動）
  """
  def awaiting(%{phase: :turn} = st), do: [{:dir, st.turn_id, st.turn_no}]
  def awaiting(%{round: nil}), do: []

  def awaiting(%{round: r}) do
    all_committed = Enum.all?(r.need, &Map.has_key?(r.commits, &1))

    Enum.flat_map(r.need, fn id ->
      cond do
        not Map.has_key?(r.commits, id) -> [{if(r.kind == :janken, do: :hand, else: :rand), id, r.seq}]
        all_committed and not Map.has_key?(r.reveals, id) -> [{:reveal, id, r.seq}]
        true -> []
      end
    end)
  end

  # ------------------------------------------------------------------ 公開用の状態（ブラウザへ）

  def snapshot(st) do
    pd = st.pending

    %{
      phase: phase_name(st.phase),
      players: Enum.map(st.order, &public_player(st, &1)),
      turnId: st.turn_id,
      winnerId: st.winner_id,
      lastRoll: st.last_roll,
      pending:
        pd &&
          %{
            a: pd.a, b: pd.b, kind: pd.kind, tile: pd.tile, round: pd.round,
            # 手は決着まで伏せる。出したかどうか(commit済みか)だけ見せる
            submitted: %{pd.a => committed?(st, pd.a), pd.b => committed?(st, pd.b)}
          },
      tileCount: @tile_count,
      log: st.log
    }
  end

  defp phase_name(:starting), do: "lobby"
  defp phase_name(:moving), do: "turn"
  defp phase_name(p), do: Atom.to_string(p)

  defp committed?(%{round: %{commits: c}}, id), do: Map.has_key?(c, id)
  defp committed?(_, _), do: false

  defp public_player(st, id) do
    p = st.players[id]

    %{
      id: p.id, name: p.name, color: Enum.find_index(st.order, &(&1 == id)), lives: p.lives, tile: p.tile,
      alive: p.alive, bot: p.bot, left: p.left
    }
  end

  # ------------------------------------------------------------------ ピアが使う問い合わせ

  def host_of(st, id), do: st.players[id] && st.players[id].host

  @doc "名簿に登場する担当ノードの一覧（名簿順・重複なし）"
  def hosts(st), do: st.order |> Enum.map(&st.players[&1].host) |> Enum.uniq()

  @doc "ロビーのリーダー＝名簿の先頭の人間。ゲーム開始の提案者になる"
  def leader_host(st) do
    case Enum.find(st.order, &(not st.players[&1].bot)) do
      nil -> nil
      id -> st.players[id].host
    end
  end

  def roster(st), do: Enum.map(st.order, &Map.take(st.players[&1], [:id, :name, :stamp, :host, :bot, :human]))

  # ------------------------------------------------------------------ 小物

  defp add_player(st, id, name, stamp, host, bot?) do
    name = if bot?, do: name, else: clean_name(name)
    name = if name == "", do: "ロボ_" <> String.slice(id, 0, 4), else: name

    p = %{
      id: id, name: name, stamp: stamp, host: host, bot: bot?, human: not bot?, left: false,
      lives: @start_lives, tile: nil, alive: true
    }

    put_player(st, p)
  end

  defp drop_player(st, id) do
    players = Map.delete(st.players, id)
    %{st | players: players, order: sorted_order(players)}
  end

  defp put_player(st, p) do
    players = Map.put(st.players, p.id, p)
    # ロビー中は (stamp, id) 順に並べ直す（誰の画面でも同じ並び＝同じ色）。ゲーム中は固定
    order = if st.phase == :lobby, do: sorted_order(players), else: st.order
    %{st | players: players, order: order}
  end

  defp sorted_order(players), do: players |> Map.values() |> Enum.sort_by(&{&1.stamp, &1.id}) |> Enum.map(& &1.id)

  defp alive_ids(st), do: Enum.filter(st.order, &st.players[&1].alive)

  defp push(st, t, data \\ %{}, text \\ nil) do
    ev = Map.merge(%{t: t, ms: dur(t)}, data)
    {ev, log} = if text, do: {Map.put(ev, :log, text), Enum.take(st.log ++ [text], -@log_limit)}, else: {ev, st.log}
    %{st | out: [ev | st.out], log: log}
  end

  defp wrap(n), do: rem(rem(n, @tile_count) + @tile_count, @tile_count)
  defp dir_label("cw"), do: "右回り"
  defp dir_label(_), do: "左回り"
  defp hand_label("rock"), do: "グー"
  defp hand_label("scissors"), do: "チョキ"
  defp hand_label("paper"), do: "パー"

  defp clean_name(raw) when is_binary(raw) do
    if String.valid?(raw),
      do: raw |> String.replace(~r/[\x00-\x1f\x7f<>]/u, "") |> String.trim() |> String.slice(0, 12),
      else: ""
  end

  defp clean_name(_), do: ""
end
