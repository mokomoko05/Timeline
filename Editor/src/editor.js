import {EditorState, StateField, StateEffect, Compartment, Transaction, Annotation, Prec} from "@codemirror/state";
import {EditorView, ViewPlugin, Decoration, WidgetType, keymap, drawSelection, rectangularSelection} from "@codemirror/view";
import {defaultKeymap, history, historyKeymap, indentWithTab, undo, redo, undoDepth, redoDepth} from "@codemirror/commands";
import {markdown, markdownLanguage, markdownKeymap} from "@codemirror/lang-markdown";
import {syntaxTree, syntaxHighlighting, HighlightStyle, indentOnInput, bracketMatching} from "@codemirror/language";
import {tags} from "@lezer/highlight";

const post = payload => window.webkit?.messageHandlers.boardEditor.postMessage(payload);
const toggleDetails = StateEffect.define();
// 折叠记忆：标题收起（"h…" → true）、折叠块展开（"d…" → true/false）。按工作板存在原生层，打开时随配置传进来。
const folds = new Map();
const refold = StateEffect.define();
const flashEffect = StateEffect.define();
// 光标在不在编辑器里：不在时整页都是渲染好的样子，不露任何 Markdown 标记。
const setFocused = StateEffect.define();
const external = Annotation.define();
const externalChange = external.of(true);
const editable = new Compartment();
const livePreview = new Compartment();
let view;
let composing = false;
let currentReadOnly, currentSourceMode;
let labels = {};
let copyRequest = 0;
const pendingCopies = new Map();

function editability(readOnly) {
  return [EditorState.readOnly.of(readOnly), EditorView.editable.of(!readOnly)];
}

function actionButton(className, label, path) {
  const button = document.createElement("button");
  button.type = "button";
  button.className = className;
  button.title = label;
  button.setAttribute("aria-label", label);
  button.innerHTML = `<svg viewBox="0 0 16 16" aria-hidden="true">${path}</svg>`;
  button.addEventListener("mousedown", event => event.preventDefault());
  return button;
}

// 链接地址和折叠块标题里的 HTML 实体（&amp; 之类）：没有 & 就不用解码，有的话共用一个元素解码。
const entityDecoder = document.createElement("textarea");
function decodeEntities(text) {
  if (!text.includes("&")) return text;
  entityDecoder.innerHTML = text;
  return entityDecoder.value;
}

class OpenLinkWidget extends WidgetType {
  constructor(url) { super(); this.url = url; }
  eq(other) { return this.url === other.url; }
  toDOM() {
    const button = actionButton("board-open-link", labels.openLink || "在 Safari 中打开", '<path d="M9 2h5v5M14 2L7 9M6 3H3a1 1 0 0 0-1 1v9a1 1 0 0 0 1 1h9a1 1 0 0 0 1-1v-3"/>');
    button.dataset.openUrl = this.url;
    button.title += " · " + this.url;
    button.addEventListener("click", () => post({kind: "open", url: this.url}));
    return button;
  }
  ignoreEvent() { return true; }
}

// 代码块的正文（不含围栏），点复制时按按钮所在的位置现找：正文改了、前面插了字，按钮不用重画。
function codeBody(position) {
  const state = view.state, code = state.field(live, false)?.blocks.codes.find(code => code.from === position);
  if (!code) return "";
  const line = state.doc.lineAt(code.from);
  const firstBody = line.number < state.doc.lines ? state.doc.line(line.number + 1).from : code.to;
  const end = code.closing != null ? state.doc.lineAt(code.closing).from : code.to;
  return state.doc.sliceString(firstBody, Math.max(firstBody, end));
}

class CopyCodeWidget extends WidgetType {
  eq() { return true; }
  toDOM() {
    const button = actionButton("board-copy-code", labels.copyCode || "复制代码", '<rect x="5.5" y="5.5" width="8" height="8" rx="1.5"/><path d="M10.5 5.5v-2A1.5 1.5 0 0 0 9 2H3.5A1.5 1.5 0 0 0 2 3.5V9A1.5 1.5 0 0 0 3.5 10.5h2"/>');
    button.dataset.label = labels.copyCode || "复制代码";
    button.addEventListener("click", () => {
      const request = ++copyRequest;
      pendingCopies.set(request, button);
      post({kind: "copy", request, text: codeBody(lineStart(button))});
    });
    return button;
  }
  ignoreEvent() { return true; }
  destroy(button) {
    for (const [request, pending] of pendingCopies) if (pending === button) pendingCopies.delete(request);
  }
}

// 只看块级结构（列表、引用里面的块也看），不进段落和标题里面：长工作板每次改字只走一遍大块，不走每个字的格式。
const containerBlocks = new Set(["Document", "BulletList", "OrderedList", "ListItem", "Blockquote"]);

function collectBlocks(state, tree) {
  const codes = [], headings = [], quotes = [], html = [];
  tree.iterate({enter(node) {
    const name = node.name;
    if (containerBlocks.has(name)) {
      if (name === "Blockquote" && !(node.from <= quotes[quotes.length - 1]?.to)) quotes.push({from: node.from, to: node.to});
      return;
    }
    if (name === "FencedCode" || name === "CodeBlock") {
      const last = node.node.lastChild;
      codes.push({name, from: node.from, to: node.to, closing: name === "FencedCode" && last?.name === "CodeMark" ? last.from : null});
    } else if (name === "HTMLBlock") {
      html.push({from: node.from, to: node.to});
    } else {
      const match = /^ATXHeading([1-6])$/.exec(name);
      if (match) headings.push({from: node.from, level: Number(match[1])});
    }
    return false;
  }});
  return {codes, headings, quotes, html};
}

