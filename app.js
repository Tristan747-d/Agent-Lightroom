/* ============================================================
   Agent Lightroom — 智能摄影后期工作站 Demo
   全流程：导入 → EXIF → 自动选片 → 相似筛选 → 自然语言调色
          → 局部蒙版 → 批量同步 → 导出
   人在环：审片、审美判断、最终确认（Agent 不自动交付）
   纯前端 / 离线；可选：(1) 从文件夹导入真实照片  (2) 桥接本地 Lightroom Classic 驱动
   ============================================================ */
const $ = (s, r = document) => r.querySelector(s);
const $$ = (s, r = document) => [...r.querySelectorAll(s)];
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const clamp = (v, a, b) => Math.max(a, Math.min(b, v));

/* 桥接本地 Lightroom Classic 驱动（127.0.0.1:8765）；无驱动时静默降级为纯演示 */
async function sendBridge(command) {
  try {
    await fetch("http://127.0.0.1:8765/command", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(command),
    });
    return true;
  } catch {
    return false; // 演示模式：无真实驱动
  }
}

async function pollBridge() {
  const pill = $("#statusPill");
  if (!pill) return;
  try {
    const health = await fetch("http://127.0.0.1:8765/health").then((r) => r.json());
    pill.classList.add("bridge-online");
    pill.title = health.lastSeen ? "Lightroom Classic Bridge 在线" : "Bridge 服务在线，等待 Lightroom 插件";
  } catch {
    pill.classList.remove("bridge-online");
    pill.title = "Lightroom Classic Bridge 未连接，当前为本地演示模式";
  }
}

/* ---------- 演示成片（无外部资源时由 SVG 场景生成）---------- */
const DEMO = [
  { id: "p1", name: "DSC_4821", scene: "portrait", cam: "Nikon Z8", lens: "85mm f/1.8 S", iso: 3200, aperture: 1.8, ss: "1/160s", wb: 5200, focal: 85, rating: 0, flag: "", isDup: false, dupOf: null, focus: 0.95, bias: -0.1 },
  { id: "p2", name: "DSC_4822", scene: "portrait", cam: "Nikon Z8", lens: "85mm f/1.8 S", iso: 3200, aperture: 1.8, ss: "1/160s", wb: 5200, focal: 85, rating: 0, flag: "", isDup: true, dupOf: "p1", focus: 0.72, bias: -0.08 },
  { id: "p3", name: "DSC_4830", scene: "landscape", cam: "Nikon Z8", lens: "24-70mm f/2.8", iso: 100, aperture: 9, ss: "1/250s", wb: 5600, focal: 35, rating: 0, flag: "", isDup: false, dupOf: null, focus: 0.9, bias: 0.05 },
  { id: "p4", name: "DSC_4835", scene: "street", cam: "Nikon Z8", lens: "35mm f/1.8", iso: 800, aperture: 2, ss: "1/200s", wb: 6000, focal: 35, rating: 0, flag: "", isDup: false, dupOf: null, focus: 0.84, bias: 0.02 },
  { id: "p5", name: "DSC_4842", scene: "night", cam: "Nikon Z8", lens: "50mm f/1.2", iso: 4000, aperture: 1.8, ss: "1/100s", wb: 4200, focal: 50, rating: 0, flag: "", isDup: false, dupOf: null, focus: 0.82, bias: -0.25 },
  { id: "p6", name: "DSC_4850", scene: "product", cam: "Nikon Z8", lens: "105mm f/2.8 Macro", iso: 200, aperture: 5.6, ss: "1/160s", wb: 5800, focal: 105, rating: 0, flag: "", isDup: false, dupOf: null, focus: 0.97, bias: 0.0 },
  { id: "p7", name: "DSC_4833", scene: "landscape", cam: "Nikon Z8", lens: "24-70mm f/2.8", iso: 100, aperture: 9, ss: "1/240s", wb: 5600, focal: 35, rating: 0, flag: "", isDup: true, dupOf: "p3", focus: 0.65, bias: 0.04 },
  { id: "p8", name: "DSC_4844", scene: "night", cam: "Nikon Z8", lens: "50mm f/1.2", iso: 4000, aperture: 1.8, ss: "1/125s", wb: 4200, focal: 50, rating: 0, flag: "", isDup: false, dupOf: null, focus: 0.9, bias: -0.12 },
];
let PHOTOS = DEMO.map((p) => ({ ...p, imgUrl: null }));
const byId = (id) => PHOTOS.find((p) => p.id === id);
let hero = PHOTOS[0];

/* ---------- 流水线步骤 ---------- */
const STEPS = [
  { id: "import", ico: "↓", t: "导入存储卡" },
  { id: "exif", ico: "◷", t: "EXIF 分析" },
  { id: "cull", ico: "◇", t: "自动选片" },
  { id: "similar", ico: "⧉", t: "相似筛选" },
  { id: "grade", ico: "◐", t: "自然语言调色" },
  { id: "mask", ico: "▣", t: "局部蒙版" },
  { id: "sync", ico: "⛓", t: "批量同步" },
  { id: "export", ico: "↗", t: "导出交付" },
];
const stepState = {};
let currentStep = "import";

/* ---------- 调色参数（范围 -50..50）---------- */
const DEFAULT_PARAMS = { exposure: 0, contrast: 0, highlights: 0, shadows: 0, whites: 0, blacks: 0, temperature: 0, tint: 0, saturation: 0, vibrance: 0, clarity: 0, vignette: 0, maskSubject: 0, maskBg: 0, mono: false };
let params = { ...DEFAULT_PARAMS };
let lastInterpret = [];

/* ============================================================
   SVG 场景生成（离线、无外部图片）
   ============================================================ */
