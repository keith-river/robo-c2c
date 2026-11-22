# エンジン層の測定。  mix run --no-start bench/engine_bench.exs
alias Robo.Engine

defmodule B do
  # n 人（各1ホスト）で1ゲームを最後まで回し、入力数を数える。
  def game(n, opts \\ []) do
    adv = Keyword.get(opts, :adv, nil)   # nil | {:fixed, id_index_list}
    st =
      Enum.reduce(0..(n - 1), Engine.new(), fn i, st ->
        {:ok, st, _} = Engine.apply_input(st, "h#{i}", {:join, "h#{i}", "P#{i}", i, "h#{i}"})
        st
      end)

    {:ok, st, _} = Engine.apply_input(st, "h0", {:start, Engine.roster(st)})
    loop(st, 0, 1, adv, %{dice: [], rounds: 0})
  end

  defp loop(%{phase: :over} = st, inputs, _, _adv, acc), do: {st, inputs, acc}
  defp loop(st, inputs, guard, _adv, _acc) when guard > 100_000, do: raise("runaway #{inspect(st.phase)}")

  defp loop(st, inputs, g, adv, acc) do
    case Engine.awaiting(st) do
      [{:dir, id, tn}] ->
        {:ok, st, evs} = Engine.apply_input(st, Engine.host_of(st, id), {:dir, id, tn, Enum.random(["cw", "ccw"])})
        loop(st, inputs + 1, g + 1, adv, acc |> note(evs))

      aw when aw != [] ->
        {st, n, acc} =
          Enum.reduce(aw, {st, 0, acc}, fn
            {k, id, seq}, {st, n, acc} when k in [:rand, :hand] ->
              payload = if k == :hand, do: Enum.random(Engine.hands()), else: :crypto.strong_rand_bytes(8)
              salt = :crypto.strong_rand_bytes(8)
              Process.put({:s, seq, id}, {payload, salt})
              {:ok, st, evs} = Engine.apply_input(st, Engine.host_of(st, id), {:commit, id, seq, Engine.commit_hash(seq, id, payload, salt)})
              {st, n + 1, note(acc, evs)}

            {:reveal, id, seq}, {st, n, acc} ->
              {p, s} = Process.get({:s, seq, id})
              {:ok, st, evs} = Engine.apply_input(st, Engine.host_of(st, id), {:reveal, id, seq, p, s})
              {st, n + 1, note(acc, evs)}
          end)

        loop(st, inputs + n, g + 1, adv, acc)

      [] ->
        # タイマー待ち（演出）のフェーズは存在しない純粋エンジンなので、ここには来ない想定
        raise "stuck in #{st.phase}"
    end
  end

  defp note(acc, evs) do
    Enum.reduce(evs, acc, fn
      %{type: "roll", dice: d}, a -> %{a | dice: [d | a.dice]}
      %{"type" => "roll", "dice" => d}, a -> %{a | dice: [d | a.dice]}
      _, a -> a
    end)
  end
end

IO.puts("== 1. 1ゲームあたりの入力数と、全員への配送メッセージ数（O(N^2)） ==")
IO.puts("N,games,inputs/game(mean),deliveries/game(=inputs*N),turns/game,apply_us/input")

for n <- 2..8 do
  games = 200
  t0 = System.monotonic_time(:microsecond)
  res = for _ <- 1..games, do: B.game(n)
  dt = System.monotonic_time(:microsecond) - t0
  inputs = res |> Enum.map(&elem(&1, 1)) |> Enum.sum()
  turns = res |> Enum.map(fn {st, _, _} -> st.turn_no end) |> Enum.sum()
  mi = inputs / games
  IO.puts("#{n},#{games},#{Float.round(mi, 1)},#{Float.round(mi * n, 1)},#{Float.round(turns / games, 1)},#{Float.round(dt / inputs, 2)}")
end

IO.puts("\n== 2. 乱数の公平性：サイコロ（honest N=4, 200,000回） ==")
roll_dist = fn mk ->
  Enum.reduce(1..200_000, %{}, fn i, acc ->
    seed = Engine.seed(i, mk.(i))
    Map.update(acc, Engine.dice_from(seed), 1, &(&1 + 1))
  end)
