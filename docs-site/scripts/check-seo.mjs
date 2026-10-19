import { readFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { ORIGIN, decodeEntities, listFiles, localUrl, readHtml, readSitemaps, resolveFile, routeFor } from "./seo-files.mjs";

function checkGraph(page, problems) {
  const graph = [];
  for (const tag of page.tags.filter((tag) => tag.name === "script" && tag.attributes.type === "application/ld+json")) {
    try {
      const data = JSON.parse(tag.text);
      const blocks = Array.isArray(data) ? data : [data];
      for (const block of blocks) {
        if (!block || typeof block !== "object") throw new Error("expected a JSON-LD object");
        graph.push(...(block["@graph"] ?? [block]));
      }
    } catch (error) { problems.push(`${page.route}: invalid JSON-LD: ${error.message}`); }
  }
  const hasType = (node, type) => node && [node["@type"]].flat().includes(type);
  if (page.indexable && page.route.startsWith("/docs/")) {
    for (const type of ["TechArticle", "BreadcrumbList"]) {
      if (!graph.some((node) => hasType(node, type))) problems.push(`${page.route}: missing ${type} JSON-LD`);
    }
  }
  for (const node of graph.filter((node) => hasType(node, "BreadcrumbList"))) {
    if (!Array.isArray(node.itemListElement) || node.itemListElement.length === 0) {
      problems.push(`${page.route}: empty BreadcrumbList`);
      continue;
    }
    for (const [index, crumb] of node.itemListElement.entries()) {
      if (!crumb || crumb.position !== index + 1 || !crumb.name) problems.push(`${page.route}: invalid breadcrumb position/name`);
      const item = typeof crumb?.item === "string" ? crumb.item : crumb?.item?.["@id"];
      if (index < node.itemListElement.length - 1 || item !== undefined) {
        try { localUrl(item); }
        catch { problems.push(`${page.route}: breadcrumb ${index + 1} needs a canonical item URL`); }
      }
    }
  }
}

export function auditSite(root) {
  const files = new Set(listFiles(root));
  const problems = [];
  const pages = new Map();
  for (const file of [...files].filter((file) => file.endsWith(".html"))) {
    const tags = readHtml(readFileSync(join(root, file), "utf8"));
    const meta = (name) => tags.filter((tag) => tag.name === "meta" && (tag.attributes.name ?? tag.attributes.property)?.toLowerCase() === name).map((tag) => tag.attributes.content ?? "");
    const refresh = tags.find((tag) => tag.name === "meta" && tag.attributes["http-equiv"]?.toLowerCase() === "refresh");
    const noindex = meta("robots").concat(meta("googlebot")).some((value) => /(?:^|[\s,])(noindex|none)(?:$|[\s,])/i.test(value));
    const error = /(?:^|\/)404(?:\.html|\/index\.html)$/.test(file);
    pages.set(file, { file, route: routeFor(file), tags, meta, refresh, noindex, error, indexable: !refresh && !noindex && !error, ids: new Set(tags.map((tag) => tag.attributes.id).filter(Boolean)) });
  }
  if (pages.size === 0) problems.push("build: no HTML pages found");
  const titles = new Map();
  const descriptions = new Map();
  let links = 0;
  for (const page of pages.values()) {
    const fail = (message) => problems.push(`${page.route}: ${message}`);
    const canonicals = page.tags.filter((tag) => tag.name === "link" && tag.attributes.rel?.toLowerCase().split(/\s+/).includes("canonical")).map((tag) => tag.attributes.href);
    if (canonicals.length !== 1) fail(`expected one canonical, found ${canonicals.length}`);
    for (const canonical of canonicals) {
      try { localUrl(canonical); }
      catch (error) { fail(error.message); }
    }
    if (page.indexable && canonicals[0] !== `${ORIGIN}${page.route}`) fail(`canonical is not self-referencing: ${canonicals[0]}`);
    if (page.error && !page.noindex) fail("404 must declare noindex");
    if (page.refresh) {
      const target = page.refresh.attributes.content?.match(/^\s*\d+(?:\.\d+)?\s*;\s*url\s*=\s*["']?([^"']+)["']?\s*$/i)?.[1];
      try {
        const url = new URL(target ?? "", `${ORIGIN}${page.route}`);
        const targetPage = pages.get(resolveFile(localUrl(`${url.origin}${url.pathname}`).pathname, files));
        if (!target || !targetPage || targetPage.refresh || targetPage.error) fail(`redirect target does not resolve directly to a content page: ${target}`);
        if (canonicals[0] !== `${url.origin}${url.pathname}`) fail("redirect canonical differs from refresh target");
      } catch (error) { fail(`invalid redirect: ${error.message}`); }
    } else {
      const title = page.tags.filter((tag) => tag.name === "title").map((tag) => decodeEntities(tag.text).trim());
      const description = page.meta("description");
      for (const [name, values] of [["title", title], ["description", description]]) {
        if (values.length !== 1 || !values[0]?.trim()) fail(`expected one nonempty ${name}, found ${values.length}`);
      }
      const headings = page.tags.filter((tag) => tag.name === "h1");
      if (headings.length !== 1) fail(`expected one h1, found ${headings.length}`);
      if (page.indexable) {
        for (const [label, map, value] of [["title", titles, title[0]], ["description", descriptions, description[0]?.trim()]]) {
          if (map.has(value)) fail(`duplicate ${label} with ${map.get(value)}`);
          else map.set(value, page.route);
        }
        const images = page.meta("og:image");
        if (images.length !== 1) fail(`expected one og:image, found ${images.length}`);
        for (const image of images) {
          try { if (!resolveFile(localUrl(image).pathname, files)) fail(`missing og:image file: ${image}`); }
          catch (error) { fail(`invalid og:image: ${error.message}`); }
        }
      }
    }
    checkGraph(page, problems);
    for (const tag of page.tags) {
      if (tag.name === "img" && !("alt" in tag.attributes)) fail(`img missing alt: ${tag.attributes.src}`);
      if (tag.name !== "a" || !("href" in tag.attributes)) continue;
      const href = tag.attributes.href;
      if (!href || /^(?:mailto:|tel:|javascript:|data:)/i.test(href)) continue;
      try {
        const target = new URL(href, `${ORIGIN}${page.route}`);
        if (target.origin !== ORIGIN) continue;
        links++;
        const file = href.startsWith("#") ? page.file : resolveFile(target.pathname, files);
        if (!file) fail(`broken internal link: ${href}`);
        else if (target.hash && pages.has(file) && !pages.get(file).ids.has(decodeURIComponent(target.hash.slice(1)).split(":~:text=")[0]) && !target.hash.startsWith("#:~:text=")) fail(`broken internal anchor: ${href}`);
      } catch (error) { fail(`invalid internal link ${href}: ${error.message}`); }
    }
  }
  const sitemap = readSitemaps(root, files, problems);
  for (const [value, count] of sitemap.urls) {
    if (count !== 1) problems.push(`sitemap: URL occurs ${count} times: ${value}`);
    try {
      const file = resolveFile(localUrl(value).pathname, files);
      if (!file) problems.push(`sitemap: URL has no built file: ${value}`);
      else if (pages.has(file) && (!pages.get(file).indexable || value !== `${ORIGIN}${pages.get(file).route}`)) problems.push(`sitemap: nonindexable or noncanonical HTML URL: ${value}`);
    } catch (error) { problems.push(`sitemap: ${error.message}`); }
  }
  for (const page of pages.values()) {
    if (page.indexable && sitemap.urls.get(`${ORIGIN}${page.route}`) !== 1) problems.push(`${page.route}: canonical indexable page must occur exactly once in sitemap`);
  }
  return { htmlPages: pages.size, indexablePages: [...pages.values()].filter((page) => page.indexable).length, redirects: [...pages.values()].filter((page) => page.refresh).length, sitemapFiles: sitemap.files, sitemapUrls: sitemap.urls.size, internalLinks: links, problems };
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const result = auditSite(resolve(process.argv[2] ?? fileURLToPath(new URL("../dist", import.meta.url))));
    console.log(JSON.stringify(result, null, 2));
    process.exitCode = result.problems.length ? 1 : 0;
  } catch (error) {
    console.error(`check-seo: ${error.message}`);
    process.exitCode = 1;
  }
}
