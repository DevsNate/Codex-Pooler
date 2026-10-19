import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";
import { runInNewContext } from "node:vm";
import ts from "typescript";

const source = (path) => readFileSync(new URL(`../src/landing/${path}`, import.meta.url), "utf8");
const script = (path) => source(path).match(/<script>([\s\S]*?)<\/script>/)[1];
const execute = (code, context) => runInNewContext(ts.transpile(code, { target: ts.ScriptTarget.ES2022 }), context);

class Element extends EventTarget {
  hidden = false;
  dataset = {};
  tabIndex = 0;
  textContent = "";
  offsetWidth = 1;
  attributes = new Map();
  classes = new Set();
  children = new Map();
  style = { setProperty() {} };
  classList = {
    add: (name) => this.classes.add(name),
    remove: (name) => this.classes.delete(name),
    toggle: (name, on) => on ? this.classes.add(name) : this.classes.delete(name),
  };
  getAttribute(name) { return this.attributes.get(name); }
  setAttribute(name, value) { this.attributes.set(name, value); }
  querySelector(selector) { return this.children.get(selector); }
  querySelectorAll(selector) { return this.children.get(selector) ?? []; }
  contains(element) { return [...this.children.values()].includes(element); }
}

test("reveal registers observation before making content animation-dependent", () => {
  // Given: an unrevealed element and the real reveal script.
  const item = new Element();
  let callback;
  const context = {
    document: { querySelectorAll: () => [item] },
    window: { matchMedia: () => ({ matches: false }), IntersectionObserver: true },
    IntersectionObserver: class {
      constructor(next) { callback = next; }
      observe(target) { assert.equal(target.classes.has("reveal-ready"), false); }
      unobserve() {}
    },
  };
  // When: the module initializes, then the observed element enters the viewport.
  execute(source("scripts/reveal.ts"), context);
  assert.equal(item.classes.has("reveal-ready"), true);
  callback([{ isIntersecting: true, target: item }]);
  // Then: the content completes the reveal.
  assert.equal(item.classes.has("is-in"), true);
});

for (const mode of ["reduced motion", "missing observer"]) {
  test(`reveal keeps content visible with ${mode}`, () => {
    const item = new Element();
    const window = { matchMedia: () => ({ matches: mode === "reduced motion" }) };
    if (mode === "reduced motion") window.IntersectionObserver = true;
    execute(source("scripts/reveal.ts"), { document: { querySelectorAll: () => [item] }, window });
    assert.equal(item.classes.has("reveal-ready"), false);
    assert.equal(item.classes.has("is-in"), true);
  });
}

for (const interaction of ["focusin", "pointerenter", "pointerdown"]) {
  test(`dashboard stops its automatic timer on ${interaction}`, () => {
    // Given: the real dashboard script with native event dispatch and a controlled clock.
    const tour = new Element();
    const tabs = [new Element(), new Element()];
    tabs.forEach((tab) => { tab.children.set(".tab-progress", new Element()); });
    tour.children.set("[data-tab]", tabs);
    tour.children.set("[data-panel]", [new Element(), new Element()]);
    tour.children.set("[data-caption]", [new Element(), new Element()]);
    const timers = new Map();
    let callback;
    let nextTimer = 0;
    execute(script("components/Dashboard.astro"), {
      document: { querySelector: () => tour },
      window: {
        matchMedia: () => ({ matches: false }),
        setTimeout: (fn) => { timers.set(++nextTimer, fn); return nextTimer; },
        clearTimeout: (id) => timers.delete(id),
      },
      IntersectionObserver: class {
        constructor(next) { callback = next; }
        observe() {}
      },
    });
    callback([{ isIntersecting: true }]);
    assert.equal(timers.size, 1);
    // When: a visitor interacts with the dashboard.
    tour.dispatchEvent(new Event(interaction));
    // Then: rotation stops and remains stopped after leaving/reentering the viewport.
    assert.equal(timers.size, 0);
    callback([{ isIntersecting: false }]);
    callback([{ isIntersecting: true }]);
    assert.equal(timers.size, 0);
  });
}

test("mobile menu restores focused link to trigger when Escape closes it", () => {
  const document = new EventTarget();
  const window = new EventTarget();
  const nav = new Element();
  const button = new Element();
  const menu = new Element();
  const link = new Element();
  menu.children.set("link", link);
  button.focus = () => { document.activeElement = button; };
  document.activeElement = link;
  document.querySelector = (selector) => ({ "[data-nav]": nav, "[data-menu-btn]": button, "[data-menu]": menu })[selector];
  window.scrollY = 0;
  window.matchMedia = () => new EventTarget();
  execute(script("components/Nav.astro"), { document, window });
  const keyEvent = new Event("keydown");
  keyEvent.key = "Escape";
  document.dispatchEvent(keyEvent);
  assert.equal(menu.hidden, true);
  assert.equal(document.activeElement, button);
});

for (const visible of [false, true]) {
  test(`returning to a tab runs the simulator only when visible=${visible}`, () => {
    // Given: the observer reports whether the simulator is visible.
    const code = script("components/Simulator.astro");
    const start = code.indexOf("    let shown = false;");
    const seam = code.slice(start, code.lastIndexOf("\n  }"));
    const document = new EventTarget();
    document.hidden = false;
    const running = [];
    let callback;
    execute(seam, {
      document,
      innerHeight: 800,
      sim: { getBoundingClientRect: () => ({ top: -1000, bottom: -100 }) },
      touched: true,
      window: { setTimeout() {} },
      setRunning: (value) => running.push(value),
      IntersectionObserver: class {
        constructor(next) { callback = next; }
        observe() {}
      },
    });
    callback([{ isIntersecting: visible, intersectionRatio: visible ? 1 : 0 }]);
    // When: the visitor returns to the browser tab.
    document.dispatchEvent(new Event("visibilitychange"));
    // Then: the animation state follows the observer, not a stale one-sided rectangle check.
    assert.deepEqual(running, [visible, visible]);
  });
}