end

chi = fn dist, total ->
  e = total / 6
  Enum.reduce(1..6, 0.0, fn k, a -> a + :math.pow(Map.get(dist, k, 0) - e, 2) / e end)
end

report = fn label, dist ->
  total = dist |> Map.values() |> Enum.sum()
  x2 = chi.(dist, total)
  # df=5 の 5% 臨界値 11.07, 1% 臨界値 15.09
  IO.puts("#{label}: " <> Enum.map_join(1..6, " ", fn k -> "#{k}:#{Float.round(Map.get(dist, k, 0) / total * 100, 2)}%" end) <> "  chi2=#{Float.round(x2, 2)} (df=5, 5%臨界=11.07)")
end

rnd = fn -> :crypto.strong_rand_bytes(8) end

report.("honest 4人            ", roll_dist.(fn _ -> for i <- 0..3, do: {"h#{i}", rnd.()} end))
report.("3人が固定値・1人honest", roll_dist.(fn _ -> [{"h0", <<0, 0, 0, 0, 0, 0, 0, 0>>}, {"h1", <<1, 1, 1, 1, 1, 1, 1, 1>>}, {"h2", <<2, 2, 2, 2, 2, 2, 2, 2>>}, {"h3", rnd.()}] end))
report.("全員固定値(悪い乱数源) ", roll_dist.(fn i -> for k <- 0..3, do: {"h#{k}", <<k>>} end))
IO.puts("  ↑ 全員固定でも seq が混ざるのでサイコロ自体は偏らない。ただし結果は予測可能になる（=honestが1人でも居る場合のみ予測不能）")

IO.puts("\n== 3. 最後にrevealする者の1bit操作（honest 3 + 攻撃者1, 攻撃者は他の3人のrevealを見てから開示/不正reveal） ==")
# 攻撃者は commit 済みの payload P を持つ。全員のreveal後に
#   (a) 正しくreveal → 結果 d1 = f(seed with P)
#   (b) 不正reveal/保留 → その者の値は nil として扱われ結果 d0 = f(seed with nil)
# 攻撃者は「どちらが欲しい目に近いか」を選べる。ここでは目標 = 6 が出ること。
trials = 100_000
{win_honest, win_attack, both_fail} =
  Enum.reduce(1..trials, {0, 0, 0}, fn i, {wh, wa, bf} ->
    hon = for k <- 0..2, do: {"h#{k}", rnd.()}
    p = rnd.()
    d1 = Engine.dice_from(Engine.seed(i, hon ++ [{"h3", p}]))
    d0 = Engine.dice_from(Engine.seed(i, hon ++ [{"h3", nil}]))
    {wh + if(d1 == 6, do: 1, else: 0), wa + if(d1 == 6 or d0 == 6, do: 1, else: 0), bf + if(d1 != 6 and d0 != 6, do: 1, else: 0)}
  end)

IO.puts("目標=6 の達成率  正直に開示: #{Float.round(win_honest / trials * 100, 2)}% (理論 16.67%)")
IO.puts("                 不正開示を使う: #{Float.round(win_attack / trials * 100, 2)}% (理論 1-(5/6)^2=30.56%)")
IO.puts("→ 最後のreveal者は『開示 or 無効化』の1bitぶんだけ結果を歪められる。ただし無効化は全員に ⚠️ として公開される。")

IO.puts("\n== 4. apply_input 単体のスループット ==")
st0 = elem(B.game(4), 0)
{:ok, lob, _} = Engine.apply_input(Engine.new(), "h0", {:join, "h0", "P", 0, "h0"})
n = 300_000
t0 = System.monotonic_time(:microsecond)
Enum.reduce(1..n, lob, fn i, s ->
  {:ok, s2, _} = Engine.apply_input(s, "h0", {:set_name, "h0", "name#{rem(i, 10)}"})
  s2
end)
dt = System.monotonic_time(:microsecond) - t0
IO.puts("set_name #{n} 回: #{Float.round(dt / n, 2)} µs/入力 = #{round(n / (dt / 1_000_000))} 入力/秒/コア")
_ = st0
