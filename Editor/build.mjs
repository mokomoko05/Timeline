import {build} from "esbuild";
import {copyFile, mkdir, readFile, readdir, rm, writeFile} from "node:fs/promises";
import {resolve} from "node:path";

const output = resolve("../Sources/Timeline/EditorAssets");
await build({entryPoints: ["src/editor.js"], bundle: true, minify: true, format: "iife", target: "safari16",
             outfile: resolve(output, "editor.js"), legalComments: "external"});
// KaTeX 单独放（工作板里出现公式时才加载）；字体只带 woff2。
const katex = resolve(output, "katex");
await rm(katex, {recursive: true, force: true});
await mkdir(resolve(katex, "fonts"), {recursive: true});
for (const name of ["katex.min.js", "katex.min.css"]) await copyFile(resolve("node_modules/katex/dist", name), resolve(katex, name));
for (const name of (await readdir("node_modules/katex/dist/fonts")).filter(name => name.endsWith(".woff2"))) {
  await copyFile(resolve("node_modules/katex/dist/fonts", name), resolve(katex, "fonts", name));
}
const lock = JSON.parse(await readFile("package-lock.json", "utf8"));
const notices = [];
for (const [path, entry] of Object.entries(lock.packages)) {
  if (!path || entry.dev) continue;
  const metadata = JSON.parse(await readFile(resolve(path, "package.json"), "utf8"));
  const files = (await readdir(path)).filter(name => /^(licen[sc]e|copying)(\.|$)/i.test(name));
  notices.push(`${metadata.name} ${metadata.version} (${metadata.license})\n${await Promise.all(files.map(name => readFile(resolve(path, name), "utf8"))).then(text => text.join("\n"))}`);
}
await writeFile(resolve(output, "THIRD_PARTY_LICENSES.txt"), notices.join("\n\n--------------------\n\n"));