function sceneMarkup(p) {
  const id = p.id;
  if (p.scene === "portrait") {
    return `<defs><radialGradient id="${id}-key" cx="40%" cy="32%" r="60%"><stop offset="0%" stop-color="#3a2c20"/><stop offset="55%" stop-color="#1a140f"/><stop offset="100%" stop-color="#0a0806"/></radialGradient>
      <linearGradient id="${id}-skin" x1="0" y1="0" x2="1" y2="1"><stop offset="0%" stop-color="#caa07e"/><stop offset="60%" stop-color="#9c7355"/><stop offset="100%" stop-color="#5e4533"/></linearGradient></defs>
      <rect width="400" height="300" fill="url(#${id}-key)"/>
      <ellipse cx="150" cy="92" rx="120" ry="120" fill="#ffb061" opacity="0.10"/>
      <path d="M120 300 C120 220 150 185 200 185 C250 185 280 220 280 300 Z" fill="url(#${id}-skin)"/>
      <ellipse cx="200" cy="120" rx="58" ry="68" fill="url(#${id}-skin)"/>
      <path d="M150 110 C150 80 180 64 200 64 C220 64 250 80 250 110 C250 150 220 172 200 172 C180 172 150 150 150 110 Z" fill="none" stroke="#ffd9a8" stroke-width="3" opacity="0.5"/>
      <ellipse cx="178" cy="112" rx="6" ry="7" fill="#2a1c12"/><ellipse cx="222" cy="112" rx="6" ry="7" fill="#2a1c12"/>
      <path d="M185 146 q15 12 30 0" fill="none" stroke="#7a4f38" stroke-width="3" stroke-linecap="round"/>`;
  }
  if (p.scene === "landscape") {
    return `<defs><linearGradient id="${id}-sky" x1="0" y1="0" x2="0" y2="1"><stop offset="0%" stop-color="#9ec9ff"/><stop offset="55%" stop-color="#dff0ff"/><stop offset="100%" stop-color="#fbe6c4"/></linearGradient></defs>
      <rect width="400" height="300" fill="url(#${id}-sky)"/><circle cx="310" cy="70" r="26" fill="#fff3d6" opacity="0.9"/>
      <path d="M0 200 L90 130 L150 175 L230 110 L300 165 L400 120 L400 300 L0 300 Z" fill="#5b6b78"/>
      <path d="M0 235 L70 185 L140 220 L220 170 L300 215 L400 180 L400 300 L0 300 Z" fill="#33414d"/>
      <rect y="265" width="400" height="35" fill="#26323b"/>`;
  }
  if (p.scene === "street") {
    let bokeh = "";
    [[60,70,26,"#ffd27a"],[120,50,18,"#ff9d6b"],[200,90,30,"#9fd0ff"],[300,60,22,"#ffcf8a"],[340,120,16,"#c7a0ff"],[90,160,20,"#ffb061"],[250,170,24,"#8fd6ff"]].forEach(([x,y,r,c]) => (bokeh += `<circle cx="${x}" cy="${y}" r="${r}" fill="${c}" opacity="0.55"/>`));
    return `<rect width="400" height="300" fill="#161a22"/>${bokeh}<ellipse cx="200" cy="240" rx="46" ry="60" fill="#0c0e13"/><ellipse cx="200" cy="205" rx="26" ry="30" fill="#0c0e13"/>`;
  }
  if (p.scene === "night") {
    let win = "";
    for (let r = 0; r < 6; r++) for (let c = 0; c < 10; c++) { const x = 20 + c * 38 + ((r % 2) * 8), y = 30 + r * 42, on = (r * 7 + c * 3) % 5 !== 0; win += `<rect x="${x}" y="${y}" width="22" height="26" rx="2" fill="${on ? "#ffd98a" : "#2b3340"}" opacity="${on ? 0.9 : 0.6}"/>`; }
    return `<rect width="400" height="300" fill="#0a1020"/><rect width="400" height="300" fill="#0e1830" opacity="0.6"/>${win}<circle cx="330" cy="60" r="22" fill="#dfe9ff" opacity="0.85"/>`;
  }
  return `<defs><radialGradient id="${id}-bg" cx="50%" cy="40%" r="70%"><stop offset="0%" stop-color="#2a2f38"/><stop offset="100%" stop-color="#0c0e12"/></radialGradient></defs>
    <rect width="400" height="300" fill="url(#${id}-bg)"/><ellipse cx="200" cy="225" rx="80" ry="14" fill="#000" opacity="0.5"/>
    <circle cx="200" cy="150" r="62" fill="#1d2128" stroke="#3a414c" stroke-width="4"/><circle cx="200" cy="150" r="50" fill="#0f1217"/><circle cx="200" cy="150" r="40" fill="none" stroke="#4a525e" stroke-width="3"/>
    <line x1="200" y1="150" x2="200" y2="118" stroke="#cdd6e2" stroke-width="3" stroke-linecap="round"/><line x1="200" y1="150" x2="226" y2="160" stroke="#cdd6e2" stroke-width="3" stroke-linecap="round"/>
    <rect x="186" y="86" width="28" height="14" rx="4" fill="#3a414c"/><path d="M150 150 q-40 30 -30 90 l160 0 q10 -60 -30 -90" fill="#23272f" opacity="0.85"/>`;
}
function editFilter(p) {
  const f = [];
  f.push(`brightness(${1 + p.exposure * 0.006 + p.shadows * 0.002})`);
  f.push(`contrast(${1 + p.contrast * 0.004 + p.clarity * 0.003})`);
  f.push(`saturate(${1 + p.saturation * 0.004 + p.vibrance * 0.003})`);
  if (p.clarity > 0) f.push("blur(0.15px)");
  if (p.mono) f.push("grayscale(1) contrast(1.04)");
  return f.join(" ");
}
function overlayDivs(p) {
  let s = "";
  if (p.temperature !== 0) { const a = Math.min(0.5, Math.abs(p.temperature) * 0.005); s += `<div class="ovl" style="background:${p.temperature > 0 ? "#ff8a2a" : "#2a6cff"};opacity:${a};mix-blend-mode:soft-light"></div>`; }
  if (p.tint !== 0) { const a = Math.min(0.4, Math.abs(p.tint) * 0.004); s += `<div class="ovl" style="background:${p.tint > 0 ? "#ff3aa0" : "#3aff8a"};opacity:${a};mix-blend-mode:soft-light"></div>`; }
  if (p.highlights < 0) s += `<div class="ovl" style="background:#000;opacity:${Math.min(0.45, -p.highlights * 0.005)};mix-blend-mode:screen"></div>`;
  if (p.vignette > 0 || p.maskBg > 0) { const a = Math.min(0.7, Math.max(p.vignette * 0.005, p.maskBg * 0.006)); s += `<div class="ovl vig" style="opacity:${a};mix-blend-mode:multiply"></div>`; }
  if (p.maskSubject > 0) { const a = Math.min(0.6, p.maskSubject * 0.006); s += `<div class="ovl subj" style="opacity:${a};mix-blend-mode:screen"></div>`; }
  return s;
}
function renderPhoto(el, p, pms) {
  if (p.imgUrl) {
    if (!pms) { el.innerHTML = `<img src="${p.imgUrl}" style="width:100%;height:100%;object-fit:cover" alt="">`; return; }
    el.innerHTML = `<img src="${p.imgUrl}" style="width:100%;height:100%;object-fit:cover;filter:${editFilter(pms)}">${overlayDivs(pms)}`;
    return;
  }
  const COMMON_DEFS = `<radialGradient id="vig" cx="50%" cy="48%" r="62%"><stop offset="55%" stop-color="#fff"/><stop offset="100%" stop-color="#000"/></radialGradient><radialGradient id="subj" cx="50%" cy="46%" r="34%"><stop offset="0%" stop-color="#fff"/><stop offset="100%" stop-color="#000"/></radialGradient>`;
  if (!pms) { el.innerHTML = `<svg viewBox="0 0 400 300" preserveAspectRatio="xMidYMid slice"><defs>${COMMON_DEFS}</defs>${sceneMarkup(p)}</svg>`; return; }
  let ov = "";
  if (p.temperature !== 0) { const a = Math.min(0.5, Math.abs(p.temperature) * 0.005); ov += `<rect width="400" height="300" fill="${p.temperature > 0 ? "#ff8a2a" : "#2a6cff"}" opacity="${a}" style="mix-blend-mode:soft-light"/>`; }
  if (p.tint !== 0) { const a = Math.min(0.4, Math.abs(p.tint) * 0.004); ov += `<rect width="400" height="300" fill="${p.tint > 0 ? "#ff3aa0" : "#3aff8a"}" opacity="${a}" style="mix-blend-mode:soft-light"/>`; }
  if (p.highlights < 0) ov += `<rect width="400" height="300" fill="#000" opacity="${Math.min(0.45, -p.highlights * 0.005)}" style="mix-blend-mode:screen"/>`;
  if (p.vignette > 0 || p.maskBg > 0) { const a = Math.min(0.7, Math.max(p.vignette * 0.005, p.maskBg * 0.006)); ov += `<rect width="400" height="300" fill="url(#vig)" opacity="${a}" style="mix-blend-mode:multiply"/>`; }
  if (p.maskSubject > 0) { const a = Math.min(0.6, p.maskSubject * 0.006); ov += `<rect width="400" height="300" fill="url(#subj)" opacity="${a}" style="mix-blend-mode:screen"/>`; }
  el.innerHTML = `<svg viewBox="0 0 400 300" preserveAspectRatio="xMidYMid slice"><defs>${COMMON_DEFS}</defs><g style="filter:${editFilter(pms)}">${sceneMarkup(p)}</g>${ov}</svg>`;
}

