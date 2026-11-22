"""複数のElixirノード(=ピア)を実際に起動し、ブラウザ代わりのWebSocketクライアントで自動プレイして検証する。

  python3 scripts/e2e.py solo     1ノード（人間1 + CPU3）で最後まで
  python3 scripts/e2e.py mesh     3ノード + 途中参加の観戦ノード。全ノードで状態・出来事が一致
  python3 scripts/e2e.py kill     ゲーム中にノードを強制終了 → 生存ピアがCPUとして引き継いで完走
  python3 scripts/e2e.py all
"""
import asyncio, json, os, random, signal, subprocess, sys, time
import websockets

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
COOKIE = "e2e-" + str(os.getpid())
SPEED = "0.04"           # 演出・待ち時間を25倍速に


class Node:
    def __init__(self, idx, join=None):
        self.name = f"n{idx}@127.0.0.1"
        self.port = 3100 + idx
        env = dict(os.environ, ROBO_PORT=str(self.port), ROBO_SPEED=SPEED, ROBO_NAME=f"P{idx}",
                   ERL_AFLAGS="-kernel inet_dist_listen_min 9200 inet_dist_listen_max 9260")
        if join: env["ROBO_JOIN"] = join
        self.log = open(f"/tmp/e2e_n{idx}.log", "w")
        self.proc = subprocess.Popen(["elixir", "--name", self.name, "--cookie", COOKIE, "-S", "mix", "run", "--no-halt"],
                                     cwd=ROOT, env=env, stdout=self.log, stderr=subprocess.STDOUT, start_new_session=True)

    def kill(self):          # 強制終了（SIGKILL）＝突然の電源断のようなもの
        try: os.killpg(self.proc.pid, signal.SIGKILL)
        except ProcessLookupError: pass

    def wait_ready(self, t=40):
        import urllib.request
        end = time.time() + t
        while time.time() < end:
            try:
                urllib.request.urlopen(f"http://127.0.0.1:{self.port}/", timeout=1).read(10); return
            except Exception: time.sleep(0.3)
        raise RuntimeError(f"{self.name} が起動しない: " + open(self.log.name).read()[-500:])


class Browser:
    """ブラウザの代役。state/events を記録し、自分の番・自分のジャンケンのときに自動で操作する。"""
    def __init__(self, port, auto=True, hold_dir=False):
        self.port, self.auto, self.hold_dir = port, auto, hold_dir
        self.id = None; self.state = None; self.events = []; self.nupdates = 0
        self.hands_leaked = False

    async def start(self):
        self.ws = await websockets.connect(f"ws://127.0.0.1:{self.port}/ws", max_size=None)
        self.task = asyncio.create_task(self._rx())
        return self

    async def _rx(self):
        try:
            async for raw in self.ws:
                m = json.loads(raw)
                if m["t"] == "hello": self.id = m["id"]
                elif m["t"] == "update":
                    self.state = m["state"]; self.events += m["events"]; self.nupdates += 1
                    pd = self.state.get("pending")
                    # 伏せているはずの手が state に漏れていないか（決着前の submitted は真偽のみ）
                    if pd and any(not isinstance(v, bool) for v in pd["submitted"].values()): self.hands_leaked = True
                    if self.auto: await self._act()
        except Exception:
            pass

    async def _act(self):
        st = self.state
        if st["phase"] == "turn" and st["turnId"] == self.id and not self.hold_dir:
            await self.send("chooseDirection " + random.choice(["cw", "ccw"]))
        pd = st.get("pending")
        if st["phase"] == "janken" and pd and self.id in (pd["a"], pd["b"]) and not pd["submitted"][self.id]:
            await self.send("chooseHand " + random.choice(["rock", "scissors", "paper"]))

    async def send(self, s):
        try: await self.ws.send(s)
        except Exception: pass

    def roster(self): return [p["id"] for p in (self.state or {}).get("players", [])]

    async def close(self):
        await self.ws.close()


