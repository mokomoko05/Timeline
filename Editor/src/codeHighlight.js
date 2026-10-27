// 代码块的语法高亮：和原生的 CodeHighlight.swift 同一套规则（就地编辑时代码的颜色和渲染好的正文一样）。
// 返回 [from, to, kind]，位置按 JavaScript 字符串（UTF-16）算，和 Swift 那边的 NSRange 一致。

const cKeywords = new Set(["if", "else", "for", "while", "do", "switch", "case", "default", "break", "continue", "return", "function", "func", "fn",
  "var", "let", "const", "class", "struct", "enum", "interface", "protocol", "extension", "impl", "trait", "type", "typealias",
  "import", "export", "from", "package", "using", "namespace", "public", "private", "protected", "internal", "fileprivate",
  "static", "final", "override", "virtual", "abstract", "async", "await", "try", "catch", "throw", "throws", "finally",
  "new", "delete", "this", "self", "super", "true", "false", "null", "nil", "undefined", "void", "in", "of", "is", "as",
  "guard", "defer", "where", "mut", "pub", "mod", "use", "match", "loop", "go", "chan", "select", "yield", "lambda",
  "int", "float", "double", "char", "bool", "boolean", "string", "long", "short", "unsigned", "signed", "auto", "inline",
  "template", "typename", "constexpr", "extern", "sizeof", "goto", "volatile", "val", "object", "when", "init", "deinit",
  "some", "any", "inout", "operator", "instanceof", "typeof", "readonly", "declare", "module", "require", "debugger"]);
const pythonKeywords = new Set(["def", "class", "if", "elif", "else", "for", "while", "return", "import", "from", "as", "with", "try", "except",
  "finally", "raise", "pass", "break", "continue", "lambda", "yield", "in", "is", "not", "and", "or", "None", "True",
  "False", "global", "nonlocal", "assert", "del", "async", "await", "self", "match", "case", "print"]);
const shellKeywords = new Set(["if", "then", "else", "elif", "fi", "for", "while", "do", "done", "case", "esac", "in", "function", "return", "export",
  "local", "echo", "cd", "sudo", "exit", "source", "alias", "set", "unset", "readonly", "until", "select", "time"]);
const rubyKeywords = new Set(["def", "end", "class", "module", "if", "elsif", "else", "unless", "while", "until", "for", "do", "return", "yield",
  "begin", "rescue", "ensure", "raise", "require", "include", "attr_accessor", "self", "nil", "true", "false", "and",
  "or", "not", "then", "case", "when", "puts", "lambda", "proc"]);
const sqlKeywords = new Set(["select", "from", "where", "and", "or", "not", "insert", "into", "values", "update", "set", "delete", "create", "table",
  "drop", "alter", "add", "index", "join", "left", "right", "inner", "outer", "on", "group", "by", "order", "having",
  "limit", "offset", "as", "distinct", "union", "all", "null", "is", "in", "like", "between", "case", "when", "then",
  "else", "end", "primary", "key", "foreign", "references", "default", "asc", "desc", "count", "sum", "avg", "max", "min", "with"]);
const jsonKeywords = new Set(["true", "false", "null"]);

function family(language) {
  switch ((language || "").toLowerCase().trim()) {
    case "python": case "py": case "python3": return "python";
    case "sh": case "bash": case "zsh": case "shell": case "console": case "fish": case "powershell": case "ps1": return "shell";
    case "ruby": case "rb": return "ruby";
    case "sql": case "mysql": case "postgresql": case "sqlite": return "sql";
    case "json": case "jsonc": case "json5": return "json";
    case "yaml": case "yml": case "toml": case "ini": return "yaml";
    case "html": case "xml": case "svg": case "vue": return "html";
    case "css": case "scss": case "less": return "css";
    case "text": case "txt": case "plain": case "plaintext": case "markdown": case "md": return "plain";
    default: return "cLike";
  }
}

function rules(family) {
  switch (family) {
    case "cLike": return {comment: String.raw`//[^\n]*|/\*[\s\S]*?\*/`, keywords: cKeywords};
    case "python": return {comment: String.raw`#[^\n]*`, keywords: pythonKeywords};
    case "shell": return {comment: String.raw`(?<![\w$])#[^\n]*`, keywords: shellKeywords};
    case "ruby": return {comment: String.raw`#[^\n]*`, keywords: rubyKeywords};
    case "sql": return {comment: String.raw`--[^\n]*|/\*[\s\S]*?\*/`, keywords: sqlKeywords, caseInsensitive: true};
    case "json": return {comment: null, keywords: jsonKeywords};
    case "yaml": return {comment: String.raw`#[^\n]*`, keywords: new Set([...jsonKeywords, "yes", "no", "on", "off"])};
    case "html": return {comment: String.raw`<!--[\s\S]*?-->`, keywords: new Set()};
    case "css": return {comment: String.raw`/\*[\s\S]*?\*/`, keywords: new Set()};
    default: return {comment: null, keywords: new Set()};
  }
}