/* ============================================================
   左侧流水线 / 视图切换
   ============================================================ */
function renderRail() {
  const nav = $("#pipeline"); if (!nav) return;
  nav.innerHTML = "";
  STEPS.forEach((s) => {
    const st = stepState[s.id] || "idle";
    const el = document.createElement("button");
    el.className = "nav-item" + (currentStep === s.id ? " active" : "");
    el.dataset.id = s.id;
    const dotCls = st === "done" ? "done" : st === "run" ? "run" : st === "wait" ? "wait" : "";
    el.innerHTML = `<span class="nav-icon">${s.ico}</span><span>${s.t}</span><span class="nav-dot ${dotCls}"></span>`;
    el.onclick = () => focusStep(s.id);
    nav.appendChild(el);
  });
}
function focusStep(id) {
  currentStep = id;
  const pageMap = { import: "import", exif: "import", cull: "cull", similar: "cull", grade: "work", mask: "work", sync: "work", export: "export" };
  $$(".nav-item").forEach((x) => x.classList.remove("active"));
  $$(`.nav-item[data-id="${id}"]`).forEach((x) => x.classList.add("active"));
  $("#page-title").textContent = STEPS.find((s) => s.id === id).t;
  $$(".page").forEach((x) => x.classList.remove("active"));
  $("#page-" + pageMap[id]).classList.add("active");
  showSubView(id);
  renderRail();
  renderStage();
}
function showSubView(id) {
  const map = { import: "importView", exif: "exifView", cull: "cullView", similar: "similarView", grade: "workView", mask: "maskView", export: "exportView" };
  ["importView","exifView","cullView","similarView","workView","maskView","exportView"].forEach((v) => ($("#" + v).style.display = v === map[id] ? "" : "none"));
}
function renderStage() {
  ({ import: stageImport, exif: stageExif, cull: stageCull, similar: stageSimilar, grade: stageGrade, mask: stageMask, export: stageExport }[currentStep] || stageImport)();
}

/* ============================================================
   各步骤视图
   ============================================================ */
function stageImport() {
  $("#importView").innerHTML = `
    <div class="setup-grid">
      <section class="panel import-drop">
        <div class="folder-symbol"></div>
        <h2>选择存储卡或文件夹</h2>
        <p id="source-path">尚未选择导入来源（演示将使用内置示例照片）</p>
        <button class="primary-action" id="choose-source">选择文件夹</button>
        <input type="file" id="source-picker" multiple accept="image/*" style="display:none" />
      </section>
      <section class="panel options-panel">
        <h2>Lightroom 导入选项</h2>
        <label class="field"><span>导入方式</span><select><option>复制为 DNG</option><option selected>复制</option><option>添加到目录</option></select></label>
        <label class="field"><span>目标位置</span><input value="/Volumes/PhotoVault/2026/Wedding_Afterparty" /></label>
        <label class="check-row"><input type="checkbox" checked /><span>构建智能预览</span></label>
        <label class="check-row"><input type="checkbox" checked /><span>导入时应用镜头校正</span></label>
        <label class="check-row"><input type="checkbox" /><span>跳过疑似重复照片</span></label>
        <button class="primary-action full" id="startImport">开始导入并分析 EXIF</button>
      </section>
      <section class="panel insight-panel">
        <h2>Agent 预分析</h2>
        <div class="metric-row"><span>当前素材</span><strong id="mCount">8 张</strong></div>
        <div class="metric-row"><span>连拍组</span><strong id="mGroup">2 组</strong></div>
        <div class="analysis-note">导入只读取元数据与生成预览，原始 RAW 不被改动；最终确认权始终在你。如已安装本地 Lightroom Classic 驱动，Agent 会真正下发命令。</div>
      </section>
    </div>`;
  $("#choose-source").onclick = () => $("#source-picker").click();
  $("#source-picker").onchange = (e) => loadRealPhotos(e.target.files);
  $("#startImport").onclick = runImport;
}
async function loadRealPhotos(fileList) {
  const files = [...fileList].filter((f) => f.type.startsWith("image/"));
  if (!files.length) { toast("未识别到图片文件，使用演示照片"); return; }
  PHOTOS = files.map((f, i) => ({
    id: "r" + i, name: f.name, scene: "portrait", cam: "本地文件", lens: "", iso: 0, aperture: 0, ss: "", wb: 0, focal: 0,
    rating: 0, flag: i === 0 ? "" : "", isDup: false, dupOf: null, focus: 0.9, bias: 0, imgUrl: URL.createObjectURL(f),
  }));
  hero = PHOTOS[0];
  $("#mCount") && ($("#mCount").textContent = files.length + " 张");
  $("#mGroup") && ($("#mGroup").textContent = "—");
  $("#source-path") && ($("#source-path").textContent = `${files.length} 张照片 · 已载入本地预览`);
  renderFilmstrip();
  agentSay("act", `已载入 <b>${files.length} 张</b>本地照片，建立预览。`, 0);
}

