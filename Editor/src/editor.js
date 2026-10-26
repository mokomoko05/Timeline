import {EditorState, StateField, StateEffect, Compartment, Transaction, Annotation, Prec} from "@codemirror/state";
import {EditorView, Decoration, WidgetType, keymap, drawSelection, rectangularSelection} from "@codemirror/view";
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
// 浏览时点下的位置：画一根光标、淡淡铺亮这一行，进入编辑时光标就落在这里。
const setBrowseCaret = StateEffect.define();
const external = Annotation.define();
const externalChange = external.of(true);
const editable = new Compartment();
const livePreview = new Compartment();
let view;
let composing = false;
let currentReadOnly, currentSourceMode, currentPreviewOnly;
let labels = {};
let copyRequest = 0;
// 浏览时拖选的范围（不写进编辑器状态，免得打断系统原生选区）；进入编辑时变成编辑器的选区。
let browseRange = null;
let pointerDown = null;
// 浏览时这一次按键交给方向键命令移动光标（见 browseKeydown / browseCaret / browseKeyRange）。
let browseKeyPending = false;
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

class CopyCodeWidget extends WidgetType {
  constructor(from, to) { super(); this.from = from; this.to = to; }
  eq(other) { return this.from === other.from && this.to === other.to; }
  toDOM() {
    const button = actionButton("board-copy-code", labels.copyCode || "复制代码", '<rect x="5.5" y="5.5" width="8" height="8" rx="1.5"/><path d="M10.5 5.5v-2A1.5 1.5 0 0 0 9 2H3.5A1.5 1.5 0 0 0 2 3.5V9A1.5 1.5 0 0 0 3.5 10.5h2"/>');
    button.dataset.label = labels.copyCode || "复制代码";
    button.addEventListener("click", () => {
      const request = ++copyRequest;
      pendingCopies.set(request, button);
      post({kind: "copy", request, text: view.state.doc.sliceString(this.from, this.to)});
    });
    return button;
  }
  ignoreEvent() { return true; }
  destroy(button) {
    for (const [request, pending] of pendingCopies) if (pending === button) pendingCopies.delete(request);
  }
}

