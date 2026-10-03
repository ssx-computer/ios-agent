#!/usr/bin/env node
/*
 * iOSAgent 大脑 — 在越狱 iOS 设备上本地运行的 Agent 循环
 * 依赖：Node >= 18（内置 fetch），无第三方依赖。
 * 用法：
 *   node agent.js "打开设置，把蓝牙关掉"
 *   node agent.js --repl      （交互式，一行一个目标）
 */
"use strict";
const fs = require("fs");
const path = require("path");
const net = require("net");

const SOCK_DIR = "/private/tmp";
const NOTIF_FILE = "/private/tmp/iosagent_notif.jsonl";
const cfg = JSON.parse(fs.readFileSync(path.join(__dirname, "config.json"), "utf8"));

/* ---------------- unix socket 客户端 ---------------- */
function rpc(file, cmd, timeoutMs = 8000) {
  return new Promise((resolve, reject) => {
    const s = net.connect(file);
    let buf = "";
    const to = setTimeout(() => {
      try { s.destroy(); } catch {}
      reject(new Error("rpc timeout: " + JSON.stringify(cmd)));
    }, timeoutMs);
    s.on("connect", () => s.write(JSON.stringify(cmd) + "\n"));
    s.on("data", (d) => {
      buf += d.toString("utf8");
      const i = buf.indexOf("\n");
      if (i >= 0) {
        clearTimeout(to);
        s.end();
        try { resolve(JSON.parse(buf.slice(0, i))); } catch (e) { reject(e); }
      }
    });
    s.on("error", (e) => { clearTimeout(to); reject(e); });
  });
}

function listSockets() {
  try {
    return fs.readdirSync(SOCK_DIR)
      .filter((f) => f.startsWith("iosagent_") && f.endsWith(".sock"))
      .map((f) => path.join(SOCK_DIR, f));
  } catch { return []; }
}

let _t = null;
async function target(force = false) {
  if (_t && !force) {
    try { await rpc(_t.file, { c: "ping" }, 1500); return _t; } catch { _t = null; }
  }
  const files = listSockets();
  let fallback = null;
  for (const f of files) {
    try {
      const r = await rpc(f, { c: "ping" }, 1500);
      if (r.ok && r.active) { _t = { file: f, r }; return _t; }
      if (r.ok && !fallback) fallback = { file: f, r };
    } catch {}
  }
  if (fallback) { _t = fallback; return _t; }
  throw new Error("未找到 iosagent Tweak socket — 确认 Tweak 已安装、设备已越狱、有前台 App");
}

async function sbTarget() {
  for (const f of listSockets()) {
    try {
      const r = await rpc(f, { c: "ping" }, 1500);
      if (r.ok && r.sb) return { file: f, r };
    } catch {}
  }
  throw new Error("未找到 SpringBoard 进程 socket（Tweak 是否被注入到 SB？重启设备试试）");
}

/* ---------------- 工具执行 ---------------- */
async function shot() {
  const t = await target();
  const r = await rpc(t.file, { c: "shot", p: { jpeg: 1 } }, 15000);
  if (!r.ok) throw new Error("截图失败: " + JSON.stringify(r));
  const b64 = fs.readFileSync(r.path).toString("base64");
  try { fs.unlinkSync(r.path); } catch {}
  return { dataUrl: "data:image/jpeg;base64," + b64, meta: r };
}

