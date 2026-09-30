// Run a built plan board's shipped inline script under a minimal DOM shim and
// print what it rendered, so tests assert on the page's behavior rather than
// on the template's source.
//
// Usage: node plan-board-harness.mjs <board.html> [<saved.json>]
// <saved.json> seeds the fake saved store: {"answers":{id:{...}},"reopen":{...},
// "notes":{"general":{...}}}. Without it the page runs with no store, as in a
// view where saving is off.
// Prints one JSON document:
//   { title, eyebrow, counts, next, views:{<plan>:{<mode>:{text, svg, unbalanced}}},
//     staticUnbalanced, copy, bar, opening:{hidden, plainHidden, mission, ruled,
//     glossary, pictures, calls, quizOrder}, concepts, quizAfter, copyAfter,
//     writes:[{path, data}], error }
// With a saved store it also presses option B on the first open call, then
// answers the first quiz question wrong and tries to answer it again.
import { readFileSync } from "node:fs";
import vm from "node:vm";

const html = readFileSync(process.argv[2], "utf8");
const saved = process.argv[3] ? JSON.parse(readFileSync(process.argv[3], "utf8")) : null;
const out = { writes: [] };

const VOID = new Set(["input", "br", "img", "meta", "link", "hr"]);
function unbalanced(fragment) {
  const stack = [], bad = [];
  for (const m of fragment.matchAll(/<(\/?)([a-zA-Z][\w-]*)((?:"[^"]*"|'[^']*'|[^'">])*)>/g)) {
    const [, close, tag, rest] = m;
    const t = tag.toLowerCase();
    if (!close && (rest.trim().endsWith("/") || VOID.has(t))) continue;
    if (!close) stack.push(t);
    else if (stack[stack.length - 1] === t) stack.pop();
    else bad.push(`</${t}> after <${stack[stack.length - 1] || "nothing"}>`);
  }
  return bad.concat(stack.map((t) => `<${t}> never closed`));
}
const strip = (s) => s.replace(/<[^>]*>/g, " ").replace(/\s+/g, " ").trim();

const selectDefaults = Object.fromEntries(
  [...html.matchAll(/<select id="([\w-]+)"><option value="([^"]*)"/g)].map((m) => [m[1], m[2]]),
);
class Node {
  constructor(id) {
    this.id = id; this.innerHTML = ""; this.textContent = ""; this.hidden = false;
    this.value = selectDefaults[id] ?? ""; this.checked = false; this.dataset = {};
    this.listeners = {}; this.attributes = {};
  }
  setAttribute(k, v) { this.attributes[k] = v; }
  addEventListener(type, fn) { (this.listeners[type] ??= []).push(fn); }
  select() {}
  scrollIntoView() {}
}
const nodes = new Map();
const node = (id) => { if (!nodes.has(id)) nodes.set(id, new Node(id)); return nodes.get(id); };
const docListeners = {};
globalThis.document = {
  getElementById: (id) => (id === "plan-board-data" ? { textContent: dataText } : node(id)),
  querySelector: (sel) => (sel.startsWith("#") ? node(sel.slice(1)) : new Node(sel)),
  querySelectorAll: () => [],
  addEventListener: (type, fn) => { (docListeners[type] ??= []).push(fn); },
  activeElement: null,
  documentElement: { outerHTML: html },
};
globalThis.window = globalThis;
globalThis.CSS = { escape: (s) => s };
globalThis.MouseEvent = class { constructor(type) { this.type = type; } };
globalThis.localStorage = { getItem: () => null, setItem: () => {} };
Object.defineProperty(globalThis, "navigator", { value: { clipboard: { writeText: async () => {} } }, configurable: true });
globalThis.scrollTo = () => {};

if (saved) {
  const snap = (coll) => ({
    docs: Object.entries(saved[coll] || {}).map(([id, v]) => ({ id, exists: true, data: () => v })),
  });
  const db = {
    collection: (name) => ({ onSnapshot: (cb) => { cb(snap(name)); return () => {}; } }),
    doc: (path) => ({
      get: async () => {
        const [coll, id] = path.split("/");
        const v = (saved[coll] || {})[id];
        return { exists: !!v, data: () => v };
      },
      set: async (data) => { out.writes.push({ path, data }); },
    }),
  };
  const user = { can: async () => true };
  globalThis.claude = { use: async (name) => (name === "db" ? db : name === "user" ? user : null) };
}

const dataText = html.split('<script id="plan-board-data" type="application/json">')[1].split("</script>")[0];
const script = html.split("<script>")[1].split("</script>")[0];
const click = (name, data) => docListeners.click.forEach((fn) =>
  fn({ target: { closest: (sel) => (sel === `[data-${name}]` ? { dataset: data } : null) } }));

try {
  vm.runInThisContext(script);
  await new Promise((r) => setTimeout(r, 30));
  const P = JSON.parse(dataText);
  const plans = P.items.filter((i) => i.kind === "plan").map((i) => i.id);
  out.title = node("title").textContent;
  out.eyebrow = node("eyebrow").textContent;
  out.counts = strip(node("counts").innerHTML);
  out.next = strip(node("next3").innerHTML);
  out.staticUnbalanced = unbalanced(html.replace(/<!--[\s\S]*?-->/g, "").replace(/<script[\s\S]*?<\/script>/g, "").replace(/<style[\s\S]*?<\/style>/g, ""));
  out.views = {};
  for (const plan of plans) {
    click("open", { open: plan });
    out.views[plan] = {};
    for (const mode of ["cards", "time", "deps", "map"]) {
      click("mode", { mode });
      const h = node("stage").innerHTML;
      out.views[plan][mode] = { text: strip(h), svg: /<svg /.test(h), unbalanced: unbalanced(h) };
    }
  }
  out.copy = node("copybox").value;
  out.bar = node("ansmsg").textContent;
  out.opening = {
    hidden: node("opening").hidden,
    plainHidden: node("plain").hidden,
    mission: strip(node("mission").innerHTML),
    ruled: strip(node("ruled").innerHTML),
    glossary: node("gloss").innerHTML,
    pictures: strip(node("refpics").innerHTML),
    calls: [...node("opencalls").innerHTML.matchAll(/<span class="id">([^<]*)<\/span>/g)].map((m) => m[1]),
    quizOrder: [...node("quiz").innerHTML.matchAll(/data-quiz="([^"]*)" data-k="(\d)"/g)].map((m) => `${m[1]}:${m[2]}`),
  };
  out.concepts = strip(node("conceptlist").innerHTML);
  const open = P.items.find((i) => i.kind === "call" && (i.status || "open") === "open");
  if (open && saved) {
    click("pick", { pick: open.id, key: "B" });
    await new Promise((r) => setTimeout(r, 10));
  }
  const q = (P.opening || {}).quiz || [];
  if (q.length && saved) {
    click("quiz", { quiz: q[0].id, k: String((q[0].answer + 1) % 3) });
    click("quiz", { quiz: q[0].id, k: String(q[0].answer) });
    await new Promise((r) => setTimeout(r, 10));
    out.quizAfter = strip(node("quiz").innerHTML);
    out.copyAfter = node("copybox").value;
  }
} catch (e) {
  out.error = String(e && e.stack || e);
}
process.stdout.write(JSON.stringify(out) + "\n");
