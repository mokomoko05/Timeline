import {EditorState, StateField, StateEffect, Compartment, Transaction, Annotation, Prec} from "@codemirror/state";
import {EditorView, Decoration, WidgetType, keymap, drawSelection, rectangularSelection} from "@codemirror/view";
import {defaultKeymap, history, historyKeymap, indentWithTab} from "@codemirror/commands";
import {markdown, markdownLanguage, markdownKeymap} from "@codemirror/lang-markdown";
import {syntaxTree, syntaxHighlighting, HighlightStyle, indentOnInput, bracketMatching} from "@codemirror/language";
import {tags} from "@lezer/highlight";
import {vim} from "@replit/codemirror-vim";

const post = payload => window.webkit?.messageHandlers.boardEditor.postMessage(payload);
const toggleDetails = StateEffect.define();
const resetDetails = StateEffect.define();
const external = Annotation.define();
const externalChange = external.of(true);
const vimMode = new Compartment();
const editable = new Compartment();
const livePreview = new Compartment();
let view;
let composing = false;
let currentVim, currentReadOnly, currentSourceMode;
let labels = {};
let copyRequest = 0;
const pendingCopies = new Map();

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
  const result = [], stack = [];
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
      stack.push({from: line.from, headerTo: doc.line(summaryLine).to,
                  title: decoded.value || "折叠内容", initiallyOpen: /\bopen(?:\s|=|$)/i.test(opening[1])});
    } else if (/^\s{0,3}<\/details>\s*$/i.test(line.text) && stack.length) {
      result.push({...stack.pop(), to: line.to, closingFrom: line.from});
    }
  }
  return result.sort((left, right) => left.from - right.from);
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
      if (view.state.readOnly) return;
      const marker = view.state.doc.sliceString(this.position, this.position + 1);
      view.dispatch({changes: {from: this.position, to: this.position + 1, insert: marker === " " ? "x" : " "},
                     annotations: Transaction.userEvent.of("input.task")});
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
    arrow.textContent = this.open ? "▼" : "▶";
    title.className = "title";
    title.textContent = this.item.title;
    button.append(arrow, title);
    button.addEventListener("mousedown", event => event.preventDefault());
    button.addEventListener("click", () => {
      const transaction = {effects: toggleDetails.of({from: this.item.from, open: !this.open})};
      const head = view.state.selection.main.head;
      if (this.open && head >= this.item.from && head <= this.item.to) {
        transaction.selection = {anchor: this.item.to < view.state.doc.length ? this.item.to + 1 : Math.max(0, this.item.from - 1)};
      }
      view.dispatch(transaction);
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

function decorations(state, details, expanded) {
  const ranges = [], hidden = [];
  const selection = state.selection.main;
  const active = state.readOnly ? null : state.doc.lineAt(selection.head).number;
  const overlapsSelection = (from, to) => selection.from <= to && selection.to >= from;
  const add = (from, to, decoration) => { if (from < to) ranges.push(decoration.range(from, to)); };
  const replace = (from, to, widget, block = false) => add(from, to, Decoration.replace({widget, block, atomic: true}));
  for (const item of details) {
    if (hidden.some(range => item.from >= range[0] && item.to <= range[1])) continue;
    const explicitlyClosed = expanded.get(item.from) === false;
    const headerActive = !explicitlyClosed && active != null && overlapsSelection(item.from, item.headerTo);
    let open = expanded.get(item.from) ?? item.initiallyOpen;
    if (!explicitlyClosed && (headerActive || (active != null && selection.head > item.headerTo && selection.head < item.closingFrom))) open = true;
    if (!headerActive) replace(item.from, item.headerTo, new DetailsWidget(item, open));
    if (!open) {
      replace(item.headerTo, item.to, undefined);
      hidden.push([item.headerTo, item.to]);
    } else {
      const closingLine = state.doc.lineAt(item.closingFrom).number;
      const previous = closingLine > 1 ? state.doc.line(closingLine - 1) : null;
      const closingFrom = previous && !previous.text.trim() ? previous.from - 1 : item.closingFrom;
      if (!overlapsSelection(closingFrom, item.to) || state.readOnly) replace(closingFrom, item.to, undefined);
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
  syntaxTree(state).iterate({enter(node) {
    if (concealed(node.from, node.to)) return false;
    const name = node.name;
    const line = state.doc.lineAt(node.from);
    const editing = active != null && state.doc.lineAt(node.to).number >= active && line.number <= active;
    if (/^ATXHeading[1-6]$/.test(name)) {
      ranges.push(Decoration.line({class: "cm-heading-" + name.slice(-1)}).range(line.from));
    }
    if (["FencedCode", "CodeBlock"].includes(name)) {
      for (let number = line.number; number <= state.doc.lineAt(node.to).number; number++) {
        ranges.push(Decoration.line({class: "cm-code"}).range(state.doc.line(number).from));
      }
      if (name === "FencedCode") {
        const firstBody = line.number < state.doc.lines ? state.doc.line(line.number + 1).from : node.to;
        const lastChild = node.node.lastChild;
        const end = lastChild?.name === "CodeMark" ? state.doc.lineAt(lastChild.from).from : node.to;
        ranges.push(Decoration.line({class: "cm-code-header"}).range(line.from));
        ranges.push(Decoration.widget({widget: new CopyCodeWidget(firstBody, Math.max(firstBody, end)), side: -1}).range(line.from));
      }
      return false;
    }
    if (name === "Blockquote") ranges.push(Decoration.line({class: "cm-quote"}).range(line.from));
    if (name === "StrongEmphasis") add(node.from, node.to, Decoration.mark({class: "cm-strong"}));
    if (name === "Emphasis") add(node.from, node.to, Decoration.mark({class: "cm-emphasis"}));
    if (name === "Strikethrough") add(node.from, node.to, Decoration.mark({class: "cm-strike"}));
    if (name === "InlineCode") add(node.from, node.to, Decoration.mark({class: "cm-code"}));
    if (["HeaderMark", "EmphasisMark", "CodeMark", "StrikethroughMark", "QuoteMark"].includes(name) && !editing) {
      const end = name === "HeaderMark" && state.doc.sliceString(node.to, node.to + 1) === " " ? node.to + 1 : node.to;
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
  return Decoration.set(ranges, true);
}

const live = StateField.define({
  create(state) {
    const tree = syntaxTree(state);
    const details = parseDetails(state.doc, tree);
    const expanded = new Map();
    return {tree, details, expanded, decorations: decorations(state, details, expanded)};
  },
  update(value, transaction) {
    let expanded = value.expanded;
    const changed = transaction.docChanged;
    if (changed) expanded = new Map([...expanded].map(([position, open]) => [transaction.changes.mapPos(position), open]));
    let effectsChanged = false;
    for (const effect of transaction.effects) {
      if (effect.is(toggleDetails)) {
        expanded = new Map(expanded);
        const item = value.details.find(item => item.from === effect.value.from);
        if (item) expanded.set(item.from, effect.value.open);
        effectsChanged = true;
      } else if (effect.is(resetDetails)) { expanded = new Map(); effectsChanged = true; }
    }
    const tree = syntaxTree(transaction.state);
    const parsed = tree !== value.tree;
    if (!changed && !transaction.selection && !effectsChanged && !parsed) return value;
    const details = changed || parsed ? parseDetails(transaction.state.doc, tree) : value.details;
    if (transaction.selection && !effectsChanged) {
      const head = transaction.state.selection.main.head;
      for (const item of details) {
        if (head >= item.from && head < item.to && expanded.get(item.from) === false) {
          expanded = new Map(expanded);
          expanded.set(item.from, true);
        }
      }
    }
    return {tree, details, expanded, decorations: decorations(transaction.state, details, expanded)};
  },
  provide: field => EditorView.decorations.from(field, value => value.decorations)
});

const highlighting = HighlightStyle.define([
  {tag: tags.processingInstruction, class: "cm-syntax"},
  {tag: tags.meta, class: "cm-syntax"},
  {tag: tags.contentSeparator, class: "cm-syntax"}
]);

function snapshot() {
  return {source: view.state.doc.toString(), anchor: view.state.selection.main.anchor,
          head: view.state.selection.main.head, composing: composing || view.composing};
}

window.boardEditor = {
  configure(config) {
    if (config.labels) labels = config.labels;
    if (!view) {
      view = new EditorView({parent: document.getElementById("editor"), state: EditorState.create({
        doc: config.source,
        selection: {anchor: config.readOnly ? 0 : config.source.length},
        extensions: [history(), drawSelection({cursorBlinkRate: 0}), rectangularSelection(), EditorView.lineWrapping,
          indentOnInput(), bracketMatching(), markdown({base: markdownLanguage}), syntaxHighlighting(highlighting),
          livePreview.of(config.sourceMode ? [] : live),
          EditorView.atomicRanges.of(view => view.state.field(live, false)?.decorations.update({filter: (_from, _to, decoration) => decoration.spec.atomic === true}) ?? Decoration.none),
          vimMode.of(config.vim ? Prec.highest(vim({status: true})) : []),
          editable.of([EditorState.readOnly.of(config.readOnly), EditorView.editable.of(!config.readOnly)]),
          keymap.of([...markdownKeymap, ...defaultKeymap, ...historyKeymap, indentWithTab]),
          Prec.lowest(EditorView.domEventHandlers({keydown(event) {
            if (event.key !== "Escape" || event.isComposing || composing || view.composing) return false;
            event.stopPropagation();
            return true;
          }})),
          EditorView.contentAttributes.of({"aria-label": "工作板 Markdown 内容", spellcheck: "false"}),
          EditorView.updateListener.of(update => {
            if (update.docChanged && !update.transactions.some(transaction => transaction.annotation(external))) {
              post({kind: "change", ...snapshot()});
            }
          }),
          EditorView.domEventHandlers({
            compositionstart() { composing = true; },
            compositionend() { composing = false; setTimeout(() => post({kind: "change", ...snapshot()}), 0); },
            blur() { post({kind: "commit", ...snapshot()}); },
            click(event) {
              const link = event.target.closest("[data-url]");
              if (link && (event.metaKey || view.state.readOnly)) { post({kind: "open", url: link.dataset.url}); return true; }
              return false;
            }
          })]
      })});
    } else {
      if (typeof config.source === "string" && config.source !== view.state.doc.toString() && !view.composing && !composing) {
        const old = view.state.selection.main;
        view.dispatch({changes: {from: 0, to: view.state.doc.length, insert: config.source},
                       selection: {anchor: Math.min(old.anchor, config.source.length), head: Math.min(old.head, config.source.length)},
                       annotations: [externalChange, Transaction.addToHistory.of(false)]});
      }
      const effects = [];
      if (currentVim !== config.vim) effects.push(vimMode.reconfigure(config.vim ? Prec.highest(vim({status: true})) : []));
      if (currentReadOnly !== config.readOnly) effects.push(editable.reconfigure([EditorState.readOnly.of(config.readOnly), EditorView.editable.of(!config.readOnly)]));
      if (currentSourceMode !== config.sourceMode) effects.push(livePreview.reconfigure(config.sourceMode ? [] : live));
      if (effects.length) view.dispatch({effects});
    }
    currentVim = config.vim;
    currentReadOnly = config.readOnly;
    currentSourceMode = config.sourceMode;
    if (config.colors) for (const [key, value] of Object.entries(config.colors)) document.documentElement.style.setProperty("--" + key, value);
    if (config.fontSize) document.documentElement.style.setProperty("--font-size", config.fontSize + "px");
    return snapshot();
  },
  snapshot,
  copyResult(request, success) {
    const button = pendingCopies.get(request);
    pendingCopies.delete(request);
    if (!button?.isConnected) return;
    const original = button.dataset.copyIcon || button.innerHTML;
    button.dataset.copyIcon = original;
    const label = labels.copyCode || "复制代码";
    const result = success ? (labels.copied || "已复制") : (labels.copyFailed || "复制失败，请重试");
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
  undo() { const command = historyKeymap.find(item => item.key === "Mod-z"); command?.run(view); return snapshot(); },
  redo() { const command = historyKeymap.find(item => item.key === "Mod-Shift-z"); command?.run(view); return snapshot(); },
  view() { return view; }
};
post({kind: "ready"});