async function runTool(name, args) {
  const t = await target();
  switch (name) {
    case "tap": {
      const r = await rpc(t.file, { c: "tap", p: args }, 10000);
      if (!r.ok) throw new Error(JSON.stringify(r));
      return { ...r, clicked: [args.x, args.y] };
    }
    case "swipe": {
      const r = await rpc(t.file, { c: "swipe", p: args }, 10000);
      if (!r.ok) throw new Error(JSON.stringify(r));
      return r;
    }
    case "type": {
      const r = await rpc(t.file, { c: "type", p: args }, 10000);
      if (!r.ok) throw new Error(JSON.stringify(r));
      return r;
    }
    case "ui_tree": {
      const r = await rpc(t.file, { c: "ui" }, 15000);
      if (!r.ok) throw new Error(JSON.stringify(r));
      return { nodes: (r.nodes || []).slice(0, 400) };
    }
    case "open_app": {
      const sb = await sbTarget();
      const r = await rpc(sb.file, { c: "open", p: { bundleId: args.bundleId } }, 15000);
      if (!r.ok) throw new Error(JSON.stringify(r));
      return r;
    }
    case "recent_notifs": {
      let txt = "";
      try { txt = fs.readFileSync(NOTIF_FILE, "utf8"); } catch {}
      return { notifications: txt.trim().split("\n").filter(Boolean).slice(-20) };
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
    description: "在指定点单击。坐标单位是 points（非像素），左上角为原点，范围见最近一张屏幕的 w/h。",
    parameters: { type: "object", properties: { x: { type: "number" }, y: { type: "number" } }, required: ["x", "y"] } } },
  { type: "function", function: {
    name: "swipe",
    description: "从 (x1,y1) 滑到 (x2,y2)，用于滚动/翻页/上滑回桌面。",
    parameters: { type: "object",
      properties: { x1: { type: "number" }, y1: { type: "number" }, x2: { type: "number" }, y2: { type: "number" },
                     ms: { type: "number", description: "滑动时长毫秒，默认 300" } },
      required: ["x1", "y1", "x2", "y2"] } } },
  { type: "function", function: {
    name: "type",
    description: "向当前聚焦的输入框键入文字（需先点击聚焦）。",
    parameters: { type: "object", properties: { text: { type: "string" } }, required: ["text"] } } },
  { type: "function", function: {
    name: "ui_tree",
    description: "获取当前窗口视图树 JSON：[类名,[x,y,w,h],文字?,accessibilityId?,enabled?]，用于精确定位控件坐标。",
    parameters: { type: "object", properties: {} } } },
  { type: "function", function: {
    name: "open_app",
    description: "按 bundleId 打开 App（例：com.apple.Preferences 设置；com.apple.mobilesafari Safari）。",
    parameters: { type: "object", properties: { bundleId: { type: "string" } }, required: ["bundleId"] } } },
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
  "你通过工具直接操作一台越狱 iPhone（设备端有桥接 Tweak）。",
  "每次动作后系统会自动附上最新屏幕，请以图片为准；坐标单位是 points 不是 pixels。",
  "工作方式：先看屏幕/调用 ui_tree 确认目标控件位置 → 执行动作 → 在新屏幕上验证结果。",
  "连续 3 次同类动作无效就换策略（改用 ui_tree 精确定位），仍失败则调用 finish 说明原因。",
  "open_app 通常需要在桌面才能生效；在 App 内时先向上滑回桌面。",
  "简洁输出；任务完成或确认做不到时调用 finish。",
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
  messages.push({
    role: "user",
    content: [
      { type: "text", text: `任务：${goal}\n(屏幕信息: w=${m0.w} h=${m0.h} points, scale=${m0.scale})` },
      { type: "image_url", image_url: { url: s0.dataUrl } },
    ],
  });
  const maxSteps = cfg.maxSteps || 30;
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
      process.stderr.write(`[tool] ${name} ${JSON.stringify(args)}\n`);
      let out;
      try { out = await runTool(name, args); }
      catch (e) { out = { ok: false, error: String(e.message || e) }; }
      if (name === "finish" && out.done) finalAnswer = out.answer;
      results.push({ role: "tool", tool_call_id: tc.id, content: JSON.stringify(out) });
    }
    messages.push(...results);
    if (finalAnswer !== null) {
      console.log("\n=== 结论 ===\n" + finalAnswer);
      return finalAnswer;
    }
    try {
      const s = await shot();
      const meta = s.meta;
      messages.push({
        role: "user",
        content: [
          { type: "text", text: `这是执行动作后的当前屏幕 (w=${meta.w} h=${meta.h} points)。` },
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