function stageExif() {
  const rows = PHOTOS.map((p) => `<tr class="${p.flag === "reject" ? "" : "sel"}"><td>${p.name}</td><td>${p.cam} ${p.lens || ""}</td><td>${p.aperture ? p.aperture + " · " + p.ss + " · ISO " + p.iso + " · " + p.focal + "mm" : "—"}</td><td>${p.wb ? p.wb + "K" : "—"}</td><td>${p.scene}</td></tr>`).join("");
  $("#exifView").innerHTML = `
    <div class="stage-head" style="display:flex;align-items:center;gap:12px;margin-bottom:14px"><h2 style="margin:0">🏷️ EXIF 分析</h2><span class="chip">相机 / 镜头 / 曝光三角</span><span class="chip">场景自动归类</span></div>
    <div class="panel" style="padding:0;overflow:auto"><table class="exif-table"><thead><tr><th>文件名</th><th>相机 / 镜头</th><th>曝光三角</th><th>白平衡</th><th>场景</th></tr></thead><tbody>${rows}</tbody></table></div>
    <div class="gate"><div class="gt">👁 人在环</div><div class="gd">EXIF 为事实数据，Agent 已自动归类场景与色温。请核对无误后进入自动选片。</div>
      <div class="row-btns"><button class="primary-action" id="toCull">进入自动选片 →</button></div></div>`;
  $("#toCull").onclick = runCull;
}

function stageCull() {
  $("#cullView").innerHTML = `
    <div class="stage-head" style="display:flex;align-items:center;gap:12px;margin-bottom:14px"><h2 style="margin:0">⭐ 自动选片</h2><span class="chip">评分：对焦 · 曝光 · 构图 · 重复惩罚</span></div>
    <div class="preview-layout">
      <section class="image-stage panel" style="grid-template-rows:1fr"><div class="photo-frame" id="cullFrame"></div></section>
      <aside class="panel decision-panel">
        <h2>选片建议</h2>
        <div class="rating-line"><span class="stars" id="cullStars">★★★★☆</span><strong id="cullVerdict">保留</strong></div>
        <p id="cullNote"></p>
        <div class="button-grid"><button id="bPick">保留</button><button id="bRej">淘汰</button><button id="bStar">+1 星</button><button id="bHero">设为主片</button></div>
        <h3>建议入选</h3><div class="maskline" id="pickList"></div>
        <div class="gate"><div class="gt">👁 人在环 · 审片</div><div class="gd">技术评分由 Agent 给出，<b>审美取舍由你</b>：可改星标、改保留对象，或整批采纳。</div>
          <div class="row-btns"><button class="btn amber" id="acceptCull">采纳 Agent 选片</button><button class="primary-action" id="toSimilar">确认并相似筛选 →</button></div></div>
      </aside>
    </div>`;
  renderPhoto($("#cullFrame"), hero);
  const upd = () => {
    const st = Math.round(hero.rating);
    $("#cullStars").textContent = "★".repeat(st) + "☆".repeat(5 - st);
    $("#cullVerdict").textContent = hero.flag === "reject" ? "淘汰" : hero.rating >= 4 ? "保留" : "待定";
    $("#cullNote").textContent = `${hero.name} · ${hero.scene} · 技术评分 ${(hero.focus * 5).toFixed(1)}/5。审美是否到位由你判断。`;
  };
  upd(); renderPickList();
  $("#bPick").onclick = () => { hero.flag = "pick"; hero.rating = Math.max(hero.rating, 4); upd(); renderPickList(); renderFilmstrip(); };
  $("#bRej").onclick = () => { hero.flag = "reject"; upd(); renderPickList(); renderFilmstrip(); };
  $("#bStar").onclick = () => { hero.rating = Math.min(5, hero.rating + 1); upd(); };
  $("#bHero").onclick = () => { hero = byId(hero.id); renderPhoto($("#cullFrame"), hero); upd(); toast(`已设 ${hero.name} 为主片`); };
  $("#acceptCull").onclick = () => { doCull(); renderPhoto($("#cullFrame"), hero); upd(); renderPickList(); renderFilmstrip(); agentSay("act", `已按技术评分套用：<b>${cullCounts().pick} 张入选，${cullCounts().reject} 张标记 reject</b>。`); };
  $("#toSimilar").onclick = runSimilar;
}

