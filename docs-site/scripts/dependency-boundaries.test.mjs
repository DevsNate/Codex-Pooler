import assert from "node:assert/strict";
import { createRequire } from "node:module";
import test from "node:test";

const require = createRequire(import.meta.url);
const postcss = require("postcss");
const postcssNested = require("postcss-nested");
const { create: createYamlService } = require("volar-service-yaml");
const { TextDocument } = require("vscode-languageserver-textdocument");

test("Volar consumes the YAML language service through its real CommonJS boundary", async (t) => {
  const service = createYamlService().create({
    env: { clientCapabilities: {} },
    decodeEmbeddedDocumentUri: () => undefined,
  });
  t.after(() => service.dispose());
  const valid = TextDocument.create("file:///example.yaml", "yaml", 1, "title: Example\nitems:\n  - first\n");
  const invalid = TextDocument.create("file:///invalid.yaml", "yaml", 1, "title: [unterminated\n");

  assert.deepEqual(await service.provideDiagnostics(valid), []);
  assert.ok((await service.provideDiagnostics(invalid)).some((diagnostic) => diagnostic.severity === 1));
  assert.ok((await service.provideDocumentSymbols(valid)).some((symbol) => symbol.name === "title"));
  const completions = await service.provideCompletionItems(valid, { line: 0, character: 0 });
  assert.ok(Array.isArray(completions.items));
});

test("PostCSS nesting preserves compound, list and media selectors through the selector parser", async () => {
  const result = await postcss([postcssNested()]).process(`
    .code {
      color: red;
      & .line, &:hover { color: blue; }
      @media (min-width: 40rem) {
        &[data-kind="a,b"] > :is(.one,.two) { color: green; }
      }
    }
  `, { from: undefined });
  const rules = [];
  result.root.walkRules((rule) => rules.push(rule));

  assert.deepEqual(rules.map((rule) => rule.selector), [
    ".code",
    ".code .line, .code:hover",
    '.code[data-kind="a,b"] > :is(.one,.two)',
  ]);
  assert.equal(rules[2].parent.name, "media");
  assert.equal(rules[2].parent.params, "(min-width: 40rem)");
  assert.deepEqual(rules.map((rule) => rule.nodes[0].value), ["red", "blue", "green"]);
  assert.deepEqual(result.warnings(), []);
});