BROWSERS = []
NODES = []

async def until(cond, what, t=60):
    end = time.time() + t
    while time.time() < end:
        if cond(): return
        await asyncio.sleep(0.05)
    for b in BROWSERS:
        st = b.state or {}
        print("  DUMP", b.port, b.id, st.get("phase"), "turn=", st.get("turnId"), "pending=", st.get("pending"), "events=", len(b.events), [e["t"] for e in b.events][-6:])
    for n in NODES:
        r = subprocess.run(["elixir", "--name", "dbg@127.0.0.1", "--cookie", COOKIE, "--rpc-eval", n.name,
            's = :sys.get_state(Robo.Peer); IO.inspect({s.engine.phase, s.engine.round, Robo.Engine.awaiting(s.engine), Map.keys(s.secrets), s.sent, Map.keys(s.timers), s.synced, map_size(s.clients)}, limit: :infinity, width: 200)'],
            capture_output=True, text=True, timeout=30)
        print("  PEER", n.name, (r.stdout + r.stderr).strip()[:900])
    raise AssertionError("timeout: " + what)


def final_view(b):
    return {"winner": b.state["winnerId"], "players": [(p["id"], p["lives"], p["alive"], p["tile"], p["bot"], p["left"]) for p in b.state["players"]]}


def signature(events):
    """出来事の列（再生される演出の列）。全ピアで同一のはず。"""
    return [json.dumps(e, sort_keys=True) for e in events]


# ---------------------------------------------------------------------------------------------
async def scenario_solo():
    print("== solo: 1ノード（人間1 + CPU3）")
    n1 = Node(1); n1.wait_ready()
    try:
        a = await Browser(n1.port).start()
        await until(lambda: a.state and len(a.roster()) == 1, "ロビーに自分が入る")
        for _ in range(3): await a.send("addBot")
        await until(lambda: len(a.roster()) == 4, "CPU3体追加")
        await a.send("startGame")
        await until(lambda: a.state["phase"] == "over", "ゲーム終了", 90)
        alive = [p for p in a.state["players"] if p["alive"]]
        assert len(alive) == 1 and a.state["winnerId"] == alive[0]["id"]
        assert not a.hands_leaked
        print(f"   ✔ {len(a.events)}イベントで決着。勝者={alive[0]['name']}（{'あなた' if alive[0]['id']==a.id else 'CPU'}）")
        await a.send("backToLobby")
        await until(lambda: a.state["phase"] == "lobby" and len(a.roster()) == 4, "ロビーへ戻る")
        print("   ✔ ロビーに戻り、CPUが残る")
    finally:
        n1.kill()


