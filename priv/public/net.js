/* Socket.io 互換の最小シム。元の main.js を無改造のまま、WebSocket(各PCのElixirノード)につなぐ。
 *   socket.on('connect'|'update'|'disconnect', cb) / socket.emit(event, arg) / socket.id
 * サーバ→ブラウザ: {t:"hello", id}（自分のプレイヤーID）/ {t:"update", state, events}
 * ブラウザ→サーバ: テキスト "イベント名 引数"
 */
(function () {
  function io() {
    const handlers = {};
    let ws = null, retry = 0;
    const sock = {
      id: null,
      on(ev, cb) { (handlers[ev] = handlers[ev] || []).push(cb); return sock; },
      emit(ev, arg) { if (ws && ws.readyState === 1) ws.send(arg === undefined ? ev : ev + ' ' + arg); },
    };
    const fire = (ev, data) => (handlers[ev] || []).forEach((cb) => cb(data));
    function open() {
      ws = new WebSocket((location.protocol === 'https:' ? 'wss://' : 'ws://') + location.host + '/ws');
      ws.onopen = () => { retry = 0; };
      ws.onmessage = (e) => {
        const m = JSON.parse(e.data);
        if (m.t === 'hello') { sock.id = m.id; fire('connect'); }
        else if (m.t === 'update') fire('update', { state: m.state, events: m.events });
      };
      ws.onclose = () => { fire('disconnect'); setTimeout(open, Math.min(3000, 500 * ++retry)); };
    }
    open();
    return sock;
  }
  window.io = io;
})();
