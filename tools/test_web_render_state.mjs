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
    globalThis.readCamera = () => new Float32Array(cameraBytes.buffer).slice();
  `, context);
  return { host: context.rendererHost, calls, readCamera: context.readCamera };
}

test("uniform changes share one upload before drawing", () => {
  const { host, calls, readCamera } = renderer();
  host.aether_webgl_set_alpha_blend(false);
  host.aether_webgl_set_uv_offset(0.25, 0.5);
  host.aether_webgl_set_fog(true, 10, 100, 1, 0, 0);
  host.aether_webgl_set_proj_matrix(0);
  host.aether_webgl_set_view_matrix(64);
  assert.equal(calls.filter(([name]) => name === "bufferSubData").length, 0);
  host.aether_webgl_draw_mesh(1, 128);
  // One shared state upload and one model upload.
  assert.equal(calls.filter(([name]) => name === "bufferSubData").length, 2);
  assert.equal(readCamera()[40], 0.25);
  assert.equal(readCamera()[41], 0.5);
  calls.length = 0;
  host.aether_webgl_draw_mesh(1, 128);
  assert.equal(calls.filter(([name]) => name === "bufferSubData").length, 1);
});

test("texture uploads restore the selected draw texture only when needed", () => {
  const { host, calls } = renderer();
  const first = host.aether_webgl_create_texture(1, 1, 0, 4);
  host.aether_webgl_bind_texture(first);
  host.aether_webgl_draw_mesh(1, 128);
  calls.length = 0;
  host.aether_webgl_bind_texture(first);
  host.aether_webgl_draw_mesh(1, 128);
  assert.equal(calls.filter(([name]) => name === "bindTexture").length, 0);
  const second = host.aether_webgl_create_texture(1, 1, 0, 4);
  calls.length = 0;
  host.aether_webgl_draw_mesh(1, 128);
  assert.equal(calls.filter(([name]) => name === "bindTexture").length, 1);
  host.aether_webgl_update_texture(second, 0, 4);
  calls.length = 0;
  host.aether_webgl_draw_mesh(1, 128);
  assert.equal(calls.filter(([name]) => name === "bindTexture").length, 1);
  calls.length = 0;
  host.aether_webgl_draw_mesh(1, 128);
  assert.equal(calls.filter(([name]) => name === "bindTexture").length, 0);
  host.aether_webgl_destroy_texture(first);
  calls.length = 0;
  host.aether_webgl_draw_mesh(1, 128);
  assert.equal(calls.filter(([name]) => name === "bindTexture").length, 0);
});

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