async def scenario_mesh():
    print("== mesh: 3ノード(人間3 + CPU1) + 途中参加の観戦ノード")
    nodes = [Node(1)]; nodes[0].wait_ready()
    for i in (2, 3):
        nodes.append(Node(i, join=nodes[0].name)); nodes[-1].wait_ready()
    NODES[:] = nodes
    try:
        bs = [await Browser(n.port).start() for n in nodes]
        BROWSERS[:] = bs
        await until(lambda: all(len(b.roster()) == 3 for b in bs), "3人がロビーに揃い、全ノードで同じ名簿")
        assert len({tuple(b.roster()) for b in bs}) == 1
        print("   ✔ 3ノードの名簿が一致:", [p["name"] for p in bs[0].state["players"]])
        await bs[1].send("addBot")
        await until(lambda: all(len(b.roster()) == 4 for b in bs), "CPU追加が全ノードへ")
        await bs[2].send("startGame")      # リーダーではないノードから開始 → リーダーへ転送される
        await until(lambda: all(b.state["phase"] in ("turn", "rolling", "janken") for b in bs), "開始")
        await until(lambda: all(any(e["t"] == "start" for e in b.events) for b in bs), "startイベント")
        tiles = [tuple(p["tile"] for p in next(e for e in b.events if e["t"] == "start")["players"]) for b in bs]
        assert len(set(tiles)) == 1 and len(set(tiles[0])) == 4
        print("   ✔ 開始。全員の乱数から決めた初期配置が全ノードで一致:", list(tiles[0]))

        # 途中から4台目のノードが参加（既存ピアから状態をもらって追いつく）
        await until(lambda: len(bs[0].events) > 12, "少し進む")
        late = Node(4, join=nodes[0].name); late.wait_ready(); nodes.append(late); NODES.append(late)
        lb = await Browser(late.port, auto=False).start()
        await until(lambda: lb.state and lb.state["phase"] != "lobby", "途中参加ノードが現在の状態に追いつく")
        print("   ✔ 途中参加ノードが追いついた（phase=%s, 観戦）" % lb.state["phase"])
        assert lb.id not in lb.roster()

        await until(lambda: all(b.state["phase"] == "over" for b in bs + [lb]), "全員で決着", 120)
        views = [final_view(b) for b in bs + [lb]]
        assert all(v == views[0] for v in views), views
        sigs = [signature(b.events) for b in bs]
        assert sigs[0] == sigs[1] == sigs[2], "再生される出来事の列が一致しない"
        assert not any(b.hands_leaked for b in bs)
        # 途中参加ノードのイベントは、自分が見られた範囲が全体の末尾と一致する
        tail = signature(lb.events)
        assert tail == sigs[0][len(sigs[0]) - len(tail):] if tail else True
        print(f"   ✔ 4ノード全てで最終状態が完全一致。勝者={views[0]['winner']}、出来事{len(sigs[0])}件も3ノードで同一")
    finally:
        for n in nodes: n.kill()


async def scenario_kill():
    print("== kill: ゲーム中にノードを強制終了")
    nodes = [Node(1)]; nodes[0].wait_ready()
    for i in (2, 3):
        nodes.append(Node(i, join=nodes[0].name)); nodes[-1].wait_ready()
    NODES[:] = nodes
    try:
        bs = [await Browser(n.port, hold_dir=(i == 2)).start() for i, n in enumerate(nodes)]
        BROWSERS[:] = bs
        await until(lambda: all(len(b.roster()) == 3 for b in bs), "3人揃う")
        await bs[0].send("startGame")
        await until(lambda: bs[0].state["phase"] in ("turn", "rolling", "janken"), "開始")
        victim = bs[2]
        # 3番ノードの人の番になった瞬間（入力待ちの真っ最中）に落とす
        await until(lambda: bs[0].state["phase"] == "turn" and bs[0].state["turnId"] == victim.id, "3番の手番", 30)
        nodes[2].kill()
        print(f"   ✔ {victim.id} の手番中にノードを SIGKILL")
        await until(lambda: all(b.state["phase"] == "over" for b in bs[:2]), "生存2ノードで完走", 120)
        pl = {p["id"]: p for p in bs[0].state["players"]}
        assert pl[victim.id]["bot"] and pl[victim.id]["left"], pl[victim.id]
        assert any("引き継ぎ" in e.get("log", "") for e in bs[0].events)
        assert final_view(bs[0]) == final_view(bs[1])
        print(f"   ✔ 生存ピアがCPUとして引き継ぎ、ゲームは完走。勝者={bs[0].state['winnerId']}、2ノードの最終状態は一致")
    finally:
        for n in nodes: n.kill()


async def main():
    which = sys.argv[1] if len(sys.argv) > 1 else "all"
    subprocess.run(["mix", "compile"], cwd=ROOT, check=True, capture_output=True)
    subprocess.run(["pkill", "-f", "beam.smp"], capture_output=True)
    for name, fn in [("solo", scenario_solo), ("mesh", scenario_mesh), ("kill", scenario_kill)]:
        if which in ("all", name):
            await fn()
    print("ALL PASSED")

if __name__ == "__main__":
    asyncio.run(main())
