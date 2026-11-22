"""配信負荷の分散を測る。同じ4ノード・同じゲーム進行で、観戦クライアントV人を
  A) 全員1つのノードに接続 / B) 4ノードに均等に接続 / C) 観戦者なし
とした時の、ノードごとのCPU秒と送信バイトを比べる。あわせて 手番の向き選択→サイコロ確定 の遅延（commit-reveal 2往復込み）を測る。
  python3 bench/fanout.py [観戦者数V] [計測秒] [反復]
"""
import asyncio, json, os, statistics, subprocess, sys, time
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "scripts"))
import e2e, psutil, websockets
from e2e import Node, Browser, until

e2e.SPEED = "0.1"


def cpu(proc):
    p = psutil.Process(proc.pid)
    tot = 0.0
    for q in [p] + p.children(recursive=True):
        try:
            t = q.cpu_times(); tot += t.user + t.system
        except psutil.Error: pass
    return tot


class Viewer:
    def __init__(self, port): self.port, self.bytes, self.msgs = port, 0, 0
    async def run(self):
        try:
            async with websockets.connect(f"ws://127.0.0.1:{self.port}/ws", max_size=None) as ws:
                async for raw in ws:
                    self.bytes += len(raw); self.msgs += 1
        except Exception: pass


class Ctl(Browser):
    """操作役：向き選択→roll確定の遅延を記録し、ゲームを繰り返し開始する。"""
    def __init__(self, port):
        super().__init__(port); self.t_dir = None; self.lat = []; self.games = 0; self._over = False
    async def send(self, s):
        if s.startswith("chooseDirection"): self.t_dir = time.time()
        await super().send(s)
    async def _rx(self):
        try:
            async for raw in self.ws:
                m = json.loads(raw)
                if m["t"] == "hello": self.id = m["id"]
                elif m["t"] == "update":
                    self.state = m["state"]
                    if self.t_dir and any(e["t"] == "roll" for e in m["events"]):
                        self.lat.append((time.time() - self.t_dir) * 1000); self.t_dir = None
                    ph = self.state["phase"]
                    if ph == "over" and not self._over: self.games += 1
                    self._over = (ph == "over")
                    await self._act()
        except Exception: pass

    async def ticker(self):
        """ゲームの繰り返し役。要求を1回しか送らないと、ロビー遷移の競合で取りこぼした時に止まるので、0.5秒ごとに再送する。"""
        while True:
            await asyncio.sleep(0.5)
            st = self.state
            if not st: continue
            if st["phase"] == "lobby" and len(self.roster()) == 4: await self.send("startGame")
            elif st["phase"] == "over": await self.send("backToLobby")


async def scenario(mode, V, secs):
    nodes = [Node(1)]; nodes[0].wait_ready()
    for i in (2, 3, 4):
        nodes.append(Node(i, join=nodes[0].name))
    for n in nodes[1:]: n.wait_ready()
    ctl = await Ctl(nodes[0].port).start()
    await until(lambda: ctl.state is not None, "接続", 20)
    others = [await Browser(n.port).start() for n in nodes[1:]]      # 他3ノードの人間（自動操作）
    await until(lambda: len(ctl.roster()) == 4, "4人揃う", 20)
    viewers = []
    for i in range(V if mode != "none" else 0):
        port = nodes[0].port if mode == "one" else nodes[i % 4].port
        viewers.append(Viewer(port))
    tasks = [asyncio.create_task(v.run()) for v in viewers]
    await asyncio.sleep(3)                           # 接続を落ち着かせる
    for v in viewers: v.bytes = v.msgs = 0
    ctl.lat.clear(); ctl.games = 0
    ticker = asyncio.create_task(ctl.ticker())
    c0 = [cpu(n.proc) for n in nodes]; t0 = time.time()
    await asyncio.sleep(secs)
    dt = time.time() - t0
    c1 = [cpu(n.proc) for n in nodes]
    per_node_cpu = [round((b - a) / dt * 100, 1) for a, b in zip(c0, c1)]       # CPU使用率%（1コア=100）
    per_node_kb = [round(sum(v.bytes for v in viewers if v.port == n.port) / dt / 1024, 1) for n in nodes]
    per_node_msgs = [round(sum(v.msgs for v in viewers if v.port == n.port) / dt, 0) for n in nodes]
    lat = sorted(ctl.lat)
    res = {"mode": mode, "V": len(viewers), "secs": round(dt), "cpu_pct": per_node_cpu, "out_KBps": per_node_kb,
           "out_msgs": per_node_msgs, "games": ctl.games, "lat_n": len(lat),
           "lat_med_ms": round(statistics.median(lat), 1) if lat else None,
           "lat_p95_ms": round(lat[int(len(lat) * .95) - 1], 1) if len(lat) >= 20 else None}
    for t in tasks + [ticker]: t.cancel()
    for n in nodes: n.kill()
    subprocess.run(["pkill", "-f", "beam.smp"], capture_output=True)
    await asyncio.sleep(1.5)
    return res


async def main():
    V = int(sys.argv[1]) if len(sys.argv) > 1 else 100
    secs = int(sys.argv[2]) if len(sys.argv) > 2 else 40
    reps = int(sys.argv[3]) if len(sys.argv) > 3 else 2
    subprocess.run(["mix", "compile"], cwd=e2e.ROOT, check=True, capture_output=True)
    subprocess.run(["pkill", "-f", "beam.smp"], capture_output=True)
    for r in range(reps):
        for mode in ("none", "one", "spread"):
            print(json.dumps(await scenario(mode, V, secs), ensure_ascii=False), flush=True)

if __name__ == "__main__":
    asyncio.run(main())