function stageSimilar() {
  const groups = groupDuplicates();
  let html = `<div class="stage-head" style="display:flex;align-items:center;gap:12px;margin-bottom:14px"><h2 style="margin:0">⧉ 相似照片筛选</h2><span class="chip">连拍 / 近似构图，每组保留最佳</span></div><div class="panel" style="padding:20px">`;
  groups.forEach((g, gi) => {
    const isDup = g.members.length > 1;
    const head = isDup ? `组 ${gi + 1} · 相似度 ${(g.sim * 100).toFixed(0)}% · 建议保留 <b id="best${gi}" style="color:var(--amber)">${g.best.name}</b>` : `独立成片 · ${g.best.name}（无近似）`;
    html += `<div style="margin-bottom:18px"><div class="chip" style="margin-bottom:8px">${head}</div><div class="filmstrip scrollbar" style="grid-template-columns:repeat(${g.members.length},108px);border:0;padding:0" data-g="${gi}"></div></div>`;
  });
  html += `<div class="gate"><div class="gt">👁 人在环</div><div class="gd">Agent 仅建议保留哪一张（对焦更实 / 构图更稳）。若你要表情更自然或另一张，点对应缩略图改选。</div>
    <div class="row-btns"><button class="primary-action" id="toGrade">确认并进入调色 →</button></div></div></div>`;
  $("#similarView").innerHTML = html;
  groups.forEach((g, gi) => {
    const fs = $(`.filmstrip[data-g="${gi}"]`);
    g.members.forEach((pid) => {
      const p = byId(pid);
      const t = document.createElement("div");
      t.className = "thumb" + (g.best.id === pid ? " best" : "");
      renderPhoto(t, p);
      t.onclick = () => { g.best = p; fs.querySelectorAll(".thumb").forEach((x) => x.classList.remove("best")); t.classList.add("best"); const b = $(`#best${gi}`); if (b) b.textContent = p.name; agentSay("user", `组 ${gi + 1} 改选保留 <b>${p.name}</b>`); };
      fs.appendChild(t);
    });
  });
  $("#toGrade").onclick = runGrade;
}

function stageGrade() {
  $("#workView").innerHTML = `
    <div class="stage-head" style="display:flex;align-items:center;gap:12px;margin-bottom:14px"><h2 style="margin:0">◐ 自然语言调色</h2><span class="chip">主片 <b style="color:var(--amber)">${hero.name}</b></span></div>
    <div class="work-layout">
      <section class="image-stage panel" style="grid-template-rows:1fr"><div class="compare" id="cmpGrade">
        <div class="layer before"><div class="ph" id="cmpBefore"></div></div>
        <div class="layer after"><div class="ph" id="cmpAfter"></div></div>
        <div class="lbl l">原图</div><div class="lbl r">Agent 调色</div><div class="handle" id="cmpHandleGrade"></div></div></section>
      <aside class="panel chat-panel"><h2>Agent 解读</h2>
        <div class="maskline" id="interpret">${lastInterpret.length ? lastInterpret.map((i) => `<span class="mtag">${i}</span>`).join("") : '<span class="chip">在右侧用自然语言描述思路并点「调色」</span>'}</div>
        <div class="params" id="paramBars" style="margin-top:14px"></div>
        <div class="gate"><div class="gt">👁 人在环 · 确认调色</div><div class="gd">拖动中间滑块核对前后对比，参数是否到位由你判断。满意后进入局部蒙版。</div>
          <div class="row-btns"><button class="btn ghost" id="undoGrade">↺ 还原</button><button class="primary-action" id="approveGrade">✓ 确认调色</button><button class="btn" id="toMask">下一步：蒙版 →</button></div></div></aside>
      <aside class="panel adjust-panel"><h2>快速修改</h2>
        <label>曝光 <input type="range" min="-50" max="50" value="${params.exposure}" id="rExp" /></label>
        <label>白平衡 <input type="range" min="-50" max="50" value="${params.temperature}" id="rTemp" /></label>
        <label>对比 <input type="range" min="-50" max="50" value="${params.contrast}" id="rCon" /></label>
        <label>高光 <input type="range" min="-50" max="50" value="${params.highlights}" id="rHi" /></label>
        <label>阴影 <input type="range" min="-50" max="50" value="${params.shadows}" id="rSh" /></label>
        <label>饱和 <input type="range" min="-50" max="50" value="${params.saturation}" id="rSat" /></label></aside>
    </div>`;
  renderPhoto($("#cmpBefore"), hero);
  renderPhoto($("#cmpAfter"), hero, params);
  renderParamBars(); setupCompare("cmpGrade");
  const reApply = () => { params.exposure = +$("#rExp").value; params.temperature = +$("#rTemp").value; params.contrast = +$("#rCon").value; params.highlights = +$("#rHi").value; params.shadows = +$("#rSh").value; params.saturation = +$("#rSat").value; renderPhoto($("#cmpAfter"), hero, params); renderParamBars(); };
  ["rExp","rTemp","rCon","rHi","rSh","rSat"].forEach((id) => ($("#" + id).oninput = reApply));
  $("#undoGrade").onclick = () => { params = { ...DEFAULT_PARAMS }; lastInterpret = []; focusStep("grade"); };
  $("#approveGrade").onclick = () => { stepState.mask = "wait"; toast("调色已确认"); focusStep("mask"); };
  $("#toMask").onclick = () => focusStep("mask");
}

function stageMask() {
  $("#maskView").innerHTML = `
    <div class="stage-head" style="display:flex;align-items:center;gap:12px;margin-bottom:14px"><h2 style="margin:0">▣ 局部蒙版</h2><span class="chip">主片 <b style="color:var(--amber)">${hero.name}</b></span></div>
    <div class="work-layout">
      <section class="image-stage panel" style="grid-template-rows:1fr"><div class="compare" id="cmpMask">
        <div class="layer before"><div class="ph" id="mBefore"></div></div>
        <div class="layer after"><div class="ph" id="mAfter"></div></div>
        <div class="lbl l">无蒙版</div><div class="lbl r">蒙版后</div><div class="handle" id="cmpHandleMask"></div></div></section>
      <aside class="panel chat-panel"><h2>蒙版说明</h2><div class="maskline" id="maskTags"></div>
        <div class="gate"><div class="gt">👁 人在环</div><div class="gd">蒙版由调色意图自动推导（如「人物亮一点 / 背景压暗」）。拖动滑块微调强度，或显示蒙版范围核对选区是否准确。</div>
          <div class="row-btns"><button class="btn" id="showMask">显示蒙版范围</button><button class="primary-action" id="toSync">确认并批量同步 →</button></div></div></aside>
      <aside class="panel adjust-panel"><h2>蒙版强度</h2>
        <label>主体提亮 <input type="range" min="0" max="50" value="${params.maskSubject}" id="ms" /></label>
        <label>背景压暗 <input type="range" min="0" max="50" value="${params.maskBg}" id="mb" /></label></aside>
    </div>`;
  renderPhoto($("#mBefore"), hero);
  renderPhoto($("#mAfter"), hero, params); renderMaskTags(); setupCompare("cmpMask");
  const upd = () => { params.maskSubject = +$("#ms").value; params.maskBg = +$("#mb").value; renderPhoto($("#mAfter"), hero, params); renderMaskTags(); };
  $("#ms").oninput = upd; $("#mb").oninput = upd;
  $("#showMask").onclick = () => { const after = $("#mAfter"); let viz = after.parentElement.querySelector(".mask-viz"); if (viz) viz.remove(); else { viz = document.createElement("div"); viz.className = "mask-viz"; after.parentElement.appendChild(viz); } };
  $("#toSync").onclick = runSync;
}

