defmodule Robo.EngineTest do
  use ExUnit.Case, async: true
  alias Robo.Engine

  # ---------------------------------------------------------------- テスト用ヘルパ
  # ホスト名 "h0","h1".. がそれぞれ1プレイヤー（id == host）。

  defp apply!(st, from, input) do
    {:ok, st, evs} = Engine.apply_input(st, from, input)
    {st, evs}
  end

  defp lobby(n, opts \\ []) do
    bots = Keyword.get(opts, :bots, 0)

    st =
      Enum.reduce(0..(n - 1)//1, Engine.new(), fn i, st ->
        {st, _} = apply!(st, "h#{i}", {:join, "h#{i}", "P#{i}", i, "h#{i}"})
        st
      end)

    Enum.reduce(0..(bots - 1)//1, st, fn i, st ->
      {st, _} = apply!(st, "h0", {:add_bot, "bot#{i}", 100 + i, "h0"})
      st
    end)
  end

  defp start!(st) do
    {st, _} = apply!(st, "h0", {:start, Engine.roster(st)})
    {st, _} = run_round(st, :random)
    st
  end

  # 進行中の乱数ラウンドを、全員が commit → reveal して決着させる。
  # payload_fun.(kind, id) が返す値を使う。:random なら乱数。
  defp run_round(st, mode, events \\ [], until \\ fn _ -> false end) do
    case Engine.awaiting(st) do
      [{k, _, _} | _] = aw when k in [:rand, :hand, :reveal] ->
        {st, evs, _} =
          Enum.reduce(aw, {st, events, %{}}, fn
            {kind, id, seq}, {st, evs, secrets} when kind in [:rand, :hand] ->
              payload = payload_for(mode, kind, id)
              salt = :crypto.strong_rand_bytes(8)
              Process.put({:sec, seq, id}, {payload, salt})
              {st2, e} = apply!(st, Engine.host_of(st, id), {:commit, id, seq, Engine.commit_hash(seq, id, payload, salt)})
              {st2, evs ++ e, secrets}

            {:reveal, id, seq}, {st, evs, secrets} ->
              {payload, salt} = Process.get({:sec, seq, id})
              {st2, e} = apply!(st, Engine.host_of(st, id), {:reveal, id, seq, payload, salt})
              {st2, evs ++ e, secrets}
          end)

        if until.(st), do: {st, evs}, else: run_round(st, mode, evs, until)

      _ ->
        {st, events}
    end
  end

  defp payload_for(:random, :rand, _id), do: :crypto.strong_rand_bytes(8)
  defp payload_for(:random, :hand, _id), do: Enum.random(Engine.hands())
  defp payload_for({:hands, map}, :hand, id), do: Map.fetch!(map, id)
  defp payload_for({:hands, _}, :rand, _id), do: :crypto.strong_rand_bytes(8)
  defp payload_for({:dice, _}, :rand, _id), do: :crypto.strong_rand_bytes(8)

  # 手番の人が向きを選び、狙った目が出るまで乱数を引き直す（ハッシュなので総当たり。平均6回）
  defp roll!(st, dir, dice) do
    id = st.turn_id
    {st, _} = apply!(st, Engine.host_of(st, id), {:dir, id, st.turn_no, dir})
    seq = st.round.seq
    ids = st.round.need

    payloads =
      Stream.repeatedly(fn -> Map.new(ids, &{&1, :crypto.strong_rand_bytes(8)}) end)
      |> Enum.find(fn ps -> Engine.dice_from(Engine.seed(seq, Enum.map(ids, &{&1, ps[&1]}))) == dice end)

    reveal_all(st, payloads)
  end

  defp reveal_all(st, payloads) do
    seq = st.round.seq
    salts = Map.new(st.round.need, &{&1, :crypto.strong_rand_bytes(8)})

    st =
      Enum.reduce(st.round.need, st, fn id, st ->
        {st, _} = apply!(st, Engine.host_of(st, id), {:commit, id, seq, Engine.commit_hash(seq, id, payloads[id], salts[id])})
        st
      end)

    Enum.reduce(st.round.need, {st, []}, fn id, {st, evs} ->
      {st, e} = apply!(st, Engine.host_of(st, id), {:reveal, id, seq, payloads[id], salts[id]})
      {st, evs ++ e}
    end)
  end

  defp hands!(st, ha, hb) do
    # ちょうど1ラウンド（あいこなら新しいラウンドが開いた時点）で止める
    pd = st.pending
    seq0 = st.round.seq
    run_round(st, {:hands, %{pd.a => ha, pd.b => hb}}, [], fn st -> st.round == nil or st.round.seq != seq0 end)
  end

  defp ev(evs, t), do: Enum.filter(evs, &(&1.t == t))
  defp put_tile(st, id, tile), do: put_in(st.players[id].tile, tile)
  defp set_turn(st, id), do: %{st | turn_id: id, phase: :turn}

  # 3人を開始し、石と手番を指定する
  defp game(tiles, turn \\ "h0") do
    st = start!(lobby(length(tiles)))
    st = tiles |> Enum.with_index() |> Enum.reduce(st, fn {t, i}, st -> put_tile(st, "h#{i}", t) end)
    set_turn(st, turn)
  end

  # ---------------------------------------------------------------- ロビー

  test "ロビー：参加は(stamp,id)順、別ホストのなりすましは拒否、重複は拒否" do
    st = Engine.new()
    {st, _} = apply!(st, "h1", {:join, "h1", "二番", 2, "h1"})
    {st, _} = apply!(st, "h0", {:join, "h0", "一番", 1, "h0"})
    assert st.order == ["h0", "h1"]
    assert {:error, :auth} = Engine.apply_input(st, "h9", {:join, "h2", "x", 3, "h2"})
    assert {:error, :exists} = Engine.apply_input(st, "h0", {:join, "h0", "x", 5, "h0"})
  end

  test "ロビーの操作は可換：到着順が入れ替わっても同じ名簿になる" do
    inputs = [
      {"h0", {:join, "h0", "A", 1, "h0"}},
      {"h1", {:join, "h1", "B", 2, "h1"}},
      {"h2", {:join, "h2", "C", 3, "h2"}},
      {"h0", {:add_bot, "b1", 4, "h0"}}
    ]

    results =
      for _ <- 1..20 do
        inputs
        |> Enum.shuffle()
        |> Enum.reduce(Engine.new(), fn {from, i}, st ->
          case Engine.apply_input(st, from, i) do {:ok, st, _} -> st; _ -> st end
        end)
        |> Engine.roster()
      end

    assert results |> Enum.uniq() |> length() == 1
  end

  test "CPUの追加・削除・名前変更・退出" do
    st = lobby(2, bots: 2)
    assert Enum.map(Engine.roster(st), & &1.name) |> Enum.take(-2) == ["ロボ太", "メカ吉"]
    {st, _} = apply!(st, "h0", {:remove_bot, "bot1"})
    assert length(st.order) == 3
    {st, _} = apply!(st, "h1", {:set_name, "h1", "<b>たろう</b>あいうえおかきくけこ"})
    refute st.players["h1"].name =~ "<"
    assert String.length(st.players["h1"].name) <= 12
    assert {:error, :auth} = Engine.apply_input(st, "h0", {:set_name, "h1", "のっとり"})
    {st, _} = apply!(st, "h1", {:leave, "h1"})
    assert length(st.order) == 2
  end

  # ---------------------------------------------------------------- 開始

  test "開始：全員の乱数でランダム配置（重ならない）、全員ライフ3、2人未満は不可" do
    one = lobby(1)
    assert {:error, :too_few} = Engine.apply_input(one, "h0", {:start, Engine.roster(one)})
    st = start!(lobby(4))
    assert st.phase == :turn
    tiles = Enum.map(st.players |> Map.values(), & &1.tile)
    assert length(Enum.uniq(tiles)) == 4 and Enum.all?(tiles, &(&1 in 0..19))
    assert Enum.all?(Map.values(st.players), &(&1.lives == 3))
    assert st.turn_id in st.order
  end

  test "初期配置は全員の寄与で決まる：同じ乱数なら同じ、1人でも違えば結果が変わる" do
    st0 = lobby(3)
    {st1, _} = apply!(st0, "h0", {:start, Engine.roster(st0)})
    fixed = Map.new(st1.order, &{&1, <<1, 2, 3>>})
    {a, _} = reveal_all(st1, fixed)
    {b, _} = reveal_all(st1, fixed)
    assert Map.new(a.players, fn {k, p} -> {k, p.tile} end) == Map.new(b.players, fn {k, p} -> {k, p.tile} end)
    assert a.turn_id == b.turn_id

    diff = Map.put(fixed, "h2", <<9, 9, 9>>)
    {c, _} = reveal_all(st1, diff)
    refute Map.new(c.players, fn {k, p} -> {k, p.tile} end) == Map.new(a.players, fn {k, p} -> {k, p.tile} end)
  end

  # ---------------------------------------------------------------- 移動

  test "右回りは +1 ずつ、左回りは -1 ずつ。輪になっている（19→0）" do
    st = game([5, 12, 0])
    {st, evs} = roll!(st, "cw", 3)
    assert ev(evs, :step) |> Enum.map(& &1.to) == [6, 7, 8]
    assert st.players["h0"].tile == 8

    st = game([18, 10, 6])
    {_st, evs} = roll!(st, "cw", 4)
    assert ev(evs, :step) |> Enum.map(& &1.to) == [19, 0, 1, 2]

    st = game([1, 10, 8]) |> set_turn("h0")
    {st, evs} = roll!(st, "ccw", 3)
    assert ev(evs, :step) |> Enum.map(& &1.to) == [0, 19, 18]
    assert st.players["h0"].tile == 18
  end

  test "ジャンケンがなければ、次の人の番になる" do
    {st, _} = roll!(game([0, 10, 15]), "cw", 2)
    assert st.phase == :turn and st.turn_id == "h1"
  end

  test "自分の番でない人・担当でないノード・不正な向きは受け付けない" do
    st = game([0, 10, 15])
    tn = st.turn_no
    assert {:error, _} = Engine.apply_input(st, "h1", {:dir, "h1", tn, "cw"})
    assert {:error, :auth} = Engine.apply_input(st, "h1", {:dir, "h0", tn, "cw"})
    assert {:error, :bad_dir} = Engine.apply_input(st, "h0", {:dir, "h0", tn, "up"})
    assert {:error, :invalid} = Engine.apply_input(st, "h0", {:dir, "h0", tn - 1, "cw"})
  end

  # ---------------------------------------------------------------- 乱数ラウンドの検証

  test "commit：担当でないノード・二重・不要な人は拒否" do
    st = game([0, 10, 15])
    {st, _} = apply!(st, "h0", {:dir, "h0", st.turn_no, "cw"})
    seq = st.round.seq
    h = Engine.commit_hash(seq, "h0", "x", "s")
    assert {:error, :auth} = Engine.apply_input(st, "h1", {:commit, "h0", seq, h})
    {st, _} = apply!(st, "h0", {:commit, "h0", seq, h})
    assert {:error, :dup} = Engine.apply_input(st, "h0", {:commit, "h0", seq, h})
    assert {:error, :invalid} = Engine.apply_input(st, "h0", {:commit, "h0", seq - 1, h})
    assert {:error, :not_needed} = Engine.apply_input(st, "h9", {:commit, "h9", seq, h})
  end

  test "reveal が commit と一致しなければ無効化され、注意ログが出て、ゲームは進む" do
    st = game([0, 10, 15])
    {st, _} = apply!(st, "h0", {:dir, "h0", st.turn_no, "cw"})
    seq = st.round.seq

    {st, evs} =
      Enum.reduce(st.round.need, {st, []}, fn id, {st, acc} ->
        {st, _} = apply!(st, id, {:commit, id, seq, Engine.commit_hash(seq, id, "honest", "salt")})
        {st, e} = apply!(st, id, {:reveal, id, seq, if(id == "h1", do: "CHEAT", else: "honest"), "salt"})
        {st, acc ++ e}
      end)

    assert Enum.any?(evs, &(&1.t == :note and &1.log =~ "不正"))
    assert st.phase == :turn and st.turn_id != "h0"
  end

  test "全員が commit するまで reveal を促さない（commitを見てから後出しできない）" do
    st = game([0, 10, 15])
    {st, _} = apply!(st, "h0", {:dir, "h0", st.turn_no, "cw"})
    seq = st.round.seq
    assert Enum.all?(Engine.awaiting(st), &match?({:rand, _, ^seq}, &1))
    {st, _} = apply!(st, "h0", {:commit, "h0", seq, Engine.commit_hash(seq, "h0", "a", "s")})
    assert Enum.any?(Engine.awaiting(st), &match?({:rand, "h1", _}, &1))
    refute Enum.any?(Engine.awaiting(st), &match?({:reveal, _, _}, &1))
  end

  # ---------------------------------------------------------------- ジャンケン

  test "同じ石に止まるとジャンケン(land)。勝者のライフは増えず、敗者が1減る" do
    st = game([0, 3, 15])
    {st, evs} = roll!(st, "cw", 3)
    assert [%{kind: :land, a: "h0", b: "h1"}] = ev(evs, :jankenStart)
    assert st.phase == :janken
    {st, evs} = hands!(st, "rock", "scissors")
    assert [%{result: :a}] = ev(evs, :jankenRound)
    assert st.players["h0"].lives == 3 and st.players["h1"].lives == 2
    assert st.phase == :turn and st.turn_id == "h1"
  end

  test "手は決着まで伏せられる：snapshotには出したかどうかだけ（commitのみ・平文なし）" do
    st = game([0, 3, 15])
    {st, _} = roll!(st, "cw", 3)
    pd = st.pending
    {payload, salt} = {"rock", "s"}
    h = Engine.commit_hash(st.round.seq, pd.a, payload, salt)
    {st, _} = apply!(st, pd.a, {:commit, pd.a, st.round.seq, h})
    snap = Engine.snapshot(st)
    assert snap.pending.submitted == %{pd.a => true, pd.b => false}
    refute inspect(snap) =~ "rock"
    # 相手の commit が揃うまで reveal は要求されない
    refute Enum.any?(Engine.awaiting(st), &match?({:reveal, _, _}, &1))
  end

  test "あいこは決着がつくまでやり直し（ライフは減らない）" do
    st = game([0, 3, 15])
    {st, _} = roll!(st, "cw", 3)
    {st, evs} = hands!(st, "rock", "rock")
    assert [%{result: :draw, round: 1}] = ev(evs, :jankenRound)
    assert st.phase == :janken and st.pending.round == 2
    assert st.players["h0"].lives == 3 and st.players["h1"].lives == 3
    {st, evs} = hands!(st, "paper", "rock")
    assert [%{result: :a, round: 2}] = ev(evs, :jankenRound)
    assert st.players["h1"].lives == 2
  end

  test "すれ違い(pass)：途中の石に相手がいたらジャンケン、終わったら続きを進む" do
    st = game([0, 2, 15])
    {st, evs} = roll!(st, "cw", 4)
    assert [%{kind: :pass}] = ev(evs, :jankenStart)
    assert st.players["h0"].tile == 2
    {st, evs} = hands!(st, "scissors", "rock")
    assert [%{result: :b}] = ev(evs, :jankenRound)
    assert ev(evs, :step) |> Enum.map(& &1.to) == [3, 4]
    assert st.players["h0"].tile == 4 and st.players["h0"].lives == 2
  end

  test "途中と最後の石の両方に相手がいれば、2回ジャンケンする" do
    st = game([0, 2, 4])
    {st, _} = roll!(st, "cw", 4)
    {st, _} = hands!(st, "rock", "scissors")
    assert st.phase == :janken and st.pending.kind == :land and st.pending.b == "h2"
    {st, _} = hands!(st, "rock", "scissors")
    assert st.players["h1"].lives == 2 and st.players["h2"].lives == 2 and st.turn_id == "h1"
  end

  test "ライフ0で脱落、最後の1人になったら優勝" do
    st = game([0, 3, 15])
    st = put_in(st.players["h1"].lives, 1)
    {st, _} = roll!(st, "cw", 3)
    {st, evs} = hands!(st, "rock", "scissors")
    assert [%{id: "h1"}] = ev(evs, :eliminated)
    refute st.players["h1"].alive
    assert st.phase == :turn and st.turn_id == "h2"

    st = put_in(st.players["h2"].lives, 1)
    st = put_tile(st, "h0", 5) |> put_tile("h2", 7) |> set_turn("h0")
    {st, evs} = roll!(st, "cw", 2)
    {st, evs2} = hands!(st, "paper", "rock")
    assert [%{id: "h0"}] = ev(evs ++ evs2, :win)
    assert st.phase == :over and st.winner_id == "h0"
    assert Engine.awaiting(st) == []
  end

  test "動いていた本人が脱落したら、その場で手番終了して次の人へ" do
    st = game([0, 3, 15])
    st = put_in(st.players["h0"].lives, 1)
    {st, _} = roll!(st, "cw", 3)
    {st, evs} = hands!(st, "rock", "paper")
    assert [%{id: "h0"}] = ev(evs, :eliminated)
    assert st.phase == :turn and st.turn_id == "h1"
  end

  # ---------------------------------------------------------------- 切断・CPU引き継ぎ

  test "ゲーム中の切断：生き残りが引き継ぎ、CPUとして続行（担当が変わる）" do
    st = game([0, 10, 15])
    assert {:error, :auth} = Engine.apply_input(st, "h1", {:takeover, "h0", "h2"})
    {st, evs} = apply!(st, "h1", {:takeover, "h0", "h1"})
    assert st.players["h0"] |> Map.take([:bot, :left, :host]) == %{bot: true, left: true, host: "h1"}
    assert [%{log: log}] = ev(evs, :note)
    assert log =~ "CPUが引き継ぎ"
    # 引き継いだ後は新しい担当ノードだけが h0 を操作できる
    assert {:error, :auth} = Engine.apply_input(st, "h0", {:dir, "h0", st.turn_no, "cw"})
    assert {:ok, _, _} = Engine.apply_input(st, "h1", {:dir, "h0", st.turn_no, "cw"})
    assert {:error, :noop} = Engine.apply_input(st, "h1", {:takeover, "h0", "h1"})
  end

  test "乱数ラウンド中に担当が変わったら、前の担当が出しかけた commit は捨てられる" do
    st = game([0, 10, 15])
    {st, _} = apply!(st, "h0", {:dir, "h0", st.turn_no, "cw"})
    seq = st.round.seq
    {st, _} = apply!(st, "h2", {:commit, "h2", seq, Engine.commit_hash(seq, "h2", "x", "s")})
    {st, _} = apply!(st, "h1", {:takeover, "h2", "h1"})
    refute Map.has_key?(st.round.commits, "h2")
    assert Enum.any?(Engine.awaiting(st), &match?({:rand, "h2", ^seq}, &1))
  end

  test "ロビーでは takeover ではなく leave で外れる／ロビーへ戻ると離脱者は消える" do
    # ロビーの複製に届いた takeover は「まだ開始が届いていない」可能性があるので保留される（効果なし）
    {held, []} = apply!(lobby(2), "h0", {:takeover, "h1", "h0"})
    assert length(held.early) == 1 and held.players["h1"].bot == false
    st = game([0, 3, 15])
    {st, _} = apply!(st, "h0", {:takeover, "h2", "h0"})
    st = %{st | phase: :over}
    {st, evs} = apply!(st, "h0", :back_to_lobby)
    assert st.phase == :lobby and Map.keys(st.players) |> Enum.sort() == ["h0", "h1"]
    assert Enum.all?(Map.values(st.players), &(&1.lives == 3 and &1.alive))
    assert [%{t: :lobby}] = evs
  end

  # ---------------------------------------------------------------- 複製の収束（この設計の肝）

  # 全員が自分の担当を実行するドライバ。毎ステップの入力を「複製ごとに違う順序」で適用する。
  defp drive_replicas(replicas, steps, mode \\ :random) do
    aw = Engine.awaiting(hd(replicas))

    if aw == [] or steps == 0 do
      replicas
    else
      inputs =
        Enum.map(aw, fn
          {:dir, id, tn} ->
            {Engine.host_of(hd(replicas), id), {:dir, id, tn, Enum.random(["cw", "ccw"])}}

          {kind, id, seq} when kind in [:rand, :hand] ->
            payload = payload_for(mode, kind, id)
            salt = :crypto.strong_rand_bytes(8)
            Process.put({:sec, seq, id}, {payload, salt})
            {Engine.host_of(hd(replicas), id), {:commit, id, seq, Engine.commit_hash(seq, id, payload, salt)}}

          {:reveal, id, seq} ->
            {payload, salt} = Process.get({:sec, seq, id})
            {Engine.host_of(hd(replicas), id), {:reveal, id, seq, payload, salt}}
        end)

      replicas =
        Enum.map(replicas, fn st ->
          inputs
          |> Enum.shuffle()
          |> Enum.reduce(st, fn {from, i}, st ->
            case Engine.apply_input(st, from, i) do
              {:ok, st, _} -> st
              {:error, r} -> flunk("拒否された入力 #{inspect(i)}: #{r}")
            end
          end)
        end)

      [first | rest] = replicas
      assert Enum.all?(rest, &(&1 == first)), "複製が食い違った（steps=#{steps}）"
      drive_replicas(replicas, steps - 1, mode)
    end
  end

  test "3つの複製に同じ入力を違う順序で適用しても、全ゲームを通して状態が完全に一致する" do
    for _ <- 1..30 do
      st = lobby(3, bots: 2)
      {st, _} = apply!(st, "h0", {:start, Engine.roster(st)})
      replicas = drive_replicas([st, st, st], 5000)
      assert Enum.all?(replicas, &(&1.phase == :over))
    end
  end

  # 実ネットワークと同じ条件：同じ送信者の入力は順序が保たれ、別の送信者の入力は任意に入れ替わる。
  defp random_interleave(log) do
    queues = log |> Enum.group_by(fn {from, _} -> from end) |> Map.values()

    Stream.unfold(queues, fn
      [] -> nil
      qs ->
        {[x | rest], i} = qs |> Enum.with_index() |> Enum.random()
        {x, List.replace_at(qs, i, rest) |> Enum.reject(&(&1 == []))}
    end)
    |> Enum.to_list()
  end

  # 1つの「基準の履歴」を作る（全員が入力を出し、基準の複製に適用）
  defp record_game(st) do
    Stream.unfold({st, 0}, fn {st, n} ->
      aw = Engine.awaiting(st)

      if aw == [] or n > 5000 do
        nil
      else
        inputs =
          Enum.map(aw, fn
            {:dir, id, tn} -> {Engine.host_of(st, id), {:dir, id, tn, Enum.random(["cw", "ccw"])}}
            {kind, id, seq} when kind in [:rand, :hand] ->
              payload = payload_for(:random, kind, id)
              salt = :crypto.strong_rand_bytes(8)
              Process.put({:sec, seq, id}, {payload, salt})
              {Engine.host_of(st, id), {:commit, id, seq, Engine.commit_hash(seq, id, payload, salt)}}
            {:reveal, id, seq} ->
              {payload, salt} = Process.get({:sec, seq, id})
              {Engine.host_of(st, id), {:reveal, id, seq, payload, salt}}
          end)

        st2 = Enum.reduce(inputs, st, fn {from, i}, st -> elem(Engine.apply_input(st, from, i), 1) end)
        {inputs, {st2, n + 1}}
      end
    end)
    |> Enum.to_list()
    |> List.flatten()
  end

  test "送信者ごとの順序だけ保たれ、送信者間は任意に入れ替わっても、全複製が同じ最終状態になる（因果順序の入れ替わり）" do
    for _ <- 1..60 do
      st = lobby(4, bots: 2)
      {st, _} = apply!(st, "h0", {:start, Engine.roster(st)})
      log = record_game(st)
      reference = Enum.reduce(log, st, fn {from, i}, s -> elem(Engine.apply_input(s, from, i), 1) end)
      assert reference.phase == :over and reference.early == []

      for _ <- 1..5 do
        replica =
          log
          |> random_interleave()
          |> Enum.reduce(st, fn {from, i}, s ->
            case Engine.apply_input(s, from, i) do
              {:ok, s, _} -> s
              {:error, r} -> flunk("拒否: #{inspect(i)} #{r}")
            end
          end)

        diff = for {k, v} <- reference, Map.get(replica, k) != v, do: {k, v, Map.get(replica, k)}
        assert diff == [], "複製が食い違った: #{inspect(diff, limit: 8)}"
      end
    end
  end

  test "前提が未到着の入力は保留され、前提が揃った時点で適用される（commitが向き選択を追い越す）" do
    st = game([0, 10, 15])
    seq = st.rseq + 1
    h = Engine.commit_hash(seq, "h1", "x", "s")
    # ラウンドがまだ開いていない時点で届いた commit → 捨てずに保留
    {st, []} = apply!(st, "h1", {:commit, "h1", seq, h})
    assert length(st.early) == 1 and st.round == nil
    # 向き選択が届いてラウンドが開くと、保留されていた commit が取り込まれる
    {st, _} = apply!(st, "h0", {:dir, "h0", st.turn_no, "cw"})
    assert st.round.commits["h1"] == h and st.early == []
  end

  test "ランダム対戦を何百回やっても、必ず1人が残って終わる（不変条件）" do
    for n <- 1..300 do
      humans = 2 + rem(n, 4)
      st = lobby(humans, bots: rem(n, 3))
      {st, _} = apply!(st, "h0", {:start, Engine.roster(st)})
      [st] = drive_replicas([st], 5000)
      assert st.phase == :over
      alive = st.players |> Map.values() |> Enum.filter(& &1.alive)
      assert length(alive) == 1 and st.winner_id == hd(alive).id
      assert Enum.all?(Map.values(st.players), &(&1.lives in 0..3 and &1.tile in 0..19))
    end
  end

  test "JSONにできる（ブラウザへ送れる）スナップショットとイベント" do
    st = game([0, 3, 15])
    {st, evs} = roll!(st, "cw", 3)
    json = Robo.JSON.encode(%{state: Engine.snapshot(st), events: evs})
    assert json =~ "\"jankenStart\"" and json =~ "\"submitted\""
  end
end
