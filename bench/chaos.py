"""カオステスト：4ノード(人間4)でゲームを開始し、ランダムな時刻にランダムな1〜2ノードを SIGKILL する。
  python3 bench/chaos.py [試行数] [seed]
測るもの: 完走率 / 引き継ぎ遅延(kill→生存ピアの状態で『CPUが引き継ぎ』になるまで) / 生存ピア間の最終状態・出来事列の一致
"""
import asyncio, json, os, random, subprocess, sys, time
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "scripts"))
import e2e
from e2e import Node, Browser, until, final_view, signature

e2e.SPEED = "0.1"
OUT = "/tmp/chaos.jsonl"


async def trial(rng, k):
    nodes = [Node(1)]; nodes[0].wait_ready()
    others = [Node(i, join=nodes[0].name) for i in (2, 3, 4)]
    for n in others: n.wait_ready()
    nodes += others
    e2e.NODES[:] = nodes
    rec = {"killed": k}
    try:
        bs = [await Browser(n.port).start() for n in nodes]
        e2e.BROWSERS[:] = bs
        await until(lambda: all(len(b.roster()) == 4 for b in bs), "4人揃う", 30)
        await bs[0].send("startGame")
        await until(lambda: all(b.state["phase"] != "lobby" for b in bs), "開始", 30)

        victims = rng.sample(range(4), k)
        target = rng.randint(3, 45)
        await until(lambda: len(bs[0].events) >= target or bs[0].state["phase"] == "over", "kill時刻まで進める", 60)
        if bs[0].state["phase"] == "over":
            rec["result"] = "too_late"; return rec
        # 手番や判定の真っ最中を狙う場合もあるが、基本はランダム
        rec["victims"] = victims; rec["phase_at_kill"] = bs[0].state["phase"]
        rec["events_at_kill"] = len(bs[0].events)
        t0 = time.time()
        for v in victims: nodes[v].kill()
        survivors = [i for i in range(4) if i not in victims]
        vids = [bs[v].id for v in victims]

        def taken():
            st = bs[survivors[0]].state
            pl = {p["id"]: p for p in st["players"]}
            return all(pl[i]["bot"] and pl[i]["left"] for i in vids) or st["phase"] == "over"
        await until(taken, "引き継ぎ", 40)
        rec["takeover_s"] = round(time.time() - t0, 2)
        await until(lambda: all(bs[i].state["phase"] == "over" for i in survivors), "完走", 90)
        rec["finish_s"] = round(time.time() - t0, 2)
        views = [final_view(bs[i]) for i in survivors]
        sigs = [signature(bs[i].events) for i in survivors]
        rec["state_equal"] = all(v == views[0] for v in views)
        rec["events_equal"] = all(s == sigs[0] for s in sigs)
        rec["result"] = "ok" if rec["state_equal"] and rec["events_equal"] else "DIVERGED"
        rec["leaked"] = any(bs[i].hands_leaked for i in survivors)
    except AssertionError as e:
        rec["result"] = "STALL"; rec["why"] = str(e)
    finally:
        for n in nodes: n.kill()
        subprocess.run(["pkill", "-f", "beam.smp"], capture_output=True)
        await asyncio.sleep(1.0)
    return rec


async def main():
    n = int(sys.argv[1]) if len(sys.argv) > 1 else 20
    seed = int(sys.argv[2]) if len(sys.argv) > 2 else 1
    rng = random.Random(seed)
    subprocess.run(["mix", "compile"], cwd=e2e.ROOT, check=True, capture_output=True)
    subprocess.run(["pkill", "-f", "beam.smp"], capture_output=True)
    open(OUT, "w").close()
    for i in range(n):
        k = 1 if i % 2 == 0 else 2          # 1台落とす/2台落とす を交互に
        r = await trial(rng, k)
        r["i"] = i
        print(json.dumps(r, ensure_ascii=False), flush=True)
        open(OUT, "a").write(json.dumps(r, ensure_ascii=False) + "\n")
    rs = [json.loads(l) for l in open(OUT)]
    ok = [r for r in rs if r["result"] == "ok"]
    valid = [r for r in rs if r["result"] != "too_late"]
    print(f"\n試行{len(rs)} (有効{len(valid)}, too_late {len(rs)-len(valid)}): 完走かつ一致 {len(ok)}/{len(valid)}")
    for k in (1, 2):
        t = sorted(r["takeover_s"] for r in ok if r["killed"] == k)
        if t: print(f"  {k}台kill: n={len(t)} 引き継ぎ遅延 中央値{t[len(t)//2]}s 最大{t[-1]}s")

if __name__ == "__main__":
    asyncio.run(main())