function stageExport() {
  const targets = PHOTOS.filter((p) => !p.isDup && p.flag !== "reject");
  $("#exportView").innerHTML = `
    <div class="stage-head" style="display:flex;align-items:center;gap:12px;margin-bottom:14px"><h2 style="margin:0">↗ 导出交付</h2><span class="chip">${targets.length} 张成片</span></div>
    <div class="setup-grid">
      <section class="panel import-drop"><div class="folder-symbol export"></div><h2>选择导出文件夹</h2><p id="export-path">/Volumes/Delivery/Wedding_Afterparty_Final</p><button class="primary-action" id="choose-export">更改位置</button></section>
      <section class="panel options-panel"><h2>导出设置</h2>
        <label class="field"><span>格式</span><select id="exFmt"><option selected>JPEG</option><option>TIFF</option><option>DNG</option></select></label>
        <label class="field"><span>色彩空间</span><select><option selected>sRGB</option><option>Adobe RGB</option><option>Display P3</option></select></label>
        <label class="field"><span>长边尺寸</span><input value="3840 px" /></label>
        <label class="field"><span>文件命名</span><input value="Afterparty_####" /></label>
        <button class="primary-action full" id="doExport">导出 ${targets.length} 张精选</button></section>
      <section class="panel insight-panel"><h2>交付检查</h2>
        <div class="metric-row"><span>已选片</span><strong>${targets.length}</strong></div>
        <div class="metric-row"><span>已调色</span><strong>${targets.length}</strong></div>
        <div class="metric-row"><span>已蒙版</span><strong>${PHOTOS.filter((p) => params.maskSubject > 0 || params.maskBg > 0).length}</strong></div>
        <div class="metric-row"><span>待你确认</span><strong style="color:var(--amber)">${targets.length}</strong></div>
        <div class="analysis-note">Agent 会在导出前检查裁切、噪点、肤色偏移与同步遗漏，但<b>最终交付需你点确认</b>。</div></section>
    </div>
    <div class="gate"><div class="gt">👁 人在环 · 最终确认</div><div class="gd">导出即交付。请核对上方预览与参数，确认无误再点「导出」。Agent 不会自动交付。</div>
      <div class="row-btns"><button class="primary-action good" id="doExport2">✓ 我确认，导出成片</button></div></div>
    <div class="progress"><i id="exProg"></i></div>`;
  $("#choose-export").onclick = () => ($("#export-path").textContent = "/Volumes/Delivery/Client_Selects");
  const run = async () => {
    const prog = $("#exProg"); stepState.export = "run"; setStatus("导出中…", true); renderRail();
    sendBridge({ type: "export", count: targets.length, path: $("#export-path") ? $("#export-path").textContent : "" });
    const n = targets.length;
    for (let i = 1; i <= n; i++) { prog.style.width = (i / n * 100) + "%"; await sleep(220); }
    stepState.export = "done"; renderRail(); setStatus("导出完成 · 待你验收", false);
    agentSay("see", `导出完成：<b>${n} 张</b> 已写入 ~/Exports/Wedding_Afterparty/。请打开验收。`);
    toast("导出完成 · 请验收成片");
  };
  $("#doExport").onclick = run; $("#doExport2").onclick = run;
}

/* ============================================================
   胶片条 / 选片工具
   ============================================================ */
function renderFilmstrip() {
  const fs = $("#filmstrip"); if (!fs) return;
  fs.innerHTML = "";
  PHOTOS.forEach((p) => {
    const t = document.createElement("div");
    t.className = "film" + (p.flag === "reject" ? " rejected" : "") + (p.id === hero.id ? " active" : "") + (p.flag === "pick" ? " selected" : "");
    renderPhoto(t, p);
    const cap = document.createElement("div"); cap.className = "cap"; cap.innerHTML = `<span>${p.name}</span><span>${p.scene}</span>`; t.appendChild(cap);
    if (p.flag) { const f = document.createElement("div"); f.className = "flag"; f.textContent = p.flag === "pick" ? "✔" : "✕"; t.appendChild(f); }
    t.onclick = () => { hero = byId(p.id); if (currentStep === "cull") stageCull(); else if (currentStep === "grade") stageGrade(); else if (currentStep === "mask") stageMask(); else renderFilmstrip(); };
    fs.appendChild(t);
  });
}
function renderPickList() {
  const el = $("#pickList"); if (!el) return;
  const picks = PHOTOS.filter((p) => p.flag === "pick" || (p.flag === "" && p.rating >= 4 && !p.isDup));
  el.innerHTML = picks.length ? picks.map((p) => `<span class="mtag">${p.name}</span>`).join("") : '<span class="chip">尚无入选</span>';
}
function cullCounts() {
  const picks = PHOTOS.filter((p) => p.flag === "pick" || (p.flag === "" && p.rating >= 4 && !p.isDup));
  const rejects = PHOTOS.filter((p) => p.flag === "reject");
  return { pick: picks.length, reject: rejects.length };
}
function doCull() {
  PHOTOS.forEach((p) => {
    let score = p.focus;
    if (p.isDup) score -= 0.4;
    if (Math.abs(p.bias) > 0.22) score -= 0.12;
    p.rating = score > 0.9 ? 5 : score > 0.8 ? 4 : score > 0.7 ? 3 : score > 0.55 ? 2 : 1;
    p.flag = p.isDup || score < 0.6 ? "reject" : score > 0.85 ? "pick" : "";
  });
}
function groupDuplicates() {
  const groups = [];
  const handled = new Set(); // 已归组的照片（含 best）
  PHOTOS.forEach((p) => {
    if (p.isDup && !handled.has(p.dupOf) && !handled.has(p.id)) {
      const best = byId(p.dupOf);
      handled.add(best.id); handled.add(p.id);
      groups.push({ members: [best.id, p.id], best: best.focus >= p.focus ? best : p, sim: 0.93 });
    }
  });
  PHOTOS.forEach((p) => {
    if (!handled.has(p.id)) { handled.add(p.id); groups.push({ members: [p.id], best: p, sim: 1 }); }
  });
  return groups;
}