// <details> 和 </details> 只会出现在 HTML 块里：只看这些块的行，不逐行扫整篇。
function parseDetails(doc, html) {
  const result = [], stack = [], seen = new Map();
  const numbers = [];
  for (const block of html) {
    const last = doc.lineAt(block.to).number;
    for (let number = doc.lineAt(block.from).number; number <= last; number++) {
      if (numbers[numbers.length - 1] !== number) numbers.push(number);
    }
  }
  for (const number of numbers) {
    const line = doc.line(number);
    if (/^(?: {4}|\t)/.test(line.text)) continue;
    const opening = line.text.match(/^\s{0,3}<details\b([^>]*)>\s*(?:<summary>(.*?)<\/summary>)?\s*$/i);
    if (opening) {
      let title = opening[2], summaryLine = number;
      if (title == null) {
        let next = number + 1;
        while (next <= doc.lines && !doc.line(next).text.trim()) next++;
        const summary = next <= doc.lines && doc.line(next).text.match(/^\s*<summary>(.*?)<\/summary>\s*$/i);
        if (summary) { title = summary[1]; summaryLine = next; }
      }
      if (title == null) continue;
      const name = decodeEntities(title) || "折叠内容";
      const occurrence = seen.get(name) ?? 0;
      seen.set(name, occurrence + 1);
      stack.push({from: line.from, headerTo: doc.line(summaryLine).to, key: `d:${name}#${occurrence}`,
                  title: name, initiallyOpen: /\bopen(?:\s|=|$)/i.test(opening[1])});
    } else if (/^\s{0,3}<\/details>\s*$/i.test(line.text) && stack.length) {
      result.push({...stack.pop(), to: line.to, closingFrom: line.from});
    }
  }
  return result.sort((left, right) => left.from - right.from);
}

