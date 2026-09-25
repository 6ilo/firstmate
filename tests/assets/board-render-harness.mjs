// Render a built bearings board's shipped inline script under a minimal DOM
// shim and print what the renderer actually produced, so board behavior is
// asserted through the real template rather than by reading its source.
//
// Usage: node board-render-harness.mjs <built-board.html>
// Prints one JSON document:
//   { stats:[{n,label}], underway:[{title,sub,badges}],
//     charted:[{title,sub,badges,pickable}], empty, more, error,
//     today:{hidden, sub, head, hours, lanes:{captain,ai}:[{title,sub,kinds,past,
//            top,height,left,width,tooltip}], now:{top}|null, asks, plans} }
import { readFileSync } from "node:fs";

const html = readFileSync(process.argv[2], "utf8");

class Node {
  constructor(tag) {
    this.tagName = tag;
    this.className = "";
    this.children = [];
    this.attributes = {};
    this._text = "";
    this.hidden = false;
    this.disabled = false;
    this.innerHTML = "";
    this.parentNode = null;
    this.type = "";
    this.value = "";
    this.checked = false;
    this.style = {};
    const classes = () => this.className.split(/\s+/).filter(Boolean);
    this.classList = {
      add: (c) => { this.className = (this.className + " " + c).trim(); },
      remove: (c) => { this.className = classes().filter((x) => x !== c).join(" "); },
      toggle: (c, on) => {
        const want = on === undefined ? !classes().includes(c) : on;
        if (want) { if (!classes().includes(c)) this.classList.add(c); } else this.classList.remove(c);
      },
      contains: (c) => classes().includes(c),
    };
  }
  get textContent() {
    return this.children.length
      ? this.children.map((c) => c.textContent).join("")
      : this._text;
  }
  set textContent(v) { this._text = String(v); this.children = []; }
  appendChild(n) { n.parentNode = this; this.children.push(n); return n; }
  setAttribute(k, v) { this.attributes[k] = v; }
  addEventListener() {}
  querySelectorAll(sel) {
    const want = sel.replace(/^\./, "").replace(/:checked$/, "");
    const checkedOnly = sel.endsWith(":checked");
    const out = [];
    const walk = (n) => {
      for (const c of n.children) {
        if (c.className.split(/\s+/).includes(want) && (!checkedOnly || c.checked)) out.push(c);
        walk(c);
      }
    };
    walk(this);
    return out;
  }
}

const byId = new Map();
const dataNode = new Node("script");
dataNode.textContent = html
  .split('<script id="bearings-data" type="application/json">')[1]
  .split("</script>")[0];
byId.set("bearings-data", dataNode);

globalThis.document = {
  createElement: (tag) => new Node(tag),
  // Lazily mint any element the page asks for: the shim tracks whatever ids
  // the shipped template actually uses instead of pinning a fixed list.
  getElementById: (id) => {
    if (!byId.has(id)) {
      const n = new Node("div");
      // Parse the one static attribute the page toggles: a `hidden` element
      // in the built HTML starts hidden, as it would in a browser.
      const tag = html.match(new RegExp('<[a-z]+[^>]*\\sid="' + id + '"[^>]*>'));
      n.hidden = Boolean(tag && /\shidden[\s>]/.test(tag[0]));
      new Node("div").appendChild(n);
      byId.set(id, n);
    }
    return byId.get(id);
  },
  querySelector: (sel) => {
    const id = "sel:" + sel;
    if (!byId.has(id)) byId.set(id, new Node("div"));
    return byId.get(id);
  },
};
globalThis.window = {};
globalThis.TextEncoder = TextEncoder;

const script = html.slice(html.indexOf("<script>") + "<script>".length, html.lastIndexOf("</script>"));
new Function(script)();

const badgesOf = (row) =>
  row.children
    .filter((c) => c.className.includes("fm-badge"))
    .map((c) => ({ tone: c.className.replace(/.*fm-badge--/, "").trim(), text: c.textContent }));