/* ============================================================
   对比 / 参数条 / 蒙版标签
   ============================================================ */
function setupCompare(rootId) {
  const cmp = document.getElementById(rootId); if (!cmp) return;
  const after = cmp.querySelector(".after"); const handle = cmp.querySelector(".handle");
  if (!after || !handle) return;
  let dragging = false;
  const setX = (clientX) => { const r = cmp.getBoundingClientRect(); let x = clamp((clientX - r.left) / r.width, 0.02, 0.98); after.style.clipPath = `inset(0 0 0 ${(x * 100).toFixed(1)}%)`; handle.style.left = (x * 100).toFixed(1) + "%"; };
  handle.onpointerdown = (e) => { dragging = true; handle.setPointerCapture(e.pointerId); };
  cmp.onpointermove = (e) => { if (dragging) setX(e.clientX); };
  cmp.onpointerup = () => (dragging = false);
}
function renderParamBars() {
  const wrap = $("#paramBars"); if (!wrap) return;
  const keys = [["exposure","曝光"],["contrast","对比度"],["highlights","高光"],["shadows","阴影"],["temperature","色温"],["tint","色调"],["saturation","饱和度"],["vibrance","自然饱和"],["clarity","清晰度"],["vignette","暗角"]];
  wrap.innerHTML = keys.map(([k, label]) => { const v = params[k] || 0; const pct = clamp(50 + v * 1.2, 2, 98); const left = pct < 50; return `<div class="prow"><span class="k">${label}</span><span class="bar"><i style="left:${left ? pct : 50}%;width:${Math.abs(pct - 50)}%"></i></span><span class="v">${v > 0 ? "+" : ""}${v}</span></div>`; }).join("");
}
function renderMaskTags() {
  const el = $("#maskTags"); if (!el) return;
  const tags = [];
  if (params.maskSubject > 0) tags.push(`<span class="mtag">主体提亮 ${params.maskSubject}</span>`);
  if (params.maskBg > 0) tags.push(`<span class="mtag bg">背景压暗 ${params.maskBg}</span>`);
  if (!tags.length) tags.push('<span class="chip">未启用局部蒙版</span>');
  el.innerHTML = tags.join("");
}

/* ============================================================
   自然语言 → Lightroom 参数
   ============================================================ */
function interpretPrompt(text) {
  const t = text.toLowerCase();
  const out = { ...DEFAULT_PARAMS };
  const notes = [];
  const has = (...kw) => kw.some((k) => t.includes(k));
  if (has("氛围", "现场", "气氛")) { out.temperature += 6; out.saturation -= 4; out.contrast -= 3; notes.push("保留现场氛围：微暖、降饱和、控对比"); }
  if (has("暖", "温暖", "暖调")) { out.temperature += 12; notes.push("色温 +：偏暖"); }
  if (has("冷", "清冷", "冷调", "蓝调")) { out.temperature -= 12; notes.push("色温 −：偏冷"); }
  if (has("亮", "提亮", "欠曝", "太暗")) { out.exposure += 10; out.shadows += 8; notes.push("曝光 +：整体提亮 / 抬阴影"); }
  if (has("压暗", "调暗", "暗下去")) { out.exposure -= 8; notes.push("曝光 −：整体压暗"); }
  if (has("人物", "主体", "人像", "脸")) { if (has("亮", "提亮")) { out.maskSubject += 7; notes.push("局部蒙版：主体提亮"); } }
  if (has("背景")) { if (has("压暗", "暗", "暗下去")) { out.maskBg += 7; notes.push("局部蒙版：背景压暗"); } if (has("虚化", "模糊")) { out.maskBg += 4; notes.push("局部蒙版：背景弱化"); } }
  if (has("对比", "对比度")) { out.contrast += 10; notes.push("对比度 +"); }
  if (has("饱和", "鲜艳", "浓")) { out.saturation += 14; notes.push("饱和度 +"); }
  if (has("自然", "清淡", "素雅")) { out.saturation -= 6; out.contrast -= 4; out.vibrance += 4; notes.push("偏自然：降饱和、微提自然饱和"); }
  if (has("清新")) { out.exposure += 6; out.saturation += 8; out.temperature -= 4; out.shadows += 6; notes.push("清新感：提亮 + 提饱和 + 微冷"); }
  if (has("高光")) { out.highlights -= 10; notes.push("高光 −（保留灯/云细节）"); }
  if (has("阴影")) { out.shadows += 10; notes.push("阴影 +（提亮暗部）"); }
  if (has("灰", "去灰", "通透")) { out.contrast += 6; out.clarity += 8; out.blacks -= 4; notes.push("去灰 / 通透：加对比 + 清晰度"); }
  if (has("锐", "清晰")) { out.clarity += 10; notes.push("清晰度 +"); }
  if (has("复古", "胶片", "胶卷")) { out.temperature += 8; out.tint += 4; out.contrast -= 4; out.saturation -= 6; out.vignette += 5; notes.push("复古胶片：暖偏移 + 微绿调 + 暗角"); }
  if (has("黑白", "单色", "mono")) { out.mono = true; notes.push("单色：转黑白"); }
  if (has("暗角", "vignette")) { out.vignette += 8; notes.push("暗角 +"); }
  if (!notes.length) notes.push("未识别明确意图，应用中性基线（可补充描述）");
  return { params: out, notes };
}

/* ============================================================
   Agent 日志 / 状态
   ============================================================ */
function agentSay(type, html, typingMs = 0) {
  const log = $("#log"); if (!log) return;
  const wrap = document.createElement("div");
  wrap.className = "msg " + type;
  const label = { think: "思考", act: "执行", see: "验证", user: "你" }[type] || "";
  wrap.innerHTML = `<div class="h"><span class="badge">${label}</span></div><div class="b"></div>`;
  log.appendChild(wrap);
  const body = wrap.querySelector(".b");
  log.scrollTop = log.scrollHeight;
  if (typingMs > 0) { const dot = document.createElement("span"); dot.className = "typing"; body.appendChild(dot); return new Promise(async (res) => { await sleep(typingMs); body.removeChild(dot); body.innerHTML = html; log.scrollTop = log.scrollHeight; res(); }); }
  body.innerHTML = html; log.scrollTop = log.scrollHeight; return Promise.resolve();
}
function setStatus(txt, busy = false) { $("#statusText").textContent = txt; $("#statusPill").classList.toggle("busy", busy); }
function setStep(id, st) { stepState[id] = st; renderRail(); }

