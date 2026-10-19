import assert from "node:assert/strict";
import test from "node:test";
import { DOCS_REDIRECTS, isIndexablePage, legacyRedirects } from "../src/legacyRedirects.mjs";

test("maps published collection ids without generating a homepage or 404 redirect", () => {
  // Given the ids produced by the docs loader, including a frontmatter slug.
  const ids = ["docs", "404", "docs/getting-started/quick-start", "docs/clients/custom-slug"];
  // When the legacy route inventory is generated.
  const redirects = legacyRedirects(ids);
  // Then published paths map to canonical docs URLs and unrelated paths remain absent.
  assert.equal(redirects["/getting-started/quick-start/"], "/docs/getting-started/quick-start/");
  assert.equal(redirects["/clients/custom-slug/"], "/docs/clients/custom-slug/");
  for (const absent of ["/", "/404/", "/docs/", "/unknown/", "/clients/source-filename/"]) {
    assert.equal(Object.hasOwn(redirects, absent), false);
  }
});

test("flattens all renamed bare paths directly to final docs pages", () => {
  // Given the current canonical ids for the three renamed pages.
  const ids = ["docs/clients/kilo-code", "docs/clients/codex-cli-desktop", "docs/reference/runtime-routes"];
  // When legacy paths are generated alongside the existing docs aliases.
  const redirects = legacyRedirects(ids);
  // Then every old bare path skips the intermediate renamed docs path.
  assert.equal(redirects["/clients/kilo/"], "/docs/clients/kilo-code/");
  assert.equal(redirects["/clients/codex-cli/"], "/docs/clients/codex-cli-desktop/");
  assert.equal(redirects["/reference/endpoint-routing/"], "/docs/reference/runtime-routes/");
  for (const [source, target] of Object.entries(DOCS_REDIRECTS)) {
    assert.equal(redirects[source.slice(5)], target);
    assert.equal(Object.hasOwn(DOCS_REDIRECTS, target), false);
  }
});

test("limits the sitemap to canonical content rather than redirect and noindex pages", () => {
  // Given canonical pages, legacy paths and the noindex moved guide.
  const paths = ["/", "/docs/", "/docs/clients/kilo-code/", "/clients/kilo-code/", "/docs/operators/monitoring/", "/404/", ...Object.keys(DOCS_REDIRECTS)];
  // When the sitemap applies its URL filter.
  const retained = paths.filter((path) => isIndexablePage(`https://example.com${path}`));
  // Then only canonical content pages survive.
  assert.deepEqual(retained, ["/", "/docs/", "/docs/clients/kilo-code/"]);
});
