import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";
import { auditSite } from "./check-seo.mjs";

const origin = "https://www.codex-pooler.com";
const graph = {
  "@context": "https://schema.org",
  "@graph": [
    { "@type": "TechArticle" },
    { "@type": "BreadcrumbList", itemListElement: [{ "@type": "ListItem", position: 1, name: "Home", item: `${origin}/` }, { "@type": "ListItem", position: 2, name: "Guide" }] },
  ],
};

function html(route, extra = {}) {
  return `<!doctype html><html><head><title>${extra.title ?? route}</title>
    <link href="${extra.canonical ?? origin + route}" rel="canonical">
    <meta content="${extra.description ?? `About ${route}`}" name="description">
    <meta content="${origin}/card.jpg" property="og:image">
    ${extra.noindex ? '<meta name="robots" content="noindex, follow">' : ""}
    <script type="application/ld+json">${JSON.stringify(graph)}</script>
    </head><body><h1>Guide</h1><p id="intro">Introduction</p><p id="a&amp;b">Details</p>
    <img src="/card.jpg" alt=""><a href="/docs/guide/#intro">Guide</a>${extra.body ?? ""}</body></html>`;
}

function fixture(t, changes = {}) {
  const root = mkdtempSync(join(tmpdir(), "site-seo-"));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  const files = {
    "index.html": html("/"),
    "docs/guide/index.html": html("/docs/guide/"),
    "card.jpg": "fixture image",
    "robots.txt": `User-agent: *\nAllow: /\nSitemap: ${origin}/sitemap-index.xml\nSitemap: ${origin}/sitemap.xml\n`,
    "sitemap-index.xml": `<sitemapindex><sitemap><loc>${origin}/sitemap.xml</loc></sitemap></sitemapindex>`,
    "sitemap.xml": sitemap(["/", "/docs/guide/"]),
    ...changes,
  };
  for (const [path, contents] of Object.entries(files)) {
    if (contents === null) continue;
    mkdirSync(dirname(join(root, path)), { recursive: true });
    writeFileSync(join(root, path), contents);
  }
  return root;
}

function sitemap(paths) {
  return `<urlset>${paths.map((path) => `<url><loc>${origin}${path}</loc></url>`).join("")}</urlset>`;
}

const redirect = `<html><head><meta http-equiv="refresh" content="0;url=${origin}/docs/guide/"><meta name="robots" content="noindex"><link rel="canonical" href="${origin}/docs/guide/"></head><body><a href="/docs/guide/">Continue</a></body></html>`;

test("accepts a complete sitemap and encoded internal anchors when the build is valid", (t) => {
  // Given real generated files, including script text that resembles HTML.
  const root = fixture(t, { "index.html": html("/", { body: '<script>const sample = "<h1>not DOM</h1><img>";</script><!-- <h1>comment</h1> --><a href="/docs/guide/#a%26b">Details</a>' }) });
  // When the actual output directory is audited.
  const result = auditSite(root);
  // Then repeated index/direct sitemap references do not duplicate its URLs.
  assert.deepEqual(result.problems, []);
  assert.equal(result.indexablePages, 2);
  assert.equal(result.sitemapUrls, 2);
});

test("accepts intentional noindex content, 404, and redirect stubs outside the sitemap", (t) => {
  const root = fixture(t, {
    "404.html": html("/404/", { noindex: true }),
    "docs/moved/index.html": html("/docs/moved/", { noindex: true }),
    "old/index.html": redirect,
  });
  const result = auditSite(root);
  assert.deepEqual(result.problems, []);
  assert.equal(result.htmlPages, 5);
  assert.equal(result.indexablePages, 2);
  assert.equal(result.redirects, 1);
});