/* ============================================================
   流程
   ============================================================ */
async function runImport() {
  setStep("import", "run"); setStatus("正在导入存储卡…", true); focusStep("import");
  sendBridge({ type: "import", source: $("#source-path") ? $("#source-path").textContent : "card" });
  agentSay("act", "读取存储卡 … 发现 <b>" + PHOTOS.length + " 张 RAW</b>，建立目录并生成 1:1 预览。", 500);
  await sleep(700);
  agentSay("see", "导入完成，原始 RAW 未改动。", 0);
  setStep("import", "done"); setStatus("已导入 · 待 EXIF 分析", false); focusStep("exif"); setStep("exif", "wait");
}
async function runExif() {
  setStep("exif", "run"); setStatus("EXIF 分析中…", true); focusStep("exif");
  agentSay("think", "从元数据提取相机 / 镜头 / 曝光三角 / 白平衡，识别场景类型。", 600);
  await sleep(500);
  agentSay("act", "解析到混合色温、多焦段，含人像 / 风光 / 街拍 / 夜景 / 产品等场景。", 0);
  setStep("exif", "done"); setStatus("待选片", false);
}
async function runCull() {
  if (stepState.exif !== "done") { toast("请先完成 EXIF 分析"); return; }
  setStep("cull", "run"); setStatus("自动选片中…", true); focusStep("cull");
  agentSay("think", "用对焦清晰度 + 曝光 + 构图评分模型给每张打星，对连拍重复降权。", 700);
  await sleep(400); doCull(); renderFilmstrip(); renderPickList();
  agentSay("act", `选片完成：<b>${cullCounts().pick} 张入选，${cullCounts().reject} 张标记 reject</b>（虚焦 / 连拍重复）。`, 0);
  setStep("cull", "done"); setStatus("选片完成 · 待你审片", false);
}
async function runSimilar() {
  if (stepState.cull !== "done") { toast("请先完成选片"); return; }
  setStep("similar", "run"); setStatus("相似筛选中…", true); focusStep("similar");
  agentSay("think", "对入选照片做感知哈希 + 特征比对，找连拍 / 近似构图。", 700);
  await sleep(400);
  const dupGroups = new Set(PHOTOS.filter((p) => p.isDup).map((p) => p.dupOf)).size;
  agentSay("act", `发现 <b>${dupGroups} 组相似</b> 连拍，每组建议保留对焦更实的一张。`, 0);
  setStep("similar", "done"); setStatus("相似筛选完成 · 待你确认", false);
}
function runGrade() { if (stepState.similar !== "done") { toast("请先完成相似筛选"); return; } focusStep("grade"); }
async function runSync() {
  setStep("sync", "run"); setStatus("批量同步中…", true); focusStep("work");
  const targets = PHOTOS.filter((p) => !p.isDup && p.flag !== "reject");
  sendBridge({ type: "sync", from: hero.name, count: targets.length });
  agentSay("act", `将「${hero.name}」的设定（调色 + 蒙版）同步到 <b>${targets.length} 张入选照片</b>。`, 0);
  await sleep(500);
  for (let i = 1; i <= targets.length; i++) { await sleep(240); agentSay("act", `同步 → <b>${targets[i - 1].name}</b>`); }
  stepState.sync = "done"; setStatus("同步完成 · 待导出", false);
  agentSay("see", `已对 ${targets.length} 张套用相同基调，保留各自曝光与构图差异。可进入导出。`);
  stepState.export = "wait"; renderRail();
}

/* ============================================================
   事件
   ============================================================ */
function bindEvents() {
  const nl = $("#nlInput"), gb = $("#gradeBtn");
  if (nl) nl.addEventListener("keydown", (e) => { if (e.key === "Enter" && !e.shiftKey) { e.preventDefault(); gb.click(); } });
  if (gb) gb.addEventListener("click", async () => {
    const txt = nl.value.trim();
    if (!txt) { toast("请先描述调色思路"); return; }
    if (stepState.similar !== "done") { toast("请先完成相似筛选"); return; }
    focusStep("grade"); setStep("grade", "run"); setStatus("解析调色意图…", true);
    agentSay("user", `<b>${escapeHtml(txt)}</b>`);
    await sleep(200);
    agentSay("think", "将自然语言拆解为 Lightroom 可调参数：曝光 / 白平衡 / 对比 / 饱和 / 局部蒙版。", 700);
    const { params: pp, notes } = interpretPrompt(txt);
    params = pp; lastInterpret = notes;
    await sleep(300);
    agentSay("act", "应用参数：" + notes.map((n) => `<b>${n}</b>`).join("；") + "。", 0);
    await sleep(300);
    agentSay("see", "已生成前后对比，拖动滑块核对——审美是否到位由你判断。", 0);
    setStep("grade", "done"); setStatus("调色已应用 · 待你确认", false);
    renderStage();
  });
  const ra = $("#runAll");
  if (ra) ra.addEventListener("click", async () => {
    setStatus("全流程运行中…", true);
    await runImport(); await sleep(300); await runExif(); await sleep(300); await runCull(); await sleep(300); await runSimilar(); await sleep(300);
    agentSay("see", "全流程分析完毕。请在右侧输入调色思路，进入「自然语言调色」。", 0);
    setStatus("分析完成 · 等待你下达调色指令", false); focusStep("grade");
  });
}
let toastTimer;
function toast(msg) { const el = $("#toast"); if (!el) return; el.textContent = msg; el.classList.add("show"); clearTimeout(toastTimer); toastTimer = setTimeout(() => el.classList.remove("show"), 2200); }
function escapeHtml(v) { return v.replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#039;" }[c])); }

/* ============================================================
   启动
   ============================================================ */
function init() {
  renderRail();
  renderStage();
  renderFilmstrip();
  bindEvents();
  $("#page-title").textContent = "导入拍摄素材";
  agentSay("think", "已就绪。我是你的后期 Agent：<b>导入、分析、选片、调色、蒙版、同步、导出</b>都由我执行，审片与最终确认由你负责。点「选择文件夹」或「运行全流程」开始。", 0);
  pollBridge();
  window.setInterval(pollBridge, 3000);
}
if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", init); else init();
