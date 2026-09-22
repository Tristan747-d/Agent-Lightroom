const http = require('node:http');
const { URL } = require('node:url');

const queue = [];
// resultSeq：每收到一次插件回报就 +1。客户端（tools/al-cmd）靠它判断
// "这是一次新回报"——只比较 status/message 会在**重复的相同回报**上失灵
// （连发两次 ping 都是 ok/Lightroom Classic connected，签名相同 → 假超时）。
const state = { connected: false, lastSeen: 0, lastResult: null, culling: [], resultSeq: 0 };

// 队列容量上限：插件消费慢时避免无限积压（尤其 snapshot 风暴）。
const QUEUE_LIMIT = 32;
// 幂等/可丢弃的命令类型：重复入队无意义，只保留一条。
const COALESCABLE = new Set(['snapshot', 'ping']);
// 用户主动动作：插到队首，避免被积压的 snapshot 阻塞。
// view = 单张读图（agent 看图），必须即时；add/probe/routine/thumbs = 自动化流程命令。
const PRIORITY = new Set(['import', 'decision', 'adjust', 'sync', 'export', 'view', 'add', 'probe', 'routine', 'thumbs']);

/// 入队策略：优先级命令插队首；可合并命令去重；其余追加。返回入队后长度。
function enqueue(command) {
  const type = command && command.type;
  if (type && COALESCABLE.has(type)) {
    if (queue.some((c) => c && c.type === type)) return queue.length; // 已有同类，丢弃
  }
  if (type && PRIORITY.has(type)) {
    queue.unshift(command);
  } else {
    queue.push(command);
  }
  // 超限时优先丢弃队尾的可合并命令，保住用户动作
  while (queue.length > QUEUE_LIMIT) {
    let dropped = false;
    for (let i = queue.length - 1; i >= 0; i--) {
      if (queue[i] && COALESCABLE.has(queue[i].type)) { queue.splice(i, 1); dropped = true; break; }
    }
    if (!dropped) queue.pop();
  }
  return queue.length;
}

function json(res, value) {
  res.writeHead(200, { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*' });
  res.end(JSON.stringify(value));
}

const server = http.createServer((req, res) => {
  const url = new URL(req.url, 'http://127.0.0.1:8765');
  if (req.method === 'OPTIONS') { res.writeHead(204, { 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Headers': 'content-type' }); res.end(); return; }
  if (url.pathname === '/health') return json(res, { ok: true, connected: Date.now() - state.lastSeen < 5000, ...state, queue: queue.length });
  if (url.pathname === '/state') return json(res, { ok: true, connected: Date.now() - state.lastSeen < 5000, ...state });
  if (url.pathname === '/next') {
    state.connected = true; state.lastSeen = Date.now();
    const command = queue.shift();
    return json(res, command || { type: 'idle' });
  }
  if (url.pathname === '/result') {
    // 支持两种投递方式：
    //   GET  /result?status=…&message=…      —— 短消息（ping/error 等）
    //   POST /result  (body: status/…&… 或 JSON) —— 长负载（如整个目录快照，
    //        1615 张照片拼进 URL 会超过 Node 请求行上限而被拒，必须走 body）
    const applyResult = (params) => {
      state.lastResult = params;
      state.resultSeq = (state.resultSeq || 0) + 1; // 单调递增，供客户端判定"新回报"
      // 目录消隐结果有两种来源（保持前后端兼容）：
      //   1) 旧式 photos=name|flag;name|flag…
      //   2) 目录快照 status=catalog&message=name|flag;…
      // 无论哪种，都解析为 state.culling 供前端 /state 回灌选片状态。
      const raw = params.photos || (params.status === 'catalog' ? params.message : '');
      if (raw) {
        // 行格式（插件端 v0.3 起）：
        //   name|flag|artist|focalLength|shotTime|aperture|shutter|iso
        // 兼容旧的两段式 name|flag（缺失字段留空）。
        state.culling = String(raw)
          .split(';')
          .filter(Boolean)
          .map((item) => {
            const f = item.split('|');
            const [name, flag] = f;
            const rest = f.slice(2);
            return {
              name: name || '',
              flag: flag || 'unflagged',
              // 拍摄信息（工作站状态行）：拍摄者/焦距/时间/光圈/快门/ISO
              shooting: rest.length >= 6 ? rest.slice(0, 6) : null,
            };
          });
      }
    };
    if (req.method === 'POST') {
      let body = '';
      req.on('data', (chunk) => { body += chunk; });
      req.on('end', () => {
        let params = {};
        const trimmed = body.trim();
        if (trimmed.startsWith('{')) {
          try { params = JSON.parse(trimmed); } catch { params = {}; }
        } else {
          params = Object.fromEntries(new URLSearchParams(trimmed).entries());
        }
        applyResult(params);
        json(res, { ok: true, culling: state.culling.length });
      });
      return;
    }
    applyResult(Object.fromEntries(url.searchParams.entries()));
    return json(res, { ok: true, culling: state.culling.length });
  }
  if (url.pathname === '/command' && req.method === 'POST') {
    let body = '';
    req.on('data', (chunk) => { body += chunk; });
    req.on('end', () => {
      try { const n = enqueue(JSON.parse(body)); json(res, { ok: true, queued: n }); }
      catch { res.writeHead(400); res.end('invalid json'); }
    });
    return;
  }
  res.writeHead(404); res.end('not found');
});

server.listen(8765, '127.0.0.1', () => console.log('Agent Lightroom bridge listening on http://127.0.0.1:8765'));
