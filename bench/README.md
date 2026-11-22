# bench/ — 実証用の測定スクリプト

| ファイル | 内容 | 実行 |
|---|---|---|
| `engine_bench.exs` | 入力数/メッセージ数のスケール、乱数の公平性(χ²)、最後のreveal者の1bit偏り、apply速度 | `mix run --no-start bench/engine_bench.exs` |
| `chaos.py` | 4ノードでゲーム開始 → ランダム時刻にランダムな1〜2ノードを SIGKILL。完走率・一致を確認 | `python3 bench/chaos.py 24 7` |
| `fanout.py` | 観戦者を1ノードに集中 / 4ノードに分散した時のノード別CPU・送信量、向き選択→サイコロ確定の遅延 | `python3 bench/fanout.py 100 30 3` |
| `chaos_run1.jsonl`, `chaos_run2.jsonl` | 記事に載せたカオステストの生データ(seed 7 と seed 11) | |

注意: 全ノードを1台のマシン(loopback)で動かしています。実LANの遅延・パケットロス・分断は測っていません。
