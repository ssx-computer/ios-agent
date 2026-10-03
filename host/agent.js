#!/usr/bin/env node
/*
 * iOSAgent 外部大脑 — 跑在 PC/Mac/服务器上，连外部 LLM 模型
 * 通过两条通道操作越狱 iPhone（RootHide / Dopamine 均适用）：
 *   ① SSH（ssh2）：执行 shell 命令 = 直接操作越狱终端
 *   ② ssh -L 端口转发 -> Tweak 的 127.0.0.1 loopback TCP：tap/swipe/type/截图/视图树
 * 用法：
 *   npm install
 *   node agent.js "打开设置，把蓝牙关掉"
 *   node agent.js --repl
 */
"use strict";
const fs = require("fs");
const os = require("os");
const path = require("path");
const net = require("net");
const { spawn } = require("child_process");
const { Client: SSHClient } = require("ssh2");

const cfg = JSON.parse(fs.readFileSync(path.join(__dirname, "config.json"), "utf8"));
const dev = cfg.device;
const NOTIF_FILE = "/private/tmp/iosagent_notif.jsonl";

/* ---------------- SSH 终端（越狱设备上的 shell） ---------------- */
let sshQueue = Promise.resolve();
function shell(cmd, timeoutMs = 30000) {
  // 串行化，避免并发 exec 互相干扰
  const job = sshQueue.then(() => new Promise((resolve, reject) => {
    const c = new SSHClient();
    const keyPath = dev.key ? path.join(os.homedir(), dev.key.replace(/^~\//, "")) : null;
    const conn = {
      host: dev.host,
      port: dev.sshPort,
      username: dev.user,
      readyTimeout: 10000,
      ...(keyPath ? { privateKey: fs.readFileSync(keyPath) } : {}),
      ...(dev.password ? { password: dev.password } : {}),
    };
    const to = setTimeout(() => { try { c.end(); } catch {} reject(new Error("ssh timeout: " + cmd)); }, timeoutMs);
    c.on("ready", () => {
      c.exec(cmd, (err, stream) => {
        if (err) { clearTimeout(to); reject(err); return; }
        let out = "";
        const cap = 200000;
        stream.on("data", (d) => { if (out.length < cap) out += d; });
        stream.stderr.on("data", (d) => { if (out.length < cap) out += "\n[stderr] " + d; });
        stream.on("close", (code) => { clearTimeout(to); c.end(); resolve({ code, output: out.slice(0, cap) }); });
      });
    });
    c.on("error", (e) => { clearTimeout(to); reject(new Error("ssh: " + e.message)); });
    c.connect(conn);
  }));
  sshQueue = job.catch(() => {});
  return job;
}

/* ---------------- 端口映射探测（Tweak 写的注册文件） ---------------- */
let _map = null, _mapAt = 0;
async function portMap(force = false) {
  if (_map && !force && Date.now() - _mapAt < 5000) return _map;
  const r = await shell(
    "for f in /private/tmp/iosagent_port_*; do [ -f \"$f\" ] && printf '%s ' \"$f\" && cat \"$f\"; done 2>/dev/null"
  );
  const map = {};
  for (const line of r.output.trim().split("\n")) {
    const m = line.trim().match(/iosagent_port_(.+?)\s+(\d+)\s*$/);
    if (m) map[m[1]] = parseInt(m[2], 10); // key: bundleid 的点已换成 _
  }
  _map = map; _mapAt = Date.now();
  return map;
}

/* ---------------- 按需 ssh 端口转发 ---------------- */
const forwards = new Map();
function ensureForward(port) {
  if (forwards.has(port)) return;
  const args = ["-N", "-f", "-n",
    "-o", "BatchMode=yes", "-o", "ConnectTimeout=5",
    "-o", "StrictHostKeyChecking=accept-new",
    "-p", String(dev.sshPort),
    `-L ${port}:127.0.0.1:${port}`,
    `-i`, path.join(os.homedir(), (dev.key || "").replace(/^~\//, "")),
    `${dev.user}@${dev.host}`];
  const p = spawn("ssh", args, { stdio: "ignore", detached: true });
  p.on("error", () => forwards.delete(port));
  p.on("exit", () => forwards.delete(port));
  p.unref();
  forwards.set(port, p);
}

/* ---------------- Tweak TCP 命令通道 ---------------- */
function rpcPort(port, cmd, timeoutMs = 10000) {
  return new Promise((resolve, reject) => {
    const s = net.connect({ port, host: "127.0.0.1" });
    let buf = "";
    const to = setTimeout(() => { try { s.destroy(); } catch {} reject(new Error("rpc timeout: " + JSON.stringify(cmd))); }, timeoutMs);
    s.on("connect", () => s.write(JSON.stringify(cmd) + "\n"));
    s.on("data", (d) => {
      buf += d.toString("utf8");
      const i = buf.indexOf("\n");
      if (i >= 0) { clearTimeout(to); s.end(); try { resolve(JSON.parse(buf.slice(0, i))); } catch (e) { reject(e); } }
    });
    s.on("error", (e) => { clearTimeout(to); reject(e); });
  });
}

let _t = null, _tAt = 0;
async function target(force = false) {
  if (_t && !force && Date.now() - _tAt < 2000) {
    try { await rpcPort(_t.port, { c: "ping" }, 1500); return _t; } catch { _t = null; }
  }
  const map = await portMap();
  let fallback = null;
  for (const [bid, port] of Object.entries(map)) {
    try {
      ensureForward(port);
      const r = await rpcPort(port, { c: "ping" }, 1500);
      if (r.ok && r.active) { _t = { bid, port, r }; _tAt = Date.now(); return _t; }
      if (r.ok && !fallback) fallback = { bid, port, r };
    } catch {}
  }
  if (fallback) { _t = fallback; _tAt = Date.now(); return _t; }
  throw new Error("未找到 Tweak 端口 — 确认 Tweak 已安装、设备有前台 App（可先 shell 命令 ls /private/tmp/iosagent_port_* 排查）");
}

async function sbTarget() {
  const map = await portMap();
  for (const [bid, port] of Object.entries(map)) {
    try {
      ensureForward(port);
      const r = await rpcPort(port, { c: "ping" }, 1500);
      if (r.ok && r.sb) return { bid, port, r };
    } catch {}
  }
  throw new Error("未找到 SpringBoard 的 Tweak 端口（重启设备试试）");
}

/* ---------------- 工具执行 ---------------- */
async function shot() {
  const t = await target();
  const r = await rpcPort(t.port, { c: "shot", p: { jpeg: 1 } }, 15000);
  if (!r.ok) throw new Error("截图失败: " + JSON.stringify(r));
  // 截图是设备上的文件：经 ssh 拉回来
  const tmp = path.join(os.tmpdir(), "iosagent_shot_" + Date.now() + ".jpg");
  const { Client: SCP } = require("ssh2");
  await new Promise((resolve, reject) => {
    const keyPath = dev.key ? path.join(os.homedir(), dev.key.replace(/^~\//, "")) : null;
    const c = new SCP();
    c.on("ready", () => c.scpCreateReadStream(`${r.path}`, {}, (err, rs) => {
      if (err) return reject(err);
      const ws = fs.createWriteStream(tmp);
      rs.pipe(ws);
      rs.on("error", reject);
      ws.on("finish", () => { c.end(); resolve(); });
    }));
    c.on("error", reject);
    c.connect({ host: dev.host, port: dev.sshPort, username: dev.user,
      ...(keyPath ? { privateKey: fs.readFileSync(keyPath) } : {}),
      ...(dev.password ? { password: dev.password } : {}) });
  });
  const b64 = fs.readFileSync(tmp).toString("base64");
  try { fs.unlinkSync(tmp); } catch {}
  return { dataUrl: "data:image/jpeg;base64," + b64, meta: r };
}

async function runTool(name, args) {
  const t = await target();
  switch (name) {
    case "tap": {
      const r = await rpcPort(t.port, { c: "tap", p: args }, 10000);
      if (!r.ok) throw new Error(JSON.stringify(r));
      return { ...r, clicked: [args.x, args.y] };
    }
    case "swipe": {
      const r = await rpcPort(t.port, { c: "swipe", p: args }, 10000);
      if (!r.ok) throw new Error(JSON.stringify(r));
      return r;
    }
    case "type": {
      const r = await rpcPort(t.port, { c: "type", p: args }, 10000);
      if (!r.ok) throw new Error(JSON.stringify(r));
      return r;
    }
    case "ui_tree": {
      const r = await rpcPort(t.port, { c: "ui" }, 15000);
      if (!r.ok) throw new Error(JSON.stringify(r));
      return { nodes: (r.nodes || []).slice(0, 400) };
    }
    case "open_app": {
      const sb = await sbTarget();
      const r = await rpcPort(sb.port, { c: "open", p: { bundleId: args.bundleId } }, 15000);
      if (!r.ok) throw new Error(JSON.stringify(r));
      return r;
    }
    case "shell": {
      const r = await shell(args.command, args.timeoutMs || 30000);
      return { ok: r.code === 0, code: r.code, output: r.output.slice(0, 8000) };
    }
    case "terminal_send": {
      // 在屏幕终端 App 里发一条命令：必要时先打开终端 App
      const bid = dev.terminalBundleId;
      if (t.bid !== bid.replace(/\./g, "_") && bid) {
        const sb = await sbTarget();
        await rpcPort(sb.port, { c: "open", p: { bundleId: bid } }, 15000);
        await new Promise((res) => setTimeout(res, 1800));
      }
      const r = await rpcPort(t.port, { c: "type", p: { text: args.line + "\n" } }, 10000);
      return { ...r, sent: args.line };
    }
    case "recent_notifs": {
      const r = await shell(`tail -n 20 ${NOTIF_FILE} 2>/dev/null`);
      return { notifications: r.output.trim().split("\n").filter(Boolean) };
    }
    case "finish":
      return { done: true, answer: args.answer };
    default:
      throw new Error("unknown tool " + name);
  }
}

const TOOL_DEFS = [
  { type: "function", function: {
    name: "tap",
    description: "在 iPhone 屏幕指定点单击。坐标单位是 points（非像素），左上角为原点，范围见最近屏幕的 w/h。",
    parameters: { type: "object", properties: { x: { type: "number" }, y: { type: "number" } }, required: ["x", "y"] } } },
  { type: "function", function: {
    name: "swipe",
    description: "从 (x1,y1) 滑到 (x2,y2)，用于滚动/翻页/上滑回桌面。",
    parameters: { type: "object",
      properties: { x1: { type: "number" }, y1: { type: "number" }, x2: { type: "number" }, y2: { type: "number" },
                     ms: { type: "number", description: "毫秒，默认 300" } },
      required: ["x1", "y1", "x2", "y2"] } } },
  { type: "function", function: {
    name: "type",
    description: "向当前聚焦的输入框键入文字（需先点击聚焦）。",
    parameters: { type: "object", properties: { text: { type: "string" } }, required: ["text"] } } },
  { type: "function", function: {
    name: "ui_tree",
    description: "获取当前窗口视图树 JSON：[类名,[x,y,w,h],文字?,accessibilityId?,enabled?]，用于精确定位控件。",
    parameters: { type: "object", properties: {} } } },
  { type: "function", function: {
    name: "open_app",
    description: "按 bundleId 打开 App。例：com.apple.Preferences 设置；com.apple.mobilesafari Safari。",
    parameters: { type: "object", properties: { bundleId: { type: "string" } }, required: ["bundleId"] } } },
  { type: "function", function: {
    name: "shell",
    description: "在越狱设备终端执行 shell 命令（rootless 为 mobile 用户，rootful 可 sudo 提权）。适合查文件、装包、看日志、起服务。",
    parameters: { type: "object", properties: {
        command: { type: "string", description: "要执行的命令" },
        timeoutMs: { type: "number", description: "超时毫秒，默认 30000" } },
      required: ["command"] } } },
  { type: "function", function: {
    name: "terminal_send",
    description: "在 iPhone 屏幕上的终端 App 里输入并回车一条命令（先自动打开终端 App）。用于交互/需要回显的场景。",
    parameters: { type: "object", properties: { line: { type: "string" } }, required: ["line"] } } },
  { type: "function", function: {
    name: "recent_notifs",
    description: "读取手机上最近出现过的通知列表。",
    parameters: { type: "object", properties: {} } } },
  { type: "function", function: {
    name: "finish",
    description: "任务完成（或确定无法完成）时调用，给出最终结论。",
    parameters: { type: "object", properties: { answer: { type: "string" } }, required: ["answer"] } } },
];

const SYSTEM = [
  "你通过工具直接操作一台越狱 iPhone（RootHide 或 Dopamine）。两条通道：",
  "A. 屏幕通道：tap/swipe/type/ui_tree/open_app —— 操作图形界面；每次动作后会自动附最新屏幕。",
  "B. 终端通道：shell（直接执行命令）/ terminal_send（在屏幕终端 App 里发命令）—— 操作越狱系统本身。",
  "优先用 shell 完成文件系统/服务/包管理任务（快且稳）；需要 UI 交互时才用屏幕通道。",
  "屏幕坐标单位是 points 不是 pixels。",
  "连续 3 次同类动作无效就换策略，仍失败则调用 finish 说明原因。",
  "破坏性命令（rm -rf、卸载系统组件、重启）先向用户确认；任务完成时调用 finish。",
].join("\n");

async function chat(messages) {
  const url = cfg.apiBase.replace(/\/+$/, "") + "/chat/completions";
  const r = await fetch(url, {
    method: "POST",
    headers: { "Content-Type": "application/json", Authorization: "Bearer " + cfg.apiKey },
    body: JSON.stringify({ model: cfg.model, messages, tools: TOOL_DEFS, tool_choice: "auto", temperature: 0.2 }),
  });
  if (!r.ok) throw new Error("LLM " + r.status + " " + (await r.text()).slice(0, 400));
  return (await r.json()).choices[0].message;
}

async function run(goal) {
  const messages = [{ role: "system", content: SYSTEM }];
  const s0 = await shot();
  const m0 = s0.meta;
  const sb = await portMap();
  messages.push({
    role: "user",
    content: [
      { type: "text", text: `任务：${goal}\n(屏幕: w=${m0.w} h=${m0.h} points; 已注入 Tweak 的进程: ${JSON.stringify(sb)})` },
      { type: "image_url", image_url: { url: s0.dataUrl } },
    ],
  });
  const maxSteps = cfg.maxSteps || 40;
  for (let step = 1; step <= maxSteps; step++) {
    process.stderr.write(`\n[step ${step}] 请求模型...\n`);
    const m = await chat(messages);
    const calls = m.tool_calls || [];
    if (m.content && !calls.length) {
      console.log("\n=== 结论 ===\n" + m.content);
      return m.content;
    }
    messages.push({ role: "assistant", content: m.content || "", tool_calls: calls });
    const results = [];
    let finalAnswer = null;
    for (const tc of calls) {
      const name = tc.function.name;
      let args = {};
      try { args = JSON.parse(tc.function.arguments || "{}"); } catch {}
      process.stderr.write(`[tool] ${name} ${JSON.stringify(args).slice(0, 200)}\n`);
      let out;
      try { out = await runTool(name, args); }
      catch (e) { out = { ok: false, error: String(e.message || e) }; }
      if (name === "finish" && out.done) finalAnswer = out.answer;
      results.push({ role: "tool", tool_call_id: tc.id, content: JSON.stringify(out).slice(0, 12000) });
    }
    messages.push(...results);
    if (finalAnswer !== null) {
      console.log("\n=== 结论 ===\n" + finalAnswer);
      return finalAnswer;
    }
    try {
      const s = await shot();
      messages.push({
        role: "user",
        content: [
          { type: "text", text: `这是执行动作后的当前屏幕 (w=${s.meta.w} h=${s.meta.h} points)。` },
          { type: "image_url", image_url: { url: s.dataUrl } },
        ],
      });
    } catch (e) {
      messages.push({ role: "user", content: [{ type: "text", text: "注意：截图失败：" + e.message }] });
    }
  }
  console.log("\n=== 达到最大步数，停止 ===");
  return "(maxSteps reached)";
}

(async () => {
  const args = process.argv.slice(2);
  if (args[0] === "--repl") {
    const { createInterface } = require("readline");
    const rl = createInterface({ input: process.stdin, output: process.stdout, prompt: "goal> " });
    rl.prompt();
    rl.on("line", async (line) => {
      line = line.trim();
      if (line) await run(line).catch((e) => console.error(e));
      rl.prompt();
    });
  } else if (args.length >= 1) {
    await run(args.join(" "));
  } else {
    console.log('用法: node agent.js "目标"   |   node agent.js --repl');
  }
})().catch((e) => { console.error(e); process.exit(1); });