const strip = byId.get("bb-stats") || new Node("div");
const stats = strip.children.map((t) => ({
  n: Number(t.children.find((c) => c.className.includes("bb-stat__num"))?.textContent),
  label: t.children.find((c) => c.className.includes("bb-stat__label"))?.textContent,
}));

const rowsOf = (container) =>
  container.children
    .filter((r) => r.className.split(/\s+/).includes("bb-row"))
    .map((row) => {
      const main = row.children.find((c) => c.className.includes("bb-row__main"));
      return {
        title: main?.children.find((c) => c.className.includes("bb-row__title"))?.textContent ?? "",
        sub: main?.children.find((c) => c.className.includes("bb-row__sub"))?.textContent ?? "",
        badges: badgesOf(row),
        pickable: row.children.some((c) => c.className.includes("bb-pick") && !c.className.includes("spacer")),
      };
    });

const uw = byId.get("bb-underway") || new Node("div");
const underway = rowsOf(uw);

const ch = byId.get("bb-charted") || new Node("div");
const charted = rowsOf(ch);
// A fail-closed render replaces the page body instead of the board sections, so
// surface it rather than reporting an empty board as a successful render.
const errorText = [...byId.entries()]
  .filter(([k]) => k.startsWith("sel:"))
  .flatMap(([, n]) => n.children.map((c) => c.textContent))
  .join(" ");
const empty = ch.children.filter((c) => c.className.includes("bb-empty")).map((c) => c.textContent);
const more = ch.children.filter((c) => c.className.includes("bb-morechip")).map((c) => c.textContent);

const hasClass = (n, c) => n.className.split(/\s+/).includes(c);
const findAll = (root, c) => {
  const out = [];
  const walk = (n) => { for (const k of n.children) { if (hasClass(k, c)) out.push(k); walk(k); } };
  walk(root);
  return out;
};
const todaySection = document.getElementById("bb-today");
const cal = byId.get("bb-today-cal") || new Node("div");
const laneOf = (name) => {
  const lane = findAll(cal, "bb-cal__lane--" + name)[0];
  if (!lane) return [];
  return lane.children.filter((c) => hasClass(c, "bb-ev")).map((ev) => ({
    title: ev.children.find((c) => hasClass(c, "bb-ev__title"))?.textContent ?? "",
    sub: ev.children.find((c) => hasClass(c, "bb-ev__sub"))?.textContent ?? "",
    kinds: ev.className.split(/\s+/).filter((c) => c.startsWith("bb-ev--") && c !== "bb-ev--past")
      .map((c) => c.slice("bb-ev--".length)),
    past: hasClass(ev, "bb-ev--past"),
    top: ev.style.top, height: ev.style.height, left: ev.style.left, width: ev.style.width,
    tooltip: ev.attributes.title ?? "",
    markup: ev.innerHTML + ev.children.map((c) => c.innerHTML).join(""),
  }));
};
const nowLine = findAll(cal, "bb-cal__now")[0];
const today = {
  hidden: todaySection.hidden,
  sub: (byId.get("bb-today-sub") || new Node("span")).textContent,
  head: findAll(cal, "bb-cal__colh").map((c) => c.textContent),
  hours: findAll(cal, "bb-cal__hr").map((c) => c.textContent),
  lanes: { captain: laneOf("captain"), ai: laneOf("ai") },
  now: nowLine ? { top: nowLine.style.top } : null,
  asks: (byId.get("bb-today-asks") || new Node("ul")).children.map((li) => ({
    when: li.children.find((c) => hasClass(c, "bb-today__when"))?.textContent ?? "",
    text: li.children.find((c) => hasClass(c, "bb-today__ask"))?.textContent ?? li.textContent,
  })),
  plans: (byId.get("bb-today-plans") || new Node("ul")).children.map((li) => li.textContent),
};

process.stdout.write(
  JSON.stringify({ stats, underway, charted, empty, more, error: errorText, today }) + "\n");
