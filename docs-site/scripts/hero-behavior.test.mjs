import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";
import { runInNewContext } from "node:vm";
import ts from "typescript";

const source = readFileSync(new URL("../src/landing/components/Hero.astro", import.meta.url), "utf8");
const code = ts.transpile(source.match(/<script>([\s\S]*?)<\/script>/)[1], { target: ts.ScriptTarget.ES2022 });

function consoleHarness({ reducedMotion = false } = {}) {
  const operations = [];
  let pathLength = 100;
  class Element {
    dataset = {};
    textContent = "";
    children = [];
    selectors = new Map();
    attributes = new Map();
    classes = new Set();
    style = {
      setProperty() { operations.push("style-write"); },
      set width(value) { this.value = value; operations.push("style-write"); },
    };
    classList = {
      add: (...names) => names.forEach((name) => { this.classes.add(name); }),
      remove: (...names) => names.forEach((name) => { this.classes.delete(name); }),
      toggle: (name, on) => on ? this.classes.add(name) : this.classes.delete(name),
    };
    constructor(tag = "div") { this.tag = tag; }
    querySelector(selector) { return this.selectors.get(selector); }
    querySelectorAll(selector) { return this.selectors.get(selector) ?? []; }
    getBoundingClientRect() {
      operations.push("box-read");
      return { left: 0, right: 100, top: 0, height: 100, width: 100 };
    }
    get offsetWidth() { operations.push("offset-read"); return 100; }
    setAttribute(name, value) {
      operations.push(name === "cx" || name === "cy" ? "position-write" : "svg-write");
      this.attributes.set(name, value);
    }
    getTotalLength() { operations.push("length-read"); return pathLength; }
    getPointAtLength(distance) { operations.push("point-read"); return { x: distance, y: 50 }; }
    append(child) { child.parent = this; this.children.push(child); }
    prepend(child) { child.parent = this; this.children.unshift(child); }
    remove() { this.parent.children.splice(this.parent.children.indexOf(this), 1); }
    get lastElementChild() { return this.children.at(-1); }
  }

  const root = new Element();
  const stage = new Element();
  const svg = new Element("svg");
  const log = new Element("ul");
  const pool = new Element();
  pool.dataset = { poolRow: "product", accounts: "account" };
  pool.selectors.set("[data-rate]", new Element());
  const clients = [new Element(), new Element()];
  clients.forEach((client, i) => {
    client.dataset = { client: `client-${i}`, pool: "product", proto: "WebSocket", ua: "Example client" };
  });
  const account = new Element();
  account.dataset = { acct: "account", left: "100", bank: "0" };
  for (const selector of ["b", "[data-fill]", "[data-pct]", "[data-state]"]) account.selectors.set(selector, new Element());
  for (const [selector, value] of Object.entries({
    "[data-stage]": stage, "[data-links]": svg, "[data-log]": log,
    "[data-client]": clients, "[data-pool-row]": [pool], "[data-acct]": [account],
  })) root.selectors.set(selector, value);

  const document = new EventTarget();
  document.hidden = false;
  document.querySelector = () => root;
  document.createElement = (tag) => new Element(tag);
  document.createElementNS = (_, tag) => new Element(tag);
  const frames = new Map();
  let nextFrame = 0;
  let now = 100;
  let resize;
  let intersection;
  runInNewContext(code, {
    document,
    window: { matchMedia: () => ({ matches: reducedMotion }), setTimeout() {} },
    performance: { now: () => now },
    Math: Object.assign(Object.create(Math), { random: () => 0 }),
    getComputedStyle: () => { operations.push("style-read"); return { display: "block" }; },
    requestAnimationFrame: (fn) => { frames.set(++nextFrame, fn); return nextFrame; },
    cancelAnimationFrame: (id) => frames.delete(id),
    ResizeObserver: class { constructor(callback) { resize = callback; } observe() {} },
    IntersectionObserver: class { constructor(callback) { intersection = callback; } observe() {} },
  });
  return {
    operations, frames, svg, account,
    visible: (value) => intersection([{ isIntersecting: value }]),
    resize: (length) => { pathLength = length; resize(); },
    step: (time) => {
      now = time;
      const scheduled = [...frames.values()];
      frames.clear();
      scheduled.forEach((fn) => { fn(now); });
    },
    circles: () => svg.children.filter((element) => element.tag === "circle"),
  };
}

test("hero reuses path lengths while packets move and remeasures after resize", () => {
  const hero = consoleHarness();
  assert.equal(hero.operations.filter((operation) => operation === "length-read").length, 3);
  hero.visible(true);
  hero.operations.length = 0;
  hero.step(400);
  const dot = hero.circles()[0];
  hero.step(500);
  const before = Number(dot.attributes.get("cx"));
  assert.ok(before > 0 && before < 100);
  hero.step(600);
  assert.ok(Number(dot.attributes.get("cx")) > before);
  assert.equal(hero.operations.includes("length-read"), false);

  hero.operations.length = 0;
  hero.resize(200);
  assert.equal(hero.operations.filter((operation) => operation === "length-read").length, 3);
  assert.ok(hero.operations.lastIndexOf("box-read") < hero.operations.indexOf("svg-write"));
  assert.ok(hero.operations.lastIndexOf("svg-write") < hero.operations.indexOf("length-read"));
  hero.operations.length = 0;
  hero.step(740);
  assert.equal(Number(dot.attributes.get("cx")), 100);
  assert.equal(hero.operations.includes("length-read"), false);
});

test("hero reads every packet point before writing positions or account styles", () => {
  const hero = consoleHarness();
  hero.visible(true);
  hero.step(400);
  hero.step(800);
  assert.equal(hero.circles().length, 2);
  hero.operations.length = 0;
  hero.step(900);
  assert.equal(hero.operations.filter((operation) => operation === "point-read").length, 2);
  const lastRead = hero.operations.lastIndexOf("point-read");
  assert.ok(lastRead < hero.operations.indexOf("position-write"));
  assert.ok(lastRead < hero.operations.indexOf("style-write"));
});

test("hero pauses offscreen, resumes moving, and delivers traffic to an account", () => {
  const hero = consoleHarness();
  hero.visible(true);
  hero.step(400);
  hero.step(500);
  const dot = hero.circles()[0];
  const position = dot.attributes.get("cx");
  hero.visible(false);
  assert.equal(hero.frames.size, 0);
  hero.step(1500);
  assert.equal(dot.attributes.get("cx"), position);
  hero.visible(true);
  hero.step(1600);
  assert.ok(Number(dot.attributes.get("cx")) > Number(position));
  hero.step(2080);
  hero.step(2620);
  assert.equal(hero.circles().includes(dot), false);
  assert.ok(parseFloat(hero.account.querySelector("[data-fill]").style.value) < 100);
});

test("hero draws its routes but schedules no movement with reduced motion", () => {
  const hero = consoleHarness({ reducedMotion: true });
  assert.equal(hero.svg.children.filter((element) => element.tag === "path").length, 3);
  assert.equal(hero.frames.size, 0);
  hero.step(1000);
  assert.equal(hero.circles().length, 0);
});
