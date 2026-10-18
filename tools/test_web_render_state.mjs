// Run with: node --test tools/test_web_render_state.mjs
// Exercise the loader's real host callbacks with a recording GL implementation.
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";
import vm from "node:vm";

function renderer() {
  const calls = [];
  let nextObject = 1;
  const gl = new Proxy({}, {
    get(_, name) {
      if (name === name.toUpperCase()) return name;
      if (name.startsWith("create")) return () => nextObject++;
      return (...args) => calls.push([name, ...args]);
    },
  });
  const context = vm.createContext({
    TextDecoder, TextEncoder,
    document: { getElementById: () => ({}) },
    recordingGl: gl,
  });
  const source = readFileSync(new URL("../web/aether.js", import.meta.url), "utf8")
    .replace(/^import .*;\n/, "")
    .replace(/\nmain\(\);\s*$/, "");
  vm.runInContext(source + `
    gl = recordingGl;
    memory = { buffer: new ArrayBuffer(256) };
    cameraBuffer = 100;
    perObjectBuffer = 101;
    meshes.set(1, { vao: 102, vertexCount: 3, indexCount: 0 });
    globalThis.rendererHost = host;
  `, context);
  return { host: context.rendererHost, calls };
}

test("depth clears restore the requested write mask without redundant calls", () => {
  const { host, calls } = renderer();
  host.aether_webgl_clear_depth();
  assert.deepEqual(calls, [["clear", "DEPTH_BUFFER_BIT"]]);
  host.aether_webgl_set_depth_write(false);
  calls.length = 0;
  host.aether_webgl_clear_depth();
  assert.deepEqual(calls, [
    ["depthMask", true], ["clear", "DEPTH_BUFFER_BIT"], ["depthMask", false],
  ]);
  calls.length = 0;
  host.aether_webgl_start_frame(640, 480);
  assert.deepEqual(calls.filter(([name]) => name === "depthMask"), [
    ["depthMask", true], ["depthMask", false],
  ]);
});