// 标题的折叠范围：到下一个同级或更高级的标题为止；标题在折叠块里时不越过折叠块的结尾，
// 折叠块里的标题也只和同一个折叠块里的标题比较。收起时末尾的空行留着，和下一个标题之间仍有间隔。
function parseHeadings(doc, found, details) {
  const headings = [], seen = new Map();
  for (const {from, level} of found) {
    const line = doc.lineAt(from);
    const text = line.text.replace(/^\s{0,3}#{1,6}\s*/, "").replace(/\s+#+\s*$/, "").trim();
    const name = `h${level}:${text}`;
    const occurrence = seen.get(name) ?? 0;
    seen.set(name, occurrence + 1);
    const container = details.filter(item => item.from < line.from && line.from < item.closingFrom)
      .reduce((inner, item) => !inner || item.from > inner.from ? item : inner, null);
    headings.push({from: line.from, lineTo: line.to, level, key: `${name}#${occurrence}`, container, next: null});
  }
  // 每个折叠块（和整页）各一个栈：遇到同级或更高级的标题，栈里比它低的标题就到此为止。
  const stacks = new Map();
  for (const heading of headings) {
    const stack = stacks.get(heading.container) ?? [];
    stacks.set(heading.container, stack);
    while (stack.length && stack[stack.length - 1].level >= heading.level) stack.pop().next = heading;
    stack.push(heading);
  }
  for (const heading of headings) {
    let boundary = heading.container ? heading.container.closingFrom : doc.length + 1;
    if (heading.next && heading.next.from < boundary) boundary = heading.next.from;
    let last = doc.lineAt(Math.max(heading.lineTo, boundary - 1)).number;
    if (boundary <= doc.length && doc.lineAt(boundary).from === boundary) last = doc.lineAt(boundary).number - 1;
    while (last > doc.lineAt(heading.from).number && !doc.line(last).text.trim()) last--;
    heading.end = doc.line(last).to;
  }
  return headings.filter(heading => heading.end > heading.lineTo);
}

class HeadingFoldWidget extends WidgetType {
  constructor(key, folded) { super(); this.key = key; this.folded = folded; }
  eq(other) { return this.key === other.key && this.folded === other.folded; }
  toDOM() {
    const button = document.createElement("button");
    button.type = "button";
    button.className = "board-heading-fold";
    button.innerHTML = '<svg viewBox="0 0 16 16" aria-hidden="true"><path d="M6 4l4 4-4 4"/></svg>';
    this.updateDOM(button);
    button.addEventListener("mousedown", event => event.preventDefault());
    // 按按钮上现在的状态翻转：按钮在两次点击之间被重画也不会按旧状态再设一遍。
    button.addEventListener("click", () => setFold(button.dataset.key, button.dataset.folded !== "true", lineStart(button)));
    return button;
  }
  // 状态变了也沿用同一个按钮：快速连点时按下和松开落在同一个元素上，点击不会丢。
  updateDOM(button) {
    button.dataset.key = this.key;
    button.dataset.folded = String(this.folded);
    button.setAttribute("aria-expanded", String(!this.folded));
    button.setAttribute("aria-label", this.folded ? (labels.expand || "展开") : (labels.collapse || "收起"));
    return true;
  }
  ignoreEvent() { return true; }
}

// 小部件所在那一行的开头。
function lineStart(element) {
  try { return view.state.doc.lineAt(view.posAtDOM(element)).from; } catch { return null; }
}

class FoldedMoreWidget extends WidgetType {
  constructor(key) { super(); this.key = key; }
  eq(other) { return this.key === other.key; }
  toDOM() {
    const button = document.createElement("button");
    button.type = "button";
    button.className = "board-fold-more";
    button.textContent = "⋯";
    button.setAttribute("aria-label", labels.expand || "展开");
    button.addEventListener("mousedown", event => event.preventDefault());
    button.addEventListener("click", () => setFold(this.key, false, lineStart(button)));
    return button;
  }
  ignoreEvent() { return true; }
}

function setFold(key, folded, lineFrom) {
  folds.set(key, folded);
  post({kind: "fold", key, value: folded});
  keepInPlace(lineFrom, {effects: [refold.of(null)]});
}

// 收起 / 展开时被点的那一行（标题、折叠块）留在屏幕上原来的位置，内容在它下面展开、收起。
// CodeMirror 自己滚到底时会让底部不动，展开就把标题往上顶；这里明确以这一行为准。
// 收起后剩下的内容不够撑住原来的滚动位置时，底部临时留出空白（往上滚就收回去）。
const basePaddingBottom = 24;
let bottomSlack = 0;

function setBottomSlack(value) {
  bottomSlack = Math.max(0, value);
  view.contentDOM.style.paddingBottom = bottomSlack ? `${basePaddingBottom + bottomSlack}px` : "";
}

function trimBottomSlack() {
  if (!bottomSlack || !view) return;
  const scroller = view.scrollDOM;
  const overflow = scroller.scrollTop + scroller.clientHeight - (scroller.scrollHeight - bottomSlack);
  if (overflow < bottomSlack) setBottomSlack(overflow);
}

function keepInPlace(lineFrom, spec) {
  const box = view.scrollDOM.getBoundingClientRect();
  const coords = lineFrom == null ? null : view.coordsAtPos(lineFrom, 1);
  if (!coords || coords.bottom < box.top || coords.top > box.bottom) { view.dispatch(spec); return; }
  const offset = coords.top - box.top;
  view.dispatch({...spec, effects: [...(spec.effects ?? []), EditorView.scrollIntoView(lineFrom, {y: "start", yMargin: offset})]});
  view.requestMeasure({
    read: () => ({coords: view.coordsAtPos(lineFrom, 1), box: view.scrollDOM.getBoundingClientRect()}),
    write: ({coords, box}) => {
      if (!coords) return;
      const drift = coords.top - box.top - offset;
      if (drift <= 1) return;
      setBottomSlack(bottomSlack + drift);
      view.scrollDOM.scrollTop += drift;
    }
  });
}

// 切换所见即所得 / 完整源码时，光标（或屏幕最上面那一行）留在屏幕上原来的高度，不会跳到别处去找不着。
function captureAnchor(position) {
  const box = view.scrollDOM.getBoundingClientRect();
  const coords = position != null ? view.coordsAtPos(position) : null;
  if (coords && coords.top >= box.top && coords.bottom <= box.bottom) return {position, offset: coords.top - box.top};
  const top = view.posAtCoords({x: box.left + box.width / 2, y: box.top + 2}, false);
  const topCoords = view.coordsAtPos(top);
  return {position: top, offset: topCoords ? topCoords.top - box.top : 0};
}

function restoreAnchor(anchor) {
  view.requestMeasure({
    // 位置不在已经排好的那一段里时 coordsAtPos 拿不到坐标，改用行块的高度算。
    read: () => ({coords: view.coordsAtPos(anchor.position) ?? {top: view.documentTop + view.lineBlockAt(anchor.position).top},
                  box: view.scrollDOM.getBoundingClientRect()}),
    write: ({coords, box}) => { if (coords) view.scrollDOM.scrollTop += coords.top - box.top - anchor.offset; }
  });
}

class CheckWidget extends WidgetType {
  constructor(checked, position) { super(); this.checked = checked; this.position = position; }
  eq(other) { return this.checked === other.checked && this.position === other.position; }
  toDOM() {
    const button = document.createElement("button");
    button.className = "board-check";
    button.type = "button";
    button.setAttribute("role", "checkbox");
    button.setAttribute("aria-checked", String(this.checked));
    button.setAttribute("aria-label", this.checked ? "标记未完成" : "标记完成");
    if (this.checked) button.innerHTML = '<svg viewBox="0 0 16 16"><path d="M3 8l3 3 7-7"/></svg>';
    button.addEventListener("mousedown", event => event.preventDefault());
    button.addEventListener("click", () => {
      if (currentReadOnly) return;
      const marker = view.state.doc.sliceString(this.position, this.position + 1);
      view.dispatch({changes: {from: this.position, to: this.position + 1, insert: marker === " " ? "x" : " "},
                     annotations: [Transaction.userEvent.of("input.task")]});
    });
    return button;
  }
  ignoreEvent() { return true; }
}

class DetailsWidget extends WidgetType {
  constructor(item, open) { super(); this.item = item; this.open = open; }
  eq(other) { return this.item.key === other.item.key && this.item.title === other.item.title && this.open === other.open; }
  // 点的时候按 key 找现在的位置（前面改过字，这个小部件是挪过来的，没有重画）。
  current() { return view.state.field(live, false)?.details.find(item => item.key === this.item.key) ?? this.item; }
  toDOM() {
    const button = document.createElement("button");
    button.className = "board-details";
    button.type = "button";
    button.setAttribute("aria-expanded", String(this.open));
    const arrow = document.createElement("span"), title = document.createElement("span");
    arrow.className = "arrow";
    arrow.dataset.open = String(this.open);
    arrow.innerHTML = '<svg viewBox="0 0 16 16" aria-hidden="true"><path d="M6 4l4 4-4 4"/></svg>';
    title.className = "title";
    title.textContent = this.item.title;
    button.append(arrow, title);
    button.addEventListener("mousedown", event => event.preventDefault());
    button.addEventListener("click", () => {
      const item = this.current();
      const transaction = {effects: [toggleDetails.of({from: item.from, open: !this.open})]};
      const head = view.state.selection.main.head;
      if (this.open && head >= item.from && head <= item.to) {
        transaction.selection = {anchor: item.to < view.state.doc.length ? item.to + 1 : Math.max(0, item.from - 1)};
      }
      keepInPlace(item.from, transaction);
    });
    button.addEventListener("dblclick", () => {
      if (view.state.readOnly) return;
      const item = this.current();
      const line = view.state.doc.lineAt(item.headerTo);
      const offset = line.text.indexOf("<summary>") + "<summary>".length;
      view.dispatch({selection: {anchor: line.from + offset}, effects: toggleDetails.of({from: item.from, open: true}), scrollIntoView: true});
      view.focus();
    });
    return button;
  }
  ignoreEvent() { return true; }
}

const focused = StateField.define({
  create() { return false; },
  update(value, transaction) {
    for (const effect of transaction.effects) if (effect.is(setFocused)) value = effect.value;
    return value;
  }
});

// 露出 Markdown 标记要看的选区：只在可编辑、光标在编辑器里时才有。
function revealSelection(state) {
  return !state.readOnly && state.field(focused, false) ? state.selection.main : null;
}

// 折叠块的状态（展开没有、头和尾是不是露出源码）只随选区变化。连成一个字符串比较，选区移动但这些都没变时不重算结构。
function detailsStates(state, details, expanded) {
  const selection = revealSelection(state);
  const overlaps = (from, to) => selection && selection.from <= to && selection.to >= from;
  return details.map(item => {
    const remembered = expanded.get(item.from) ?? folds.get(item.key);
    const explicitlyClosed = remembered === false;
    const headerActive = !explicitlyClosed && !!overlaps(item.from, item.headerTo);
    let open = remembered ?? item.initiallyOpen;
    if (!explicitlyClosed && (headerActive || (selection && selection.head > item.headerTo && selection.head < item.closingFrom))) open = true;
    const closingLine = state.doc.lineAt(item.closingFrom).number;
    const previous = closingLine > 1 ? state.doc.line(closingLine - 1) : null;
    const closingFrom = previous && !previous.text.trim() ? previous.from - 1 : item.closingFrom;
    return {item, open, headerActive, closingFrom, closingActive: !!overlaps(closingFrom, item.to)};
  });
}

function statesKey(states) {
  return states.map(state => (state.open ? "o" : "c") + (state.headerActive ? "h" : "") + (state.closingActive ? "e" : "")).join();
}

// 结构层：标题折叠、折叠块、代码块和引用的底框、标题的字号、搜索高亮。跨行隐藏只能放在这里（状态字段），
// 正文和折叠变了才重算；每个字的格式和标记的显隐交给只看屏幕上那一段的 inlinePreview。
function structure(state, blocks, states, headings, flash) {
  const ranges = [], hidden = [];
  const add = (from, to, decoration) => { if (from < to) ranges.push(decoration.range(from, to)); };
  const replace = (from, to, widget) => add(from, to, Decoration.replace({widget, atomic: true}));
  // 标题和折叠块按位置依次处理：外层收起了，里面的就不再处理。
  const foldables = [...states.map(details => ({details})), ...headings.map(heading => ({heading}))]
    .sort((left, right) => (left.details?.item ?? left.heading).from - (right.details?.item ?? right.heading).from);
  for (const {details, heading} of foldables) {
    if (heading) {
      if (hidden.some(range => heading.from >= range[0] && heading.from <= range[1])) continue;
      const folded = folds.get(heading.key) === true;
      ranges.push(Decoration.line({class: "cm-foldable" + (folded ? " cm-folded" : "")}).range(heading.from));
      ranges.push(Decoration.widget({widget: new HeadingFoldWidget(heading.key, folded), side: -1}).range(heading.from));
      if (folded) {
        ranges.push(Decoration.widget({widget: new FoldedMoreWidget(heading.key), side: 1}).range(heading.lineTo));
        replace(heading.lineTo, heading.end, undefined);
        hidden.push([heading.lineTo, heading.end]);
      }
      continue;
    }
    const {item, open, headerActive, closingFrom, closingActive} = details;
    if (hidden.some(range => item.from >= range[0] && item.to <= range[1])) continue;
    if (!headerActive) replace(item.from, item.headerTo, new DetailsWidget(item, open));
    if (!open) {
      replace(item.headerTo, item.to, undefined);
      hidden.push([item.headerTo, item.to]);
    } else {
      if (!closingActive) replace(closingFrom, item.to, undefined);
      const first = state.doc.lineAt(item.headerTo).number + 1;
      const last = state.doc.lineAt(item.closingFrom).number;
      for (let number = first; number < last; number++) {
        const line = state.doc.line(number);
        if (number === first && !line.text.trim()) { replace(line.from - 1, line.to, undefined); continue; }
        if (number === last - 1 && !line.text.trim()) continue;
        ranges.push(Decoration.line({class: "cm-details-body"}).range(line.from));
      }
    }
  }
  const concealed = (from, to) => hidden.some(range => from >= range[0] && to <= range[1]);
  for (const {from, level} of blocks.headings) {
    if (!concealed(from, from)) ranges.push(Decoration.line({class: "cm-heading-" + level}).range(state.doc.lineAt(from).from));
  }
  for (const code of blocks.codes) {
    if (concealed(code.from, code.to)) continue;
    const line = state.doc.lineAt(code.from);
    const lastLine = state.doc.lineAt(code.to).number;
    for (let number = line.number; number <= lastLine; number++) {
      const classes = "cm-code" + (number === line.number ? " cm-code-start" : "") + (number === lastLine ? " cm-code-end" : "");
      ranges.push(Decoration.line({class: classes}).range(state.doc.line(number).from));
    }
    if (code.name === "FencedCode") {
      ranges.push(Decoration.line({class: "cm-code-header"}).range(line.from));
      ranges.push(Decoration.widget({widget: new CopyCodeWidget(), side: -1}).range(line.from));
    }
  }
  // 引用：一个引用的每一行都铺底色，只有第一行、最后一行是框的上下边；隔着空行的两段引用是两块，空行不铺。
  for (const quote of blocks.quotes) {
    const first = state.doc.lineAt(quote.from).number, last = state.doc.lineAt(Math.max(quote.from, quote.to - 1)).number;
    for (let number = first; number <= last; number++) {
      const line = state.doc.line(number);
      if (concealed(line.from, line.to)) continue;
      ranges.push(Decoration.line({class: "cm-quote" + (number === first ? " cm-quote-start" : "") + (number === last ? " cm-quote-end" : "")}).range(line.from));
    }
  }
  if (flash && !concealed(flash.from, flash.to)) {
    ranges.push(Decoration.line({class: "cm-search-line"}).range(state.doc.lineAt(flash.from).from));
    add(flash.from, flash.to, Decoration.mark({class: "cm-search-hit"}));
  }
  return Decoration.set(ranges, true);
}

// 一次只改了一行里的普通文字（不是标题、引用、围栏、HTML、分隔线这类决定版面的行，也没有增删行）：
// 块的结构不会变，把上次算好的结构挪个位置就行，不用整篇重算。长工作板上打字主要走这条路。
const structuralLine = /^\s*(?:#|>|<|```|~~~)/;
function plainLine(text) {
  if (!text.trim() || /^(?: {4}|\t)/.test(text) || /^\s*[-=_*]+\s*$/.test(text)) return false;
  return !structuralLine.test(text.replace(/^(?:\s*(?:[-+*]|\d+[.)])\s+)+/, ""));
}

function plainEdit(transaction) {
  const before = transaction.startState.doc, after = transaction.state.doc;
  if (before.lines !== after.lines) return false;
  let plain = true;
  transaction.changes.iterChanges((fromA, toA, fromB, toB) => {
    if (!plain) return;
    const a = before.lineAt(fromA), b = after.lineAt(fromB);
    plain = a.to >= toA && b.to >= toB && plainLine(a.text) && plainLine(b.text);
  });
  return plain;
}

// 结构里记的位置跟着改动挪：开头挪到改动前面，结尾跟着改动往后延（在一节、一块的末尾打字，范围也包住新字）。
function mapStructure(value, changes) {
  const start = position => changes.mapPos(position, -1), end = position => changes.mapPos(position, 1);
  const details = value.details.map(item => ({...item, from: start(item.from), headerTo: start(item.headerTo),
                                               closingFrom: start(item.closingFrom), to: end(item.to)}));
  const container = new Map(value.details.map((item, index) => [item, details[index]]));
  const headings = value.headings.map(heading => ({...heading, from: start(heading.from), lineTo: start(heading.lineTo),
                                                   end: end(heading.end), container: heading.container && container.get(heading.container)}));
  const range = item => ({...item, from: start(item.from), to: end(item.to)});
  const blocks = {codes: value.blocks.codes.map(code => ({...range(code), closing: code.closing == null ? null : start(code.closing)})),
                  headings: value.blocks.headings.map(heading => ({...heading, from: start(heading.from)})),
                  quotes: value.blocks.quotes.map(range), html: value.blocks.html.map(range)};
  return {blocks, details, headings};
}

const live = StateField.define({
  create(state) {
    const tree = syntaxTree(state);
    const blocks = collectBlocks(state, tree);
    const details = parseDetails(state.doc, blocks.html);
    const headings = parseHeadings(state.doc, blocks.headings, details);
    const expanded = new Map();
    const states = detailsStates(state, details, expanded);
    return {tree, blocks, details, headings, expanded, flash: null, key: statesKey(states),
            decorations: structure(state, blocks, states, headings, null)};
  },
  update(value, transaction) {
    let expanded = value.expanded;
    let flash = value.flash;
    const changed = transaction.docChanged;
    if (changed) {
      expanded = new Map([...expanded].map(([position, open]) => [transaction.changes.mapPos(position), open]));
      flash = null;
    }
    let effectsChanged = false;
    for (const effect of transaction.effects) {
      if (effect.is(toggleDetails)) {
        expanded = new Map(expanded);
        const item = value.details.find(item => item.from === effect.value.from);
        if (item) {
          expanded.set(item.from, effect.value.open);
          folds.set(item.key, effect.value.open);
          post({kind: "fold", key: item.key, value: effect.value.open});
        }
        effectsChanged = true;
      } else if (effect.is(refold)) {
        effectsChanged = true;
      } else if (effect.is(flashEffect)) {
        flash = effect.value;
        effectsChanged = true;
      }
    }
    const tree = syntaxTree(transaction.state);
    const parsed = tree !== value.tree;
    let {blocks, details, headings} = value;
    const mapped = changed && plainEdit(transaction);
    if (mapped) ({blocks, details, headings} = mapStructure(value, transaction.changes));
    else if (changed || parsed) {
      blocks = collectBlocks(transaction.state, tree);
      details = parseDetails(transaction.state.doc, blocks.html);
      headings = parseHeadings(transaction.state.doc, blocks.headings, details);
    }
    if ((transaction.selection || changed) && !transaction.state.readOnly) {
      // 编辑时光标进了收起的标题下面（比如在收起的标题末尾回车）：展开这一节，不在看不见的地方打字。
      const head = transaction.state.selection.main.head;
      for (const heading of headings) {
        if (head > heading.lineTo && head <= heading.end && folds.get(heading.key) === true) {
          folds.set(heading.key, false);
          post({kind: "fold", key: heading.key, value: false});
          effectsChanged = true;
        }
      }
      // 光标进了收起的折叠块：展开它，并且记住是展开的（光标离开、编辑器失去焦点时不再收回去跳一下）。
      if (transaction.selection && !transaction.effects.some(effect => effect.is(toggleDetails))) {
        for (const item of details) {
          if (head > item.headerTo && head < item.to && !(expanded.get(item.from) ?? folds.get(item.key) ?? item.initiallyOpen)) {
            expanded = new Map(expanded);
            expanded.set(item.from, true);
          }
        }
      }
    }
    const states = detailsStates(transaction.state, details, expanded);
    const key = statesKey(states);
    if (!changed && !parsed && !effectsChanged && key === value.key) {
      return expanded === value.expanded ? value : {...value, expanded};
    }
    if (mapped && !effectsChanged && key === value.key && flash === value.flash) {
      return {tree, blocks, details, headings, expanded, flash, key, decorations: value.decorations.map(transaction.changes)};
    }
    return {tree, blocks, details, headings, expanded, flash, key,
            decorations: structure(transaction.state, blocks, states, headings, flash)};
  },
  provide: field => [
    EditorView.decorations.from(field, value => value.decorations),
    EditorView.atomicRanges.of(view => view.state.field(field, false)?.decorations.update({filter: (_from, _to, decoration) => decoration.spec.atomic === true}) ?? Decoration.none)
  ]
});

// 行内层：加粗、斜体、行内代码、链接、待办勾选框，以及 Markdown 标记的显隐。只排屏幕上看得到的那一段。
// 标记只在光标进到那个元素里面时露出来（不是整行都露）：上下移动光标经过一行时版面不变，不会一行行跳动。
// 光标停在元素的边上（比如加粗文字的后面）不算进去，这时打的字也确实在元素外面。
function inlineDecorations(view) {
  const {state} = view;
  const selection = revealSelection(state);
  const inside = (from, to) => selection && selection.to > from && selection.from < to;
  const ranges = [], seen = new Set();
  const add = (from, to, decoration) => { if (from < to) ranges.push(decoration.range(from, to)); };
  const hide = (from, to) => add(from, to, Decoration.replace({atomic: true}));
  const tree = syntaxTree(state);
  for (const visible of view.visibleRanges) {
    tree.iterate({from: visible.from, to: visible.to, enter(node) {
      const name = node.name;
      if (containerBlocks.has(name)) return;
      const id = name + ":" + node.from;
      if (seen.has(id)) return false;
      seen.add(id);
      if (name === "FencedCode") {
        // 围栏那两行（``` 和语言名）只在光标碰到那一行时露出来；平时开头一行缩成代码块的上边，复制按钮浮在右上角。
        const line = state.doc.lineAt(node.from), lastLine = state.doc.lineAt(node.to).number;
        const touches = target => selection && selection.from <= target.to && selection.to >= target.from;
        const last = node.node.lastChild;
        const closing = last?.name === "CodeMark" && last.from > line.from ? state.doc.lineAt(last.from) : null;
        if (!touches(line)) {
          if ((closing ? closing.number : lastLine + 1) - line.number - 1 > 0) {
            ranges.push(Decoration.line({class: "cm-code-header-concealed"}).range(line.from));
            ranges.push(Decoration.line({class: "cm-code-first"}).range(state.doc.line(line.number + 1).from));
          }
          hide(line.from, line.to);
        }
        if (closing && !touches(closing)) {
          hide(closing.from, closing.to);
          ranges.push(Decoration.line({class: "cm-code-footer"}).range(closing.from));
        }
        return false;
      }
      if (name === "CodeBlock" || name === "HTMLBlock") return false;
      if (name === "StrongEmphasis") add(node.from, node.to, Decoration.mark({class: "cm-strong"}));
      else if (name === "Emphasis") add(node.from, node.to, Decoration.mark({class: "cm-emphasis"}));
      else if (name === "Strikethrough") add(node.from, node.to, Decoration.mark({class: "cm-strike"}));
      else if (name === "InlineCode") add(node.from, node.to, Decoration.mark({class: "cm-code"}));
      else if (name === "HeaderMark" || name === "QuoteMark") {
        // 行首的 # 和 >：光标在行首（按 ← 越过它们）时才露出来，可以改级别、删掉；光标在文字开头时不露。
        // 藏着的时候在文字开头按退格，整个标记一起删掉（标题变回正文）。
        const end = state.doc.sliceString(node.to, node.to + 1) === " " ? node.to + 1 : node.to;
        if (!(selection && selection.from < end && selection.to >= node.from)) hide(node.from, end);
      } else if (name === "EmphasisMark" || name === "StrikethroughMark" || name === "CodeMark") {
        const parent = node.node.parent;
        if (parent && !inside(parent.from, parent.to)) hide(node.from, node.to);
      } else if (name === "TaskMarker") {
        const line = state.doc.lineAt(node.from);
        const checked = /[xX]/.test(state.doc.sliceString(node.from, node.to));
        if (checked) add(node.to, line.to, Decoration.mark({class: "cm-task-done"}));
        ranges.push(Decoration.replace({widget: new CheckWidget(checked, node.from + 1), atomic: true}).range(node.from, node.to));
      } else if (name === "ListMark") {
        const line = state.doc.lineAt(node.from);
        if (/^\s*[-+*]\s+\[[ xX]\]/.test(line.text)) hide(node.from, node.to + 1);
      } else if (name === "Link") {
        const destination = node.node.getChild("URL");
        const closing = node.node.getChildren("LinkMark").find(mark => state.doc.sliceString(mark.from, mark.to) === "]");
        if (destination && closing) {
          const url = decodeEntities(state.doc.sliceString(destination.from, destination.to).replace(/^<|>$/g, "")
            .replace(/\\([!"#$%&'()*+,\-./:;<=>?@[\]\\^_`{|}~])/g, "$1"));
          add(node.from + 1, closing.from, Decoration.mark({class: "cm-link", attributes: {"data-url": url}}));
          ranges.push(Decoration.widget({widget: new OpenLinkWidget(url), side: 1}).range(node.to));
          if (!inside(node.from, node.to)) {
            hide(node.from, node.from + 1);
            hide(closing.from, node.to);
          }
        }
      }
    }});
  }
  return Decoration.set(ranges, true);
}

const inlinePreview = ViewPlugin.fromClass(class {
  constructor(view) { this.build(view); }
  update(update) {
    const {startState, state} = update;
    if (update.docChanged || update.viewportChanged || update.selectionSet || update.transactions.some(transaction => transaction.effects.length)
        || syntaxTree(startState) !== syntaxTree(state) || startState.readOnly !== state.readOnly) this.build(update.view);
  }
  build(view) {
    this.decorations = inlineDecorations(view);
    this.atomic = this.decorations.update({filter: (_from, _to, decoration) => decoration.spec.atomic === true});
  }
}, {
  decorations: plugin => plugin.decorations,
  provide: plugin => EditorView.atomicRanges.of(view => view.plugin(plugin)?.atomic ?? Decoration.none)
});

const livePreviewExtensions = [live, inlinePreview];

const highlighting = HighlightStyle.define([
  {tag: tags.processingInstruction, class: "cm-syntax"},
  {tag: tags.meta, class: "cm-syntax"},
  {tag: tags.contentSeparator, class: "cm-syntax"}
]);

function runHistory(command) {
  if (!view || currentReadOnly) return false;
  return command(view);
}

let lastHistory = "";
function reportHistory(state) {
  const depth = {undo: undoDepth(state), redo: redoDepth(state)};
  const key = depth.undo + "/" + depth.redo;
  if (key === lastHistory) return;
  lastHistory = key;
  post({kind: "history", ...depth});
}

function snapshot() {
  return {key: currentKey, source: view.state.doc.toString(), anchor: view.state.selection.main.anchor,
          head: view.state.selection.main.head, composing: composing || view.composing};
}

// 改动不是每个字都把全文送给原生层：停顿一下再送；失去焦点、⌘↩、输入法结束、换工作板时立即送。
// 每条消息带着工作板的 key，换走之后才到的也记到原来那块工作板上。
const changeDelay = 150;
let changeTimer = null;

function scheduleChange() {
  clearTimeout(changeTimer);
  changeTimer = setTimeout(flushChange, changeDelay);
}

function flushChange() {
  if (changeTimer == null) return;
  clearTimeout(changeTimer);
  changeTimer = null;
  post({kind: "change", ...snapshot()});
}

function commit() {
  clearTimeout(changeTimer);
  changeTimer = null;
  post({kind: "commit", ...snapshot()});
}

function editorExtensions(config) {
  return [history(), drawSelection({cursorBlinkRate: 0}), rectangularSelection(), EditorView.lineWrapping,
          indentOnInput(), bracketMatching(), markdown({base: markdownLanguage}), syntaxHighlighting(highlighting),
          focused,
          livePreview.of(config.sourceMode ? [] : livePreviewExtensions),
          editable.of(editability(config.readOnly)),
          // 撤销 / 重做：没有可撤销的也吞掉按键，不落到应用别处的撤销上。
          Prec.highest(keymap.of([
            {key: "Mod-z", run: () => { runHistory(undo); return true; }, preventDefault: true},
            {key: "Mod-Shift-z", run: () => { runHistory(redo); return true; }, preventDefault: true},
            {key: "Mod-y", run: () => { runHistory(redo); return true; }, preventDefault: true}
          ])),
          // ⌘Enter 是全应用统一的保存键：立即保存，继续编辑。
          Prec.highest(keymap.of([{key: "Mod-Enter", run: view => {
            if (view.state.readOnly || composing || view.composing) return false;
            commit();
            return true;
          }}])),
          keymap.of([...markdownKeymap, ...defaultKeymap, ...historyKeymap, indentWithTab]),
          Prec.lowest(EditorView.domEventHandlers({keydown(event) {
            if (event.key !== "Escape" || event.isComposing || composing || view.composing) return false;
            event.stopPropagation();
            return true;
          }})),
          EditorView.contentAttributes.of(view => ({
            "aria-label": "工作板 Markdown 内容",
            spellcheck: "false", tabindex: "0"
          })),
          EditorView.updateListener.of(update => {
            if (update.transactions.length) reportHistory(update.state);
            if (update.docChanged && !update.transactions.some(transaction => transaction.annotation(external))) scheduleChange();
          }),
          EditorView.domEventHandlers({
            // 只读的工作板：复制系统原生选区里看到的文字（CodeMirror 自己的选区在只读时不跟随拖选）。
            copy(event, view) {
              if (!view.state.readOnly) return false;
              const text = window.getSelection()?.toString() ?? "";
              if (!text) return false;
              event.clipboardData?.setData("text/plain", text);
              event.preventDefault();
              return true;
            },
            compositionstart() { composing = true; },
            compositionend() { composing = false; setTimeout(commit, 0); },
            // 光标进出编辑器：按编辑区自己的焦点算（不看窗口是不是在前台），切到别的应用再回来时版面不变。
            focus(_event, view) { if (!view.state.field(focused)) view.dispatch({effects: setFocused.of(true)}); },
            blur(_event, view) {
              commit();
              if (view.state.field(focused)) view.dispatch({effects: setFocused.of(false)});
            },
            click(event) {
              const link = event.target.closest("[data-url]");
              if (link && (event.metaKey || view.state.readOnly)) {
                // Dragging across a link selects text for copying rather than opening Safari.
                if (!view.state.selection.main.empty || window.getSelection()?.isCollapsed === false) return false;
                post({kind: "open", url: link.dataset.url});
                return true;
              }
              return false;
            }
          })];
}

function freshState(config) {
  // 光标先放在末尾：用键盘进到编辑器时接着往下写，也不会一进来就露出开头那个元素的标记。
  return EditorState.create({doc: config.source ?? "", selection: {anchor: (config.source ?? "").length}, extensions: editorExtensions(config)});
}

function loadFolds(entries) {
  folds.clear();
  if (entries) for (const [key, value] of Object.entries(entries)) folds.set(key, value);
}

// 原生层传来的折叠记忆和这里的是否一样（标题没记就是展开）。在别处（笔记里的看板内容）改了折叠时不一样。
function sameFolds(entries) {
  const normalized = (key, value) => key.startsWith("h") ? value === true : value;
  for (const key of new Set([...folds.keys(), ...Object.keys(entries)])) {
    if (normalized(key, folds.get(key)) !== normalized(key, entries[key])) return false;
  }
  return true;
}

// 所有工作板共用一个编辑器（一份网页进程）。换工作板时把当前这块的编辑器状态（正文、光标、撤销历史、
// 折叠块的展开）和滚动位置存起来，换回来时原样恢复。只留最近用过的几块。
const savedBoards = new Map();
const savedBoardLimit = 8;
let currentKey = null;

function switchBoard(config) {
  if (currentKey != null) {
    flushChange();
    savedBoards.delete(currentKey);
    savedBoards.set(currentKey, {state: view.state, scroll: view.scrollDOM.scrollTop});
    while (savedBoards.size > savedBoardLimit) savedBoards.delete(savedBoards.keys().next().value);
  }
  setBottomSlack(0);
  const saved = savedBoards.get(config.key);
  savedBoards.delete(config.key);
  currentKey = config.key;
  loadFolds(config.folds);
  view.setState(saved?.state ?? freshState(config));
  // 恢复的状态里模式可能和现在不同：按这次的配置重新设一遍，折叠按这块工作板的记忆重算。
  view.dispatch({effects: [editable.reconfigure(editability(!!config.readOnly)), livePreview.reconfigure(config.sourceMode ? [] : livePreviewExtensions),
                           refold.of(null), setFocused.of(document.activeElement === view.contentDOM)]});
  currentReadOnly = config.readOnly;
  currentSourceMode = config.sourceMode;
  const scroll = saved?.scroll ?? 0;
  view.requestMeasure({read: () => null, write: () => { view.scrollDOM.scrollTop = scroll; }});
  lastHistory = "";
  reportHistory(view.state);
}

window.boardEditor = {
  configure(config) {
    if (config.labels) labels = config.labels;
    if (!view) {
      currentKey = config.key ?? null;
      loadFolds(config.folds);
      view = new EditorView({parent: document.getElementById("editor"), state: freshState(config)});
      // 只读的工作板交给系统原生选区：CodeMirror 的鼠标选择在渲染后的标题、折叠块和浮动按钮附近
      // 算出的位置和看到的文字不一致，拖选会错位。捕获阶段截住按下事件、不阻止默认行为。按钮类控件不受影响。
      view.dom.addEventListener("mousedown", event => {
        if (!view.state.readOnly || event.button !== 0) return;
        if (event.target.closest?.("button, .board-check, .board-details, .board-open-link, .board-copy-code")) return;
        event.stopPropagation();
      }, true);
      view.scrollDOM.addEventListener("scroll", trimBottomSlack, {passive: true});
    } else {
      if (config.key != null && config.key !== currentKey) switchBoard(config);
      else if (config.folds && !sameFolds(config.folds)) {
        loadFolds(config.folds);
        view.dispatch({effects: refold.of(null)});
      }
      if (typeof config.source === "string" && config.source !== view.state.doc.toString() && !view.composing && !composing) {
        const old = view.state.selection.main;
        view.dispatch({changes: {from: 0, to: view.state.doc.length, insert: config.source},
                       selection: {anchor: Math.min(old.anchor, config.source.length), head: Math.min(old.head, config.source.length)},
                       annotations: [externalChange, Transaction.addToHistory.of(false)]});
      }
      const effects = [];
      if (!!currentReadOnly !== !!config.readOnly) effects.push(editable.reconfigure(editability(!!config.readOnly)));
      if (!!currentSourceMode !== !!config.sourceMode) effects.push(livePreview.reconfigure(config.sourceMode ? [] : livePreviewExtensions));
      if (effects.length) {
        const anchor = captureAnchor(view.state.selection.main.head);
        view.dispatch({effects});
        restoreAnchor(anchor);
      }
    }
    currentReadOnly = config.readOnly;
    currentSourceMode = config.sourceMode;
    view.dom.dataset.preview = String(!!config.readOnly);
    if (config.colors) for (const [key, value] of Object.entries(config.colors)) document.documentElement.style.setProperty("--" + key, value);
    if (config.fontSize) document.documentElement.style.setProperty("--font-size", config.fontSize + "px");
    return snapshot();
  },
  snapshot,
  edit() {
    if (currentReadOnly) return;
    view.focus();
  },
  copyResult(request, success) {
    const button = pendingCopies.get(request);
    pendingCopies.delete(request);
    if (!button?.isConnected) return;
    const original = button.dataset.copyIcon || button.innerHTML;
    button.dataset.copyIcon = original;
    const label = labels.copyCode || "复制代码";
    const result = success ? (labels.copied || "已复制") : (labels.copyFailed || "复制失败，请重试");
    button.dataset.label = result;
    button.title = result;
    button.setAttribute("aria-label", result);
    if (success) {
      button.dataset.copied = "true";
      button.innerHTML = '<svg viewBox="0 0 16 16" aria-hidden="true"><path d="M3 8l3 3 7-7"/></svg>';
    }
    setTimeout(() => {
      if (!button.isConnected) return;
      button.innerHTML = original;
      delete button.dataset.copied;
      button.dataset.label = label;
      button.title = label;
      button.setAttribute("aria-label", label);
    }, 1600);
  },
  focus() { view.focus(); },
  escape() {
    const target = view.dom.contains(document.activeElement) ? document.activeElement : view.contentDOM;
    target.dispatchEvent(new KeyboardEvent("keydown", {key: "Escape", code: "Escape", bubbles: true, cancelable: true}));
  },
  insertTemplate(kind, labels) {
    if (currentReadOnly) return snapshot();
    const selection = view.state.selection.main;
    const selected = view.state.doc.sliceString(selection.from, selection.to);
    let content, title;
    if (kind === "disclosure") {
      title = labels.title;
      content = `<details>\n<summary>${title}</summary>\n\n${selected || labels.body}\n\n</details>`;
    } else if (kind === "paper") {
      title = labels.paper;
      content = `# ${title}\n\n- [ ] Intro & Abstract\n- [ ] Background\n- [ ] Design\n- [ ] Experiment\n\n## ${labels.notes}\n\n`;
    } else {
      title = labels.meeting;
      content = `# ${title}\n\n## ${labels.progress}\n\n## ${labels.discussion}\n\n## ${labels.actions}\n\n`;
    }
    const before = view.state.doc.sliceString(0, selection.from), after = view.state.doc.sliceString(selection.to);
    const prefix = !before || before.endsWith("\n\n") ? "" : before.endsWith("\n") ? "\n" : "\n\n";
    const suffix = !after || after.startsWith("\n\n") ? "" : after.startsWith("\n") ? "\n" : "\n\n";
    const replacement = prefix + content + suffix;
    const anchor = selection.from + replacement.indexOf(title);
    view.dispatch({changes: {from: selection.from, to: selection.to, insert: replacement},
                   selection: {anchor, head: anchor + title.length}, scrollIntoView: true,
                   annotations: Transaction.userEvent.of("input.template")});
    view.focus();
    commit();
    return snapshot();
  },
  replaceSelection(text) {
    view.dispatch(view.state.replaceSelection(text));
    return snapshot();
  },
  select(anchor, head = anchor) { view.dispatch({selection: {anchor, head}}); return snapshot(); },
  // 搜索结果跳过来：展开包住这一行的标题和折叠块，滚到中间，把命中的文字闪一下。
  reveal(line, query) {
    if (!view) return false;
    const doc = view.state.doc;
    const number = Math.min(Math.max(1, line), doc.lines);
    const target = doc.line(number);
    let from = target.from, to = target.to;
    const index = query ? target.text.toLocaleLowerCase().indexOf(query.toLocaleLowerCase()) : -1;
    if (index >= 0) { from = target.from + index; to = from + query.length; }
    const field = view.state.field(live, false);
    const effects = [];
    if (field) {
      for (const heading of field.headings) {
        if (heading.lineTo < from && from <= heading.end && folds.get(heading.key) === true) {
          folds.set(heading.key, false);
          post({kind: "fold", key: heading.key, value: false});
        }
      }
      for (const item of field.details) {
        const open = field.expanded.get(item.from) ?? folds.get(item.key) ?? item.initiallyOpen;
        if (!open && item.headerTo < from && from < item.to) effects.push(toggleDetails.of({from: item.from, open: true}));
      }
      effects.push(refold.of(null), flashEffect.of({from, to}));
    }
    effects.push(EditorView.scrollIntoView(from, {y: "center"}));
    view.dispatch({effects, selection: {anchor: from}});
    clearTimeout(window.flashTimer);
    window.flashTimer = setTimeout(() => view.dispatch({effects: flashEffect.of(null)}), 2400);
    return true;
  },
  // 工作板不再保留（关掉或很久没用）：丢掉存着的编辑器状态。
  forget(key) { savedBoards.delete(key); },
  undo() { runHistory(undo); return snapshot(); },
  redo() { runHistory(redo); return snapshot(); },
  history() { return {undo: undoDepth(view.state), redo: redoDepth(view.state)}; },
  // 测试用：现在的结构（打字时挪过来的）和对同样正文从头算的结构，两者应当一致。
  outline() {
    const summary = value => value && {
      headings: value.headings.map(heading => [heading.from, heading.lineTo, heading.end, heading.key]),
      details: value.details.map(item => [item.from, item.headerTo, item.closingFrom, item.to, item.key]),
      codes: value.blocks.codes.map(code => [code.from, code.to, code.closing]),
      quotes: value.blocks.quotes.map(quote => [quote.from, quote.to])};
    const fresh = EditorState.create({doc: view.state.doc, extensions: [markdown({base: markdownLanguage}), live]});
    return {current: summary(view.state.field(live, false)), fresh: summary(fresh.field(live))};
  },
  view() { return view; }
};
post({kind: "ready"});
