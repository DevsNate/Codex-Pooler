import { readdirSync, readFileSync } from "node:fs";
import { join, posix } from "node:path";

export const ORIGIN = "https://www.codex-pooler.com";

export function decodeEntities(value) {
  const named = { amp: "&", quot: '"', apos: "'", lt: "<", gt: ">", nbsp: " " };
  return value.replace(/&(#x[\da-f]+|#\d+|amp|quot|apos|lt|gt|nbsp);/gi, (entity, code) => {
    if (!code.startsWith("#")) return named[code.toLowerCase()];
    const point = code[1].toLowerCase() === "x" ? Number.parseInt(code.slice(2), 16) : Number(code.slice(1));
    return point > 0 && point <= 0x10ffff ? String.fromCodePoint(point) : entity;
  });
}

export function listFiles(directory, prefix = "") {
  return readdirSync(directory, { withFileTypes: true }).flatMap((entry) => {
    const path = posix.join(prefix, entry.name);
    return entry.isDirectory() ? listFiles(join(directory, entry.name), path) : [path];
  });
}

// This tokenizer reads generated static HTML. Quoted attributes and raw-text
// elements are consumed together, so markup in scripts is never counted as DOM.
export function readHtml(html) {
  const tags = [];
  const pattern = /<!--[\s\S]*?-->|<(script|style|title|textarea)\b((?:[^>"']|"[^"]*"|'[^']*')*)>([\s\S]*?)<\/\1\s*>|<([a-z][\w:-]*)\b((?:[^>"']|"[^"]*"|'[^']*')*)>/gi;
  for (const match of html.matchAll(pattern)) {
    if (match[0].startsWith("<!--")) continue;
    const attributes = Object.create(null);
    for (const attr of (match[2] ?? match[5]).matchAll(/([^\s=/>]+)(?:\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+)))?/g)) {
      attributes[attr[1].toLowerCase()] = decodeEntities(attr[2] ?? attr[3] ?? attr[4] ?? "");
    }
    tags.push({ name: (match[1] ?? match[4]).toLowerCase(), attributes, text: match[3] ?? "" });
  }
  return tags;
}

export function routeFor(file) {
  return `/${file.replace(/(?:^|\/)index\.html$/, "/").replace(/^\//, "")}`;
}

export function resolveFile(pathname, files) {
  const path = decodeURIComponent(pathname).replace(/^\/+/, "");
  const candidates = pathname.endsWith("/") ? [`${path}index.html`] : [path, `${path}/index.html`, `${path}.html`];
  return candidates.find((file) => files.has(file));
}

export function localUrl(value) {
  const url = new URL(value);
  if (url.origin !== ORIGIN || url.username || url.password || url.search || url.hash) {
    throw new Error(`expected an absolute canonical URL under ${ORIGIN}: ${value}`);
  }
  return url;
}

export function readSitemaps(root, files, problems) {
  const urls = new Map();
  const visited = new Set();
  const visiting = new Set();
  const visit = (value) => {
    let file;
    try { file = resolveFile(localUrl(value).pathname, files); }
    catch (error) { problems.push(`sitemap: ${error.message}`); return; }
    if (!file?.endsWith(".xml")) { problems.push(`sitemap: missing XML file ${value}`); return; }
    if (visiting.has(file)) { problems.push(`sitemap: cyclic index ${value}`); return; }
    if (visited.has(file)) return;
    visiting.add(file);
    const xml = readFileSync(join(root, file), "utf8");
    const index = /<sitemapindex\b/.test(xml);
    if (!index && !/<urlset\b/.test(xml)) problems.push(`${file}: expected sitemapindex or urlset`);
    const entries = [...xml.matchAll(/<loc\b[^>]*>([^<]*)<\/loc>/g)].map((match) => decodeEntities(match[1].trim()));
    if (entries.length === 0) problems.push(`${file}: empty sitemap`);
    for (const entry of entries) {
      if (index) visit(entry);
      else urls.set(entry, (urls.get(entry) ?? 0) + 1);
    }
    visiting.delete(file);
    visited.add(file);
  };
  if (!files.has("robots.txt")) problems.push("robots.txt: missing file");
  else {
    const robots = readFileSync(join(root, "robots.txt"), "utf8");
    const declarations = [...robots.matchAll(/^\s*Sitemap:\s*(\S+)/gim)];
    if (declarations.length === 0) problems.push("robots.txt: no Sitemap declaration");
    for (const declaration of declarations) visit(declaration[1]);
  }
  return { urls, files: visited.size };
}