const stringSource = String.raw`"""[\s\S]*?"""|'''[\s\S]*?'''|"(?:\\.|[^"\\\n])*"|'(?:\\.|[^'\\\n])*'|` + "`(?:\\\\.|[^`\\\\])*`";
const patterns = {
  number: String.raw`\b(?:0x[0-9a-fA-F_]+|\d[\d_]*(?:\.\d+)?(?:[eE][+-]?\d+)?)\b`,
  word: String.raw`[A-Za-z_$][\w$]*`,
  attribute: String.raw`@[A-Za-z_]\w*`,
  htmlTag: String.raw`<\/?[A-Za-z][\w:-]*|\/?>`,
  htmlAttribute: String.raw`\s([A-Za-z_:][\w:.-]*)(?==)`,
  cssProperty: String.raw`([A-Za-z-]+)\s*:`,
  yamlKey: String.raw`^\s*-?\s*([\w.-]+)\s*[:=]`,
  shellVariable: String.raw`\$\{?[A-Za-z_][\w]*\}?|(?<=\s)--?[A-Za-z][\w-]*`,
};

function* matches(pattern, text, flags = "g") {
  const regex = new RegExp(pattern, flags);
  for (let match; (match = regex.exec(text));) {
    if (match[0].length === 0) { regex.lastIndex++; continue; }
    yield match;
  }
}

// 匹配里某个分组的位置（没有 d 标志的老引擎上退回到在整个匹配里找）。
function groupRange(match, group) {
  if (match.indices) return match.indices[group] ?? null;
  const value = match[group];
  if (value == null) return null;
  const offset = match[0].lastIndexOf(value);
  return [match.index + offset, match.index + offset + value.length];
}

const cache = new Map();

export function codeTokens(code, language) {
  const key = (language || "") + "\u0000" + code;
  const cached = cache.get(key);
  if (cached) return cached;
  const result = scan(code, family(language));
  if (cache.size > 300) cache.clear();
  cache.set(key, result);
  return result;
}

function scan(code, family) {
  if (family === "plain" || !code) return [];
  const {comment, keywords, caseInsensitive} = rules(family);
  const tokens = [];
  const taken = new Uint8Array(code.length);
  const claim = (from, to, kind) => {
    if (to <= from) return;
    for (let index = from; index < to; index++) if (taken[index]) return;
    taken.fill(1, from, to);
    tokens.push([from, to, kind]);
  };
  // 注释和字符串合成一个表达式从左往右扫：先出现的算数。
  const strings = family === "html" ? String.raw`"[^"]*"|'[^']*'` : stringSource;
  const combined = (comment ? "(" + comment + ")|" : "()(?!)|") + "(" + strings + ")";
  for (const match of matches(combined, code)) claim(match.index, match.index + match[0].length, match[1] !== undefined ? "comment" : "string");
  const group = (pattern, flags = "gd") => {
    for (const match of matches(pattern, code, flags)) {
      const range = groupRange(match, 1);
      if (range) claim(range[0], range[1], "attribute");
    }
  };
  switch (family) {
    case "html":
      for (const match of matches(patterns.htmlTag, code)) claim(match.index, match.index + match[0].length, "keyword");
      group(patterns.htmlAttribute);
      break;
    case "css": group(patterns.cssProperty); break;
    case "yaml": case "json": group(patterns.yamlKey, "gmd"); break;
    case "shell":
      for (const match of matches(patterns.shellVariable, code)) claim(match.index, match.index + match[0].length, "attribute");
      break;
    default:
      for (const match of matches(patterns.attribute, code)) claim(match.index, match.index + match[0].length, "attribute");
  }
  for (const match of matches(patterns.number, code)) claim(match.index, match.index + match[0].length, "number");
  for (const match of matches(patterns.word, code)) {
    const word = match[0], from = match.index, to = from + word.length;
    if (keywords.has(caseInsensitive ? word.toLowerCase() : word)) { claim(from, to, "keyword"); continue; }
    if (code[to] === "(" && family !== "sql" && family !== "json" && family !== "yaml") claim(from, to, "function");
    else if (word.length > 1 && /^[A-Z]/.test(word) && (family === "cLike" || family === "python" || family === "ruby")) claim(from, to, "type");
  }
  return tokens.sort((a, b) => a[0] - b[0]);
}