function parseDetails(doc, tree) {
  const excluded = [];
  tree.iterate({enter(node) {
    if (["FencedCode", "CodeBlock"].includes(node.name)) {
      excluded.push([node.from, node.to]);
      return false;
    }
  }});
  const result = [], stack = [], seen = new Map();
  let codeIndex = 0;
  for (let number = 1; number <= doc.lines; number++) {
    const line = doc.line(number);
    while (excluded[codeIndex]?.[1] < line.from) codeIndex++;
    if (excluded[codeIndex]?.[0] <= line.from && excluded[codeIndex][1] > line.from) continue;
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
      const decoded = document.createElement("textarea");
      decoded.innerHTML = title;
      const name = decoded.value || "折叠内容";
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
function parseHeadings(doc, tree, details) {
  const headings = [], seen = new Map();
  tree.iterate({enter(node) {
    if (["FencedCode", "CodeBlock"].includes(node.name)) return false;
    const match = /^ATXHeading([1-6])$/.exec(node.name);
    if (!match) return;
    const line = doc.lineAt(node.from);
    const text = line.text.replace(/^\s{0,3}#{1,6}\s*/, "").replace(/\s+#+\s*$/, "").trim();
    const level = Number(match[1]);
    const name = `h${level}:${text}`;
    const occurrence = seen.get(name) ?? 0;
    seen.set(name, occurrence + 1);
    const container = details.filter(item => item.from < line.from && line.from < item.closingFrom)
      .reduce((inner, item) => !inner || item.from > inner.from ? item : inner, null);
    headings.push({from: line.from, lineTo: line.to, level, key: `${name}#${occurrence}`, container});
    return false;
  }});
  for (let index = 0; index < headings.length; index++) {
    const heading = headings[index];
    const next = headings.slice(index + 1).find(item => item.container === heading.container && item.level <= heading.level);
    let boundary = heading.container ? heading.container.closingFrom : doc.length + 1;
    if (next && next.from < boundary) boundary = next.from;
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

// 浏览时的选区是不是方向键选出来的：只有这种才由编辑器自己铺颜色；鼠标拖出来的是系统原生选区，不能再往上叠装饰。
// 原生选区照常同步进编辑器（不能拦下：拦下后编辑器会把网页里的选区改回自己的，拖选时选区一直闪、选不住）；
// 浏览光标只跟方向键和点击走（见 browseCaret），收起 / 展开标题重画时不会被浏览器的选区带到开头去。
const browseKeyRange = StateField.define({
  create() { return false; },
  update(value, transaction) {
    if (!transaction.selection) return value;
    return transaction.state.readOnly && browseKeyPending && transaction.isUserEvent("select");
  }
});

const browseCaret = StateField.define({
  create() { return null; },
  update(value, transaction) {
    let explicit = false;
    for (const effect of transaction.effects) if (effect.is(setBrowseCaret)) { value = effect.value; explicit = true; }
    // 浏览时用方向键（以及 Home / End / 翻页）移动光标：光标跟着编辑器的选区走。
    // 鼠标拖选、重画后浏览器自己放的选区也会同步进编辑器，但不带动光标。
    if (!explicit && transaction.state.readOnly && transaction.isUserEvent("select") && browseKeyPending) value = transaction.state.selection.main.head;
    if (value != null && transaction.docChanged) value = transaction.changes.mapPos(value);
    if (value != null && !transaction.state.readOnly) value = null;
    return value;
  },
  // 光标用标记画在字的左边缘（行尾画在前一个字的右边缘，空行画在行首），不插进额外的元素，双击选词不受影响。
  // 按住 Shift 用方向键选出的范围也铺上选区的颜色。
  provide: field => EditorView.decorations.compute([field, browseKeyRange, "selection"], state => {
    const position = state.field(field);
    if (position == null) return Decoration.none;
    const line = state.doc.lineAt(position);
    const ranges = [];
    const selection = state.selection.main;
    if (state.readOnly && state.field(browseKeyRange) && !selection.empty && selection.head === position) {
      ranges.push(Decoration.mark({class: "cm-browse-range"}).range(selection.from, selection.to));
    }
    if (position < line.to) ranges.push(Decoration.mark({class: "cm-browse-caret"}).range(position, position + 1));
    else if (position > line.from) ranges.push(Decoration.mark({class: "cm-browse-caret cm-browse-caret-end"}).range(position - 1, position));
    ranges.unshift(Decoration.line({class: "cm-browse-line" + (line.length ? "" : " cm-browse-empty")}).range(line.from));
    return Decoration.set(ranges, true);
  })
});

// 浏览时松开鼠标：没有拖选就把光标放在点下的位置（点在可折叠的标题上同时收起 / 展开它）；拖选了就记下范围。
function browsePointerUp(event) {
  const start = pointerDown;
  pointerDown = null;
  if (!view?.state.readOnly || !start || event.button !== 0) return;
  if (event.target.closest?.("button, .board-check, .board-details, .board-open-link, .board-copy-code, [data-url]")) return;
  const selection = window.getSelection();
  const moved = Math.hypot(event.clientX - start.x, event.clientY - start.y) > 4;
  if (selection && !selection.isCollapsed && selection.rangeCount && view.contentDOM.contains(selection.anchorNode)) {
    try {
      const range = selection.getRangeAt(0);
      const from = view.posAtDOM(range.startContainer, range.startOffset), to = view.posAtDOM(range.endContainer, range.endOffset);
      const backward = selection.anchorNode === range.endContainer && selection.anchorOffset === range.endOffset && from !== to;
      browseRange = backward ? {anchor: to, head: from} : {anchor: from, head: to};
    } catch { browseRange = null; }
    if (view.state.field(browseCaret) != null) view.dispatch({effects: setBrowseCaret.of(null)});
    return;
  }
  if (moved || (event.detail > 1 && !event.target.closest?.(".cm-line.cm-foldable"))) return;
  browseRange = null;
  let position = view.posAtCoords({x: event.clientX, y: event.clientY});
  if (position == null) return;
  const clickedLine = event.target.closest?.(".cm-line");
  if (clickedLine) {
    try { position = Math.min(position, view.state.doc.lineAt(view.posAtDOM(clickedLine, 0)).to); } catch {}
  }
  const effects = [setBrowseCaret.of(position)];
  const lineElement = event.target.closest?.(".cm-line.cm-foldable");
  let toggledLine = null;
  if (lineElement) {
    // 收起的标题右边点下去，位置会落在被隐藏的那一节里：按点中的那一行找标题。
    const lineFrom = view.state.doc.lineAt(view.posAtDOM(lineElement, 0)).from;
    const heading = view.state.field(live, false)?.headings.find(item => item.from === lineFrom);
    if (heading) {
      const folded = folds.get(heading.key) === true;
      folds.set(heading.key, !folded);
      post({kind: "fold", key: heading.key, value: !folded});
      effects.push(refold.of(null));
      toggledLine = heading.from;
    }
  }
  if (toggledLine != null) keepInPlace(toggledLine, {effects, selection: {anchor: position}});
  else view.dispatch({effects, selection: {anchor: position}});
}

// 浏览时按方向键：还没有光标就先放在屏幕最上面那一行；有拖选的范围就从光标处重新开始，不接着旧的选区走。
function browseKeydown(event, view) {
  if (!view.state.readOnly || event.metaKey || event.ctrlKey || event.isComposing) return false;
  if (!/^(Arrow(Up|Down|Left|Right)|Home|End|PageUp|PageDown)$/.test(event.key)) return false;
  const caret = view.state.field(browseCaret);
  if (browseRange || window.getSelection()?.isCollapsed === false) {
    browseRange = null;
    window.getSelection()?.removeAllRanges();
  }
  if (caret == null) {
    const box = view.scrollDOM.getBoundingClientRect();
    const top = view.lineBlockAtHeight(Math.max(0, box.top - view.documentTop + 2)).from;
    view.dispatch({selection: {anchor: top}, effects: setBrowseCaret.of(top), scrollIntoView: true});
    event.preventDefault();
    return true;
  }
  const selection = view.state.selection.main;
  if (selection.head !== caret) view.dispatch({selection: {anchor: caret}});
  browseKeyPending = true;
  queueMicrotask(() => { browseKeyPending = false; });
  return false;
}


// 切换浏览 / 编辑 / 源码时，光标（或屏幕最上面那一行）留在屏幕上原来的高度，不会跳到别处去找不着。
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
  eq(other) { return this.item.from === other.item.from && this.item.title === other.item.title && this.open === other.open; }
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
      const transaction = {effects: [toggleDetails.of({from: this.item.from, open: !this.open})]};
      const head = view.state.selection.main.head;
      if (this.open && head >= this.item.from && head <= this.item.to) {
        transaction.selection = {anchor: this.item.to < view.state.doc.length ? this.item.to + 1 : Math.max(0, this.item.from - 1)};
      }
      keepInPlace(this.item.from, transaction);
    });
    button.addEventListener("dblclick", () => {
      if (view.state.readOnly) return;
      const line = view.state.doc.lineAt(this.item.headerTo);
      const offset = line.text.indexOf("<summary>") + "<summary>".length;
      view.dispatch({selection: {anchor: line.from + offset}, effects: toggleDetails.of({from: this.item.from, open: true}), scrollIntoView: true});
      view.focus();
    });
    return button;
  }
  ignoreEvent() { return true; }
}

function decorations(state, details, expanded, headings, flash) {
  const ranges = [], hidden = [];
  const selection = state.selection.main;
  const active = state.readOnly ? null : state.doc.lineAt(selection.head).number;
  const overlapsSelection = (from, to) => selection.from <= to && selection.to >= from;
  const add = (from, to, decoration) => { if (from < to) ranges.push(decoration.range(from, to)); };
  const replace = (from, to, widget, block = false) => add(from, to, Decoration.replace({widget, block, atomic: true}));
  // 标题和折叠块按位置依次处理：外层收起了，里面的就不再处理。标题在浏览和编辑时一样收起，
  // 切换时版面不变，光标留在屏幕上原来的地方。
  const foldables = [...details.map(item => ({item})), ...headings.map(heading => ({heading}))]
    .sort((left, right) => (left.item ?? left.heading).from - (right.item ?? right.heading).from);
  for (const {item, heading} of foldables) {
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
    if (hidden.some(range => item.from >= range[0] && item.to <= range[1])) continue;
    const remembered = expanded.get(item.from) ?? folds.get(item.key);
    const explicitlyClosed = remembered === false;
    const headerActive = !explicitlyClosed && active != null && overlapsSelection(item.from, item.headerTo);
    let open = remembered ?? item.initiallyOpen;
    if (!explicitlyClosed && (headerActive || (active != null && selection.head > item.headerTo && selection.head < item.closingFrom))) open = true;
    if (!headerActive) replace(item.from, item.headerTo, new DetailsWidget(item, open));
    if (!open) {
      replace(item.headerTo, item.to, undefined);
      hidden.push([item.headerTo, item.to]);
    } else {
      const closingLine = state.doc.lineAt(item.closingFrom).number;
      const previous = closingLine > 1 ? state.doc.line(closingLine - 1) : null;
      const closingFrom = previous && !previous.text.trim() ? previous.from - 1 : item.closingFrom;
      if (active == null || !overlapsSelection(closingFrom, item.to)) replace(closingFrom, item.to, undefined);
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
  // 引用：最外层引用占的行号范围，最后合成灰底的引用框。
  const quotes = [];
  syntaxTree(state).iterate({enter(node) {
    if (concealed(node.from, node.to)) return false;
    const name = node.name;
    const line = state.doc.lineAt(node.from);
    const editing = active != null && state.doc.lineAt(node.to).number >= active && line.number <= active;
    if (/^ATXHeading[1-6]$/.test(name)) {
      ranges.push(Decoration.line({class: "cm-heading-" + name.slice(-1)}).range(line.from));
    }
    if (["FencedCode", "CodeBlock"].includes(name)) {
      const lastLine = state.doc.lineAt(node.to).number;
      for (let number = line.number; number <= lastLine; number++) {
        const classes = "cm-code" + (number === line.number ? " cm-code-start" : "") + (number === lastLine ? " cm-code-end" : "");
        ranges.push(Decoration.line({class: classes}).range(state.doc.line(number).from));
      }
      if (name === "FencedCode") {
        const firstBody = line.number < state.doc.lines ? state.doc.line(line.number + 1).from : node.to;
        const lastChild = node.node.lastChild;
        const end = lastChild?.name === "CodeMark" ? state.doc.lineAt(lastChild.from).from : node.to;
        ranges.push(Decoration.line({class: "cm-code-header"}).range(line.from));
        ranges.push(Decoration.widget({widget: new CopyCodeWidget(firstBody, Math.max(firstBody, end)), side: -1}).range(line.from));
        if (state.readOnly || !editing) {
          // Keep the header for the copy action, but never expose fences or HTML examples as markup.
          // The hidden fence line shrinks to the block's top edge; the copy button floats in the corner.
          // An empty block keeps the row: the button is all there is to show.
          const closingLine = lastChild?.name === "CodeMark" && lastChild.from > line.from ? state.doc.lineAt(lastChild.from).number : lastLine + 1;
          if (closingLine - line.number - 1 > 0) {
            ranges.push(Decoration.line({class: "cm-code-header-concealed"}).range(line.from));
            ranges.push(Decoration.line({class: "cm-code-first"}).range(state.doc.line(line.number + 1).from));
          }
          replace(line.from, line.to, undefined);
          if (lastChild?.name === "CodeMark" && lastChild.from > line.from) {
            const closing = state.doc.lineAt(lastChild.from);
            replace(closing.from, closing.to, undefined);
            ranges.push(Decoration.line({class: "cm-code-footer"}).range(closing.from));
          }
        }
      }
      return false;
    }
    if (name === "Blockquote" && !quotes.some(range => line.number <= range[1])) {
      quotes.push([line.number, state.doc.lineAt(Math.max(node.from, node.to - 1)).number]);
    }
    if (name === "StrongEmphasis") add(node.from, node.to, Decoration.mark({class: "cm-strong"}));
    if (name === "Emphasis") add(node.from, node.to, Decoration.mark({class: "cm-emphasis"}));
    if (name === "Strikethrough") add(node.from, node.to, Decoration.mark({class: "cm-strike"}));
    if (name === "InlineCode") add(node.from, node.to, Decoration.mark({class: "cm-code"}));
    if (["HeaderMark", "EmphasisMark", "CodeMark", "StrikethroughMark", "QuoteMark"].includes(name) && !editing) {
      const end = (name === "HeaderMark" || name === "QuoteMark") && state.doc.sliceString(node.to, node.to + 1) === " " ? node.to + 1 : node.to;
      replace(node.from, end, undefined);
    }
    if (name === "TaskMarker") {
      const checked = /[xX]/.test(state.doc.sliceString(node.from, node.to));
      if (checked) add(node.to, line.to, Decoration.mark({class: "cm-task-done"}));
      const start = line.text.search(/\[[ xX]\]/);
      if (start >= 0) replace(line.from + start, line.from + start + 3, new CheckWidget(checked, line.from + start + 1));
    }
    if (name === "ListMark" && /^\s*[-+*]\s+\[[ xX]\]/.test(line.text)) replace(node.from, node.to + 1, undefined);
    if (name === "Link") {
      const destination = node.node.getChild("URL");
      const closing = node.node.getChildren("LinkMark").find(mark => state.doc.sliceString(mark.from, mark.to) === "]");
      if (destination && closing) {
        const decoded = document.createElement("textarea");
        decoded.innerHTML = state.doc.sliceString(destination.from, destination.to).replace(/^<|>$/g, "").replace(/\\([!"#$%&'()*+,\-./:;<=>?@[\]\\^_`{|}~])/g, "$1");
        const url = decoded.value;
        add(node.from + 1, closing.from,
            Decoration.mark({class: "cm-link", attributes: {"data-url": url}}));
        ranges.push(Decoration.widget({widget: new OpenLinkWidget(url), side: 1}).range(node.to));
        if (!editing) {
          replace(node.from, node.from + 1, undefined);
          replace(closing.from, node.to, undefined);
        }
      }
    }
  }});
  // 一个引用的每一行都铺底色，只有第一行、最后一行是框的上下边；隔着空行的两段引用是两块，空行不铺。
  for (const [first, last] of quotes) {
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

const live = StateField.define({
  create(state) {
    const tree = syntaxTree(state);
    const details = parseDetails(state.doc, tree);
    const headings = parseHeadings(state.doc, tree, details);
    const expanded = new Map();
    return {tree, details, headings, expanded, flash: null, decorations: decorations(state, details, expanded, headings, null)};
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
    const modeChanged = transaction.startState.readOnly !== transaction.state.readOnly;
    // 浏览时选区不影响版面（拖选时每动一下都会来一次）：只有选区变了就不重算。
    if (!changed && !effectsChanged && !parsed && !modeChanged && (!transaction.selection || transaction.state.readOnly)) return value;
    const details = changed || parsed ? parseDetails(transaction.state.doc, tree) : value.details;
    const headings = changed || parsed ? parseHeadings(transaction.state.doc, tree, details) : value.headings;
    if ((transaction.selection || changed) && !transaction.state.readOnly) {
      // 编辑时光标进了收起的标题下面（比如在收起的标题末尾回车）：展开这一节，不在看不见的地方打字。
      const head = transaction.state.selection.main.head;
      for (const heading of headings) {
        if (head > heading.lineTo && head <= heading.end && folds.get(heading.key) === true) {
          folds.set(heading.key, false);
          post({kind: "fold", key: heading.key, value: false});
        }
      }
    }
    if (transaction.selection && !effectsChanged && !transaction.state.readOnly) {
      const head = transaction.state.selection.main.head;
      for (const item of details) {
        if (head >= item.from && head < item.to && expanded.get(item.from) === false) {
          expanded = new Map(expanded);
          expanded.set(item.from, true);
        }
      }
    }
    return {tree, details, headings, expanded, flash, decorations: decorations(transaction.state, details, expanded, headings, flash)};
  },
  provide: field => EditorView.decorations.from(field, value => value.decorations)
});

const highlighting = HighlightStyle.define([
  {tag: tags.processingInstruction, class: "cm-syntax"},
  {tag: tags.meta, class: "cm-syntax"},
  {tag: tags.contentSeparator, class: "cm-syntax"}
]);

// 浏览（只读预览）时也能撤销：勾掉的待办、刚保存的修改都能用 ⌘Z 找回。CodeMirror 的撤销命令在只读状态下不执行，
// 这里临时放开可编辑，执行完立刻恢复；切换可编辑不进撤销历史。数据本身只读（没有写入权限）时不撤销。
function runHistory(command) {
  if (!view || currentReadOnly) return false;
  const locked = view.state.readOnly;
  if (locked) view.dispatch({effects: editable.reconfigure(editability(false))});
  const done = command(view);
  if (locked) view.dispatch({effects: editable.reconfigure(editability(true))});
  return done;
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
  return {source: view.state.doc.toString(), anchor: view.state.selection.main.anchor,
          head: view.state.selection.main.head, composing: composing || view.composing};
}

function editorExtensions(config) {
  return [history(), drawSelection({cursorBlinkRate: 0}), rectangularSelection(), EditorView.lineWrapping,
          indentOnInput(), bracketMatching(), markdown({base: markdownLanguage}), syntaxHighlighting(highlighting),
          livePreview.of(config.sourceMode ? [] : live), browseCaret, browseKeyRange,
          EditorView.atomicRanges.of(view => view.state.field(live, false)?.decorations.update({filter: (_from, _to, decoration) => decoration.spec.atomic === true}) ?? Decoration.none),
          editable.of(editability(config.readOnly || config.previewOnly)),
          // 撤销 / 重做在浏览和编辑时都可用；没有可撤销的也吞掉按键，不落到应用别处的撤销上。
          Prec.highest(keymap.of([
            {key: "Mod-z", run: () => { runHistory(undo); return true; }, preventDefault: true},
            {key: "Mod-Shift-z", run: () => { runHistory(redo); return true; }, preventDefault: true},
            {key: "Mod-y", run: () => { runHistory(redo); return true; }, preventDefault: true}
          ])),
          // ⌘Enter 是全应用统一的保存键：提交内容并回到只读浏览。
          Prec.highest(keymap.of([{key: "Mod-Enter", run: view => {
            if (view.state.readOnly || composing || view.composing) return false;
            post({kind: "commit", ...snapshot()});
            post({kind: "preview"});
            return true;
          }}])),
          Prec.highest(EditorView.domEventHandlers({keydown: browseKeydown})),
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
            if (update.docChanged && !update.transactions.some(transaction => transaction.annotation(external))) {
              post({kind: "change", ...snapshot()});
            }
          }),
          EditorView.domEventHandlers({
            // 浏览时复制系统原生选区里看到的文字（CodeMirror 自己的选区在只读时不跟随拖选）。
            copy(event, view) {
              if (!view.state.readOnly) return false;
              const text = window.getSelection()?.toString() ?? "";
              if (!text) return false;
              event.clipboardData?.setData("text/plain", text);
              event.preventDefault();
              return true;
            },
            compositionstart() { composing = true; },
            compositionend() { composing = false; setTimeout(() => post({kind: "change", ...snapshot()}), 0); },
            blur() { post({kind: "commit", ...snapshot()}); },
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
  return EditorState.create({doc: config.source ?? "", selection: {anchor: config.readOnly ? 0 : (config.source ?? "").length},
                             extensions: editorExtensions(config)});
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
// 折叠块的展开、浏览光标）和滚动位置存起来，换回来时原样恢复。只留最近用过的几块。
const savedBoards = new Map();
const savedBoardLimit = 8;
let currentKey = null;

function switchBoard(config) {
  if (currentKey != null) {
    savedBoards.delete(currentKey);
    savedBoards.set(currentKey, {state: view.state, scroll: view.scrollDOM.scrollTop, browseRange});
    while (savedBoards.size > savedBoardLimit) savedBoards.delete(savedBoards.keys().next().value);
  }
  setBottomSlack(0);
  const saved = savedBoards.get(config.key);
  savedBoards.delete(config.key);
  currentKey = config.key;
  loadFolds(config.folds);
  browseRange = saved?.browseRange ?? null;
  view.setState(saved?.state ?? freshState(config));
  // 恢复的状态里模式可能和现在不同：按这次的配置重新设一遍，折叠按这块工作板的记忆重算。
  const browsing = !!(config.readOnly || config.previewOnly);
  view.dispatch({effects: [editable.reconfigure(editability(browsing)), livePreview.reconfigure(config.sourceMode ? [] : live), refold.of(null)]});
  currentReadOnly = config.readOnly;
  currentPreviewOnly = config.previewOnly;
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
      // 浏览（只读）时交给系统原生选区：CodeMirror 的鼠标选择在渲染后的标题、折叠块和浮动按钮附近
      // 算出的位置和看到的文字不一致，拖选会错位。捕获阶段截住按下事件、不阻止默认行为，
      // 原生选区照常工作，CodeMirror 不再另算一份选区。按钮类控件不受影响。
      view.dom.addEventListener("mousedown", event => {
        if (!view.state.readOnly || event.button !== 0) return;
        if (event.target.closest?.("button, .board-check, .board-details, .board-open-link, .board-copy-code")) return;
        pointerDown = {x: event.clientX, y: event.clientY};
        // 可折叠的标题上连续快点：每一下都是一次收起 / 展开，不让第二下变成双击选词。
        if (event.detail > 1 && event.target.closest?.(".cm-line.cm-foldable")) event.preventDefault();
        event.stopPropagation();
      }, true);
      view.dom.addEventListener("mouseup", browsePointerUp);
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
      const wasBrowsing = !!(currentReadOnly || currentPreviewOnly), browsing = !!(config.readOnly || config.previewOnly);
      if (wasBrowsing !== browsing) effects.push(editable.reconfigure(editability(browsing)));
      if (currentSourceMode !== config.sourceMode) effects.push(livePreview.reconfigure(config.sourceMode ? [] : live));
      if (effects.length) {
        const caret = view.state.field(browseCaret);
        const transaction = {effects};
        if (wasBrowsing && !browsing) {
          // 进入编辑：浏览时点下的位置或拖选（按 Shift 用方向键选）的范围变成编辑器的光标 / 选区。
          const selection = view.state.selection.main;
          const keyboardRange = caret != null && !selection.empty && selection.head === caret ? {anchor: selection.anchor, head: selection.head} : null;
          transaction.selection = browseRange ?? keyboardRange ?? {anchor: caret ?? selection.head};
        } else if (!wasBrowsing && browsing) {
          // 回到浏览：在刚才编辑的地方留一根光标。
          effects.push(setBrowseCaret.of(view.state.selection.main.head));
        }
        const anchor = captureAnchor(browseRange?.head ?? caret ?? view.state.selection.main.head);
        browseRange = null;
        view.dispatch(transaction);
        restoreAnchor(anchor);
        if (wasBrowsing && !browsing) view.focus();
      }
    }
    currentReadOnly = config.readOnly;
    currentPreviewOnly = config.previewOnly;
    currentSourceMode = config.sourceMode;
    view.dom.dataset.preview = String(!!(config.readOnly || config.previewOnly));
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
    post({kind: "commit", ...snapshot()});
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
  view() { return view; }
};
post({kind: "ready"});
