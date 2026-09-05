// Exercise the real loader host callback without starting WebGL or WASM.
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";
import vm from "node:vm";

function exporter({ clickFails = false } = {}) {
  const events = [];
  const pending = [];
  const context = vm.createContext({
    TextDecoder, TextEncoder, Uint8Array, ArrayBuffer,
    Blob: class {
      constructor(parts, options) {
        events.push(["blob", Array.from(parts[0]), options.type]);
      }
    },
    URL: {
      createObjectURL() { events.push(["url"]); return "blob:export"; },
      revokeObjectURL(url) { events.push(["revoke", url]); },
    },
    setTimeout(fn) { pending.push(fn); },
    document: {
      getElementById() { return {}; },
      body: { appendChild() { events.push(["append"]); } },
      createElement(tag) {
        assert.equal(tag, "a");
        return {
          style: {},
          click() {
            events.push(["click", this.download, this.href]);
            if (clickFails) throw new Error("blocked");
          },
          remove() { events.push(["remove"]); },
        };
      },
    },
  });
  const source = readFileSync(new URL("../web/aether.js", import.meta.url), "utf8")
    .replace(/^import .*;\n/, "")
    .replace(/\nmain\(\);\s*$/, "");
  vm.runInContext(source + `
    memory = { buffer: new ArrayBuffer(1024) };
    files.set("save.dat", new Uint8Array([0, 128, 255]));
    files.set("empty.dat", new Uint8Array(0));
    globalThis.download = (path, name, type) => {
      let offset = 0;
      const args = [];
      for (const value of [path, name, type]) {
        const bytes = new TextEncoder().encode(value);
        new Uint8Array(memory.buffer, offset, bytes.length).set(bytes);
        args.push(offset, bytes.length);
        offset += bytes.length;
      }
      return host.aether_download_file(...args);
    };
  `, context);
  return { download: context.download, events, flush: () => pending.splice(0).forEach(fn => fn()) };
}

test("exports virtual file bytes with requested filename and MIME, then releases URL", () => {
  const e = exporter();
  assert.equal(e.download("save.dat", "example.bin", "application/x-example"), true);
  assert.deepEqual(e.events[0], ["blob", [0, 128, 255], "application/x-example"]);
  assert.ok(e.events.some(event => event[0] === "click" && event[1] === "example.bin"));
  assert.ok(e.events.some(event => event[0] === "remove"));
  assert.equal(e.events.some(event => event[0] === "revoke"), false);
  e.flush();
  assert.deepEqual(e.events.at(-1), ["revoke", "blob:export"]);
});

test("missing files and empty metadata fail without creating URLs; empty files export", () => {
  const e = exporter();
  assert.equal(e.download("missing", "missing.dat", "application/octet-stream"), false);
  assert.equal(e.download("save.dat", "", "application/octet-stream"), false);
  assert.deepEqual(e.events, []);
  assert.equal(e.download("empty.dat", "empty.dat", "application/octet-stream"), true);
});

test("failed browser initiation still removes the element and releases the URL", () => {
  const e = exporter({ clickFails: true });
  assert.equal(e.download("save.dat", "save.dat", "application/octet-stream"), false);
  e.flush();
  assert.deepEqual(e.events.at(-1), ["revoke", "blob:export"]);
  assert.ok(e.events.some(event => event[0] === "remove"));
});