const regressions = [
  ["canonical origin", { "index.html": html("/", { canonical: "https://example.com/" }) }, /expected an absolute canonical URL/],
  ["canonical path", { "index.html": html("/", { canonical: `${origin}/docs/guide/` }) }, /canonical is not self-referencing/],
  ["duplicate canonicals", { "index.html": html("/", { body: `<link rel="canonical" href="${origin}/">` }) }, /expected one canonical/],
  ["duplicate titles", { "docs/guide/index.html": html("/docs/guide/", { title: "/" }) }, /duplicate title/],
  ["duplicate descriptions", { "docs/guide/index.html": html("/docs/guide/", { description: "About /" }) }, /duplicate description/],
  ["extra h1", { "index.html": html("/", { body: "<h1>Second</h1>" }) }, /expected one h1/],
  ["missing description", { "index.html": html("/").replace(/<meta content="About \/" name="description">/, "") }, /expected one nonempty description/],
  ["missing social card", { "card.jpg": null }, /missing og:image file/],
  ["missing image alt", { "index.html": html("/", { body: "<img src='/card.jpg'>" }) }, /img missing alt/],
  ["missing root-relative page", { "index.html": html("/", { body: '<a href="/missing/">Missing</a>' }) }, /broken internal link/],
  ["missing absolute same-origin page", { "index.html": html("/", { body: `<a href="${origin}/missing/">Missing</a>` }) }, /broken internal link/],
  ["missing anchor", { "index.html": html("/", { body: '<a href="/docs/guide/#absent">Missing</a>' }) }, /broken internal anchor/],
  ["malformed percent escape", { "index.html": html("/", { body: '<a href="/docs/%zz/">Missing</a>' }) }, /invalid internal link/],
  ["missing sitemap entry", { "sitemap.xml": sitemap(["/"]) }, /canonical indexable page must occur exactly once/],
  ["duplicate sitemap entry", { "sitemap.xml": sitemap(["/", "/", "/docs/guide/"]) }, /URL occurs 2 times/],
  ["sitemap URL without a file", { "sitemap.xml": sitemap(["/", "/docs/guide/", "/missing/"]) }, /URL has no built file/],
  ["noncanonical sitemap URL", { "sitemap.xml": sitemap(["/", "/docs/guide/", "/index.html"]) }, /nonindexable or noncanonical HTML URL/],
  ["noindex in sitemap", { "docs/guide/index.html": html("/docs/guide/", { noindex: true }) }, /nonindexable or noncanonical HTML URL/],
  ["404 in sitemap", { "404.html": html("/404/", { noindex: true }), "sitemap.xml": sitemap(["/", "/docs/guide/", "/404.html"]) }, /nonindexable or noncanonical HTML URL/],
  ["indexable 404", { "404.html": html("/404/") }, /404 must declare noindex/],
  ["redirect in sitemap", { "old/index.html": redirect, "sitemap.xml": sitemap(["/", "/docs/guide/", "/old/"]) }, /nonindexable or noncanonical HTML URL/],
  ["redirect to absent page", { "old/index.html": redirect.replaceAll("/docs/guide/", "/absent/") }, /redirect target does not resolve/],
  ["missing robots sitemap", { "robots.txt": "User-agent: *\nAllow: /\n" }, /no Sitemap declaration/],
  ["missing referenced sitemap", { "sitemap.xml": null }, /missing XML file/],
  ["cyclic sitemap index", { "sitemap-index.xml": `<sitemapindex><sitemap><loc>${origin}/sitemap-index.xml</loc></sitemap></sitemapindex>` }, /cyclic index/],
  ["missing docs graph types", { "docs/guide/index.html": html("/docs/guide/").replace('"TechArticle"', '"WebPage"') }, /missing TechArticle JSON-LD/],
  ["malformed JSON-LD", { "docs/guide/index.html": html("/docs/guide/").replace('"@graph":', '"@graph"=') }, /invalid JSON-LD/],
  ["breadcrumb missing non-last URL", { "docs/guide/index.html": html("/docs/guide/").replace(`,"item":"${origin}/"`, "") }, /breadcrumb 1 needs a canonical item URL/],
];

for (const [scenario, changes, diagnostic] of regressions) {
  test(`rejects the build when it contains ${scenario}`, (t) => {
    // Given a real temporary build with the named regression.
    const root = fixture(t, changes);
    // When the gate reads its HTML, robots file, sitemaps and assets.
    const result = auditSite(root);
    // Then the regression yields its own actionable diagnostic.
    assert.ok(result.problems.some((problem) => diagnostic.test(problem)), JSON.stringify(result));
  });
}

test("CLI returns nonzero and a machine-readable report when the build fails", (t) => {
  const root = fixture(t, { "sitemap.xml": sitemap(["/"]) });
  const result = spawnSync(process.execPath, [fileURLToPath(new URL("./check-seo.mjs", import.meta.url)), root], { encoding: "utf8" });
  assert.equal(result.status, 1);
  assert.ok(JSON.parse(result.stdout).problems.some((problem) => /canonical indexable page/.test(problem)));
});

test("CLI returns zero when the build passes", (t) => {
  const root = fixture(t);
  const result = spawnSync(process.execPath, [fileURLToPath(new URL("./check-seo.mjs", import.meta.url)), root], { encoding: "utf8" });
  assert.equal(result.status, 0, result.stderr);
  assert.deepEqual(JSON.parse(result.stdout).problems, []);
});
