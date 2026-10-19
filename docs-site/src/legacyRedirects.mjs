// Renamed documentation paths point straight to their final canonical page.
export const DOCS_REDIRECTS = {
  "/docs/clients/kilo/": "/docs/clients/kilo-code/",
  "/docs/clients/codex-cli/": "/docs/clients/codex-cli-desktop/",
  "/docs/reference/endpoint-routing/": "/docs/reference/runtime-routes/",
};

/** @param {readonly string[]} entryIds */
export function legacyRedirects(entryIds) {
  return {
    ...Object.fromEntries(entryIds.filter((id) => id.startsWith("docs/")).map((id) => [`/${id.slice(5)}/`, `/${id}/`])),
    ...Object.fromEntries(Object.entries(DOCS_REDIRECTS).map(([source, target]) => [source.slice(5), target])),
  };
}

/** @param {string} page */
export function isIndexablePage(page) {
  const { pathname } = new URL(page);
  return pathname === "/" || (pathname.startsWith("/docs/") && pathname !== "/docs/operators/monitoring/" && !Object.hasOwn(DOCS_REDIRECTS, pathname));
}
