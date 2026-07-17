const canvas = document.getElementById("aether");
const statusEl = document.getElementById("status");
const textDecoder = new TextDecoder();
const textEncoder = new TextEncoder();

let instance = null;
let memory = null;
let gl = null;
let program = null;
let currentTexture = null;
let cameraBuffer = null;
let perObjectBuffer = null;
let nextMeshHandle = 1;
let nextTextureHandle = 1;
const meshes = new Map();
const textures = new Map();
const audioSlots = new Map();
let audioContext = null;
let gainRoot = null;
let audioSampleRate = 48000;
let audioMaxSlots = 32;
let requestedCursorMode = 3;
let pointerLocked = false;
let suppressNextPointerUnlock = false;
let pendingSyntheticEscapeUp = false;
let ignorePointerMoveCount = 0;

const CURSOR_CAPTURED = 0;
const CURSOR_FREE = 1;
const CURSOR_HIDDEN = 2;
const CURSOR_VISIBLE = 3;
const KEY_ESCAPE = 256;

const CAMERA_UBO_SIZE = 176;
const PER_OBJECT_UBO_SIZE = 64;
const cameraBytes = new Uint8Array(CAMERA_UBO_SIZE);
const cameraData = new DataView(cameraBytes.buffer);
const perObjectBytes = new Uint8Array(PER_OBJECT_UBO_SIZE);

const files = new Map();
const dirs = new Set(["."]);
const fds = new Map([
  [0, { kind: "stdio" }],
  [1, { kind: "stdio" }],
  [2, { kind: "stdio" }],
  [3, { kind: "dir", path: "/" }],
]);
const stdioBuffers = new Map([
  [1, ""],
  [2, ""],
]);
let nextFd = 4;

function bytes() {
  return new Uint8Array(memory.buffer);
}
function view() {
  return new DataView(memory.buffer);
}
function f32(ptr, count) {
  return new Float32Array(memory.buffer, ptr, count);
}
function f32Copy(ptr, count) {
  return Float32Array.from(f32(ptr, count));
}
function copyBytes(ptr, len) {
  return Uint8Array.from(bytes().subarray(ptr, ptr + len));
}
function str(ptr, len) {
  return textDecoder.decode(copyBytes(ptr, len));
}
function setStatus(text) {
  statusEl.textContent = text;
}

async function preload(name) {
  const response = await fetch(`./${name}`);
  if (!response.ok) throw new Error(`missing resource ${name}`);
  files.set(name, new Uint8Array(await response.arrayBuffer()));
}

async function preloadResourceDirectory() {
  const manifestResponse = await fetch("./resources.manifest", {
    cache: "no-store",
  });
  if (!manifestResponse.ok) return;
  const manifest = await manifestResponse.text();
  const entries = manifest
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter((line) => line && !line.startsWith("#"));
  await Promise.all(entries.map(preload));
}

function errno(code) {
  return code;
}
const WASI = {
  proc_exit(code) {
    throw new Error(`WASI exited with ${code}`);
  },
  args_sizes_get(argcPtr, argvBufSizePtr) {
    view().setUint32(argcPtr, 0, true);
    view().setUint32(argvBufSizePtr, 0, true);
    return 0;
  },
  args_get() {
    return 0;
  },
  environ_sizes_get(countPtr, sizePtr) {
    view().setUint32(countPtr, 0, true);
    view().setUint32(sizePtr, 0, true);
    return 0;
  },
  environ_get() {
    return 0;
  },
  clock_time_get(id, precision, timePtr) {
    const ns =
      id === 1
        ? BigInt(Math.floor(performance.now() * 1_000_000))
        : BigInt(Date.now()) * 1_000_000n;
    view().setBigUint64(timePtr, ns, true);
    return 0;
  },
  clock_res_get(id, resolutionPtr) {
    const ns = id === 1 ? 1_000_000n : 1_000_000n;
    view().setBigUint64(resolutionPtr, ns, true);
    return 0;
  },
  poll_oneoff(inPtr, outPtr, nsubscriptions, neventsPtr) {
    view().setUint32(neventsPtr, 0, true);
    return 0;
  },
  random_get(ptr, len) {
    const random = new Uint8Array(len);
    crypto.getRandomValues(random);
    bytes().set(random, ptr);
    return 0;
  },
  fd_prestat_get(fd, ptr) {
    if (fd !== 3) return errno(8);
    view().setUint8(ptr, 0);
    view().setUint32(ptr + 4, 1, true);
    return 0;
  },
  fd_prestat_dir_name(fd, ptr, len) {
    if (fd !== 3) return errno(8);
    bytes().set(textEncoder.encode("/").subarray(0, len), ptr);
    return 0;
  },
  fd_fdstat_get(fd, ptr) {
    const file = fds.get(fd);
    if (!file) return errno(8);
    view().setUint8(ptr, file.kind === "dir" ? 3 : 4);
    view().setUint16(ptr + 2, 0, true);
    view().setBigUint64(ptr + 8, 0xffff_ffffn, true);
    view().setBigUint64(ptr + 16, 0xffff_ffffn, true);
    return 0;
  },
  fd_close(fd) {
    if (fd <= 3) return 0;
    fds.delete(fd);
    return 0;
  },
  fd_filestat_get(fd, ptr) {
    const file = fds.get(fd);
    if (!file) return errno(8);
    const size = file.data ? file.data.length : 0;
    for (let i = 0; i < 64; i++) view().setUint8(ptr + i, 0);
    view().setUint8(ptr + 16, file.kind === "dir" ? 3 : 4);
    view().setBigUint64(ptr + 32, BigInt(size), true);
    return 0;
  },
  fd_filestat_set_times() {
    return 0;
  },
  fd_filestat_set_size(fd, size) {
    const file = fds.get(fd);
    if (!file || file.kind !== "file") return errno(8);
    const next = new Uint8Array(Number(size));
    next.set(file.data.subarray(0, Math.min(file.data.length, next.length)));
    file.data = next;
    file.pos = Math.min(file.pos, next.length);
    files.set(file.name, next);
    return 0;
  },
  fd_sync() {
    return 0;
  },
  path_filestat_get(fd, flags, pathPtr, pathLen, resultPtr) {
    const name = resolvePath(fd, str(pathPtr, pathLen));
    if (!name) return errno(8);
    const data = files.get(name);
    const isDir = dirs.has(name);
    if (!data && !isDir) return errno(44);
    for (let i = 0; i < 64; i++) view().setUint8(resultPtr + i, 0);
    view().setUint8(resultPtr + 16, isDir ? 3 : 4);
    view().setBigUint64(resultPtr + 32, BigInt(data ? data.length : 0), true);
    return 0;
  },
  path_create_directory(fd, pathPtr, pathLen) {
    const name = resolvePath(fd, str(pathPtr, pathLen));
    if (!name) return errno(8);
    dirs.add(name);
    return 0;
  },
  path_link() {
    return errno(52);
  },
  path_symlink() {
    return errno(52);
  },
  path_readlink() {
    return errno(52);
  },
  path_rename(oldFd, oldPathPtr, oldPathLen, newFd, newPathPtr, newPathLen) {
    const oldName = resolvePath(oldFd, str(oldPathPtr, oldPathLen));
    const newName = resolvePath(newFd, str(newPathPtr, newPathLen));
    if (!oldName || !newName) return errno(8);
    const data = files.get(oldName);
    if (!data) return errno(44);
    files.set(newName, data);
    files.delete(oldName);
    for (const file of fds.values()) {
      if (file.name === oldName) file.name = newName;
    }
    return 0;
  },
  path_remove_directory() {
    return 0;
  },
  path_unlink_file(fd, pathPtr, pathLen) {
    const name = resolvePath(fd, str(pathPtr, pathLen));
    if (!name) return errno(8);
    files.delete(name);
    return 0;
  },
  path_open(
    fd,
    dirflags,
    pathPtr,
    pathLen,
    oflags,
    rightsBase,
    rightsInheriting,
    fdflags,
    openedFdPtr,
  ) {
    const name = resolvePath(fd, str(pathPtr, pathLen));
    if (!name) return errno(8);
    const create = (oflags & 1) !== 0;
    const directory = (oflags & 2) !== 0;
    const exclusive = (oflags & 4) !== 0;
    const truncate = (oflags & 8) !== 0;
    if (directory) {
      if (!dirs.has(name)) return errno(44);
      const newFd = nextFd++;
      fds.set(newFd, { kind: "dir", path: name });
      view().setUint32(openedFdPtr, newFd, true);
      return 0;
    }
    let data = files.get(name);
    if (!data) {
      if (!create) return errno(44);
      data = new Uint8Array(0);
      files.set(name, data);
    } else if (create && exclusive) {
      return errno(20);
    } else if (truncate) {
      data = new Uint8Array(0);
      files.set(name, data);
    }
    const newFd = nextFd++;
    fds.set(newFd, { kind: "file", name, data, pos: 0, writable: true });
    view().setUint32(openedFdPtr, newFd, true);
    return 0;
  },
  fd_readdir(fd, bufPtr, bufLen, cookie, bufUsedPtr) {
    const file = fds.get(fd);
    if (!file || file.kind !== "dir") return errno(8);
    const entries = directoryEntries(file.path || ".");
    let out = 0;
    const start = Number(cookie);
    for (let i = start; i < entries.length; i++) {
      const entry = entries[i];
      const nameBytes = textEncoder.encode(entry.name);
      const needed = 24 + nameBytes.length;
      if (out + needed > bufLen) break;

      const ptr = bufPtr + out;
      view().setBigUint64(ptr, BigInt(i + 1), true);
      view().setBigUint64(ptr + 8, BigInt(i + 1), true);
      view().setUint32(ptr + 16, nameBytes.length, true);
      view().setUint8(ptr + 20, entry.type);
      view().setUint8(ptr + 21, 0);
      view().setUint8(ptr + 22, 0);
      view().setUint8(ptr + 23, 0);
      bytes().set(nameBytes, ptr + 24);
      out += needed;
    }
    view().setUint32(bufUsedPtr, out, true);
    return 0;
  },
  fd_read(fd, iovsPtr, iovsLen, nreadPtr) {
    const file = fds.get(fd);
    if (!file || !file.data) return errno(8);
    let total = 0;
    for (let i = 0; i < iovsLen; i++) {
      const ptr = view().getUint32(iovsPtr + i * 8, true);
      const len = view().getUint32(iovsPtr + i * 8 + 4, true);
      const chunk = file.data.subarray(file.pos, file.pos + len);
      bytes().set(chunk, ptr);
      file.pos += chunk.length;
      total += chunk.length;
      if (chunk.length < len) break;
    }
    view().setUint32(nreadPtr, total, true);
    return 0;
  },
  fd_pread(fd, iovsPtr, iovsLen, offset, nreadPtr) {
    const file = fds.get(fd);
    if (!file || !file.data) return errno(8);
    const oldPos = file.pos;
    file.pos = Number(offset);
    const result = WASI.fd_read(fd, iovsPtr, iovsLen, nreadPtr);
    file.pos = oldPos;
    return result;
  },
  fd_write(fd, iovsPtr, iovsLen, nwrittenPtr) {
    const file = fds.get(fd);
    let total = 0;
    for (let i = 0; i < iovsLen; i++) {
      const ptr = view().getUint32(iovsPtr + i * 8, true);
      const len = view().getUint32(iovsPtr + i * 8 + 4, true);
      const chunk = copyBytes(ptr, len);
      total += len;
      if (fd === 1 || fd === 2) {
        writeStdio(fd, chunk);
      } else if (file && file.kind === "file") {
        const next = new Uint8Array(Math.max(file.data.length, file.pos + len));
        next.set(file.data);
        next.set(chunk, file.pos);
        file.data = next;
        file.pos += len;
        files.set(file.name, next);
      }
    }
    view().setUint32(nwrittenPtr, total, true);
    return 0;
  },
  fd_pwrite(fd, iovsPtr, iovsLen, offset, nwrittenPtr) {
    const file = fds.get(fd);
    if (!file || file.kind !== "file") return errno(8);
    const oldPos = file.pos;
    file.pos = Number(offset);
    const result = WASI.fd_write(fd, iovsPtr, iovsLen, nwrittenPtr);
    file.pos = oldPos;
    return result;
  },
  fd_seek(fd, offset, whence, newOffsetPtr) {
    const file = fds.get(fd);
    if (!file || !file.data) return errno(8);
    const base = whence === 0 ? 0 : whence === 1 ? file.pos : file.data.length;
    file.pos = Math.max(0, base + Number(offset));
    view().setBigUint64(newOffsetPtr, BigInt(file.pos), true);
    return 0;
  },
};

function normalizePath(path) {
  while (path.startsWith("/")) path = path.slice(1);
  const parts = [];
  for (const part of path.split("/")) {
    if (!part || part === ".") continue;
    if (part === "..") parts.pop();
    else parts.push(part);
  }
  return parts.join("/") || ".";
}

function resolvePath(fd, path) {
  const base = fds.get(fd);
  if (!base || base.kind !== "dir") return null;
  if (path.startsWith("/")) return normalizePath(path);
  const prefix = normalizePath(base.path || ".");
  return normalizePath(prefix === "." ? path : `${prefix}/${path}`);
}

function directoryEntries(path) {
  const dir = normalizePath(path);
  const byName = new Map();
  const addChild = (fullPath, type) => {
    const normalized = normalizePath(fullPath);
    if (normalized === dir) return;
    const prefix = dir === "." ? "" : `${dir}/`;
    if (prefix && !normalized.startsWith(prefix)) return;
    const rest = prefix ? normalized.slice(prefix.length) : normalized;
    if (!rest || rest.includes("/")) return;
    byName.set(rest, { name: rest, type });
  };

  for (const child of dirs) addChild(child, 3);
  for (const child of files.keys()) addChild(child, 4);
  return Array.from(byName.values()).sort((a, b) =>
    a.name.localeCompare(b.name),
  );
}

function writeStdio(fd, chunk) {
  let text = (stdioBuffers.get(fd) || "") + textDecoder.decode(chunk);
  const lines = text.split(/\r?\n/);
  stdioBuffers.set(fd, lines.pop() || "");
  const write = fd === 2 ? console.error : console.log;
  for (const line of lines) {
    if (line.length > 0) write(line);
  }
}

function compileShader(type, source) {
  const shader = gl.createShader(type);
  gl.shaderSource(shader, normalizeSlangGlsl(source));
  gl.compileShader(shader);
  if (!gl.getShaderParameter(shader, gl.COMPILE_STATUS)) {
    throw new Error(gl.getShaderInfoLog(shader));
  }
  return shader;
}

function normalizeSlangGlsl(source) {
  return source;
}

function setMat4Bytes(target, byteOffset, ptr) {
  new Float32Array(target.buffer, byteOffset, 16).set(f32Copy(ptr, 16));
}

function uploadCameraUbo() {
  gl.bindBuffer(gl.UNIFORM_BUFFER, cameraBuffer);
  gl.bufferSubData(gl.UNIFORM_BUFFER, 0, cameraBytes);
}

function uploadPerObjectUbo(modelPtr) {
  setMat4Bytes(perObjectBytes, 0, modelPtr);
  gl.bindBuffer(gl.UNIFORM_BUFFER, perObjectBuffer);
  gl.bufferSubData(gl.UNIFORM_BUFFER, 0, perObjectBytes);
}

function initUniformBlocks() {
  cameraBuffer = gl.createBuffer();
  perObjectBuffer = gl.createBuffer();

  gl.bindBuffer(gl.UNIFORM_BUFFER, cameraBuffer);
  gl.bufferData(gl.UNIFORM_BUFFER, cameraBytes, gl.DYNAMIC_DRAW);
  gl.bindBufferBase(gl.UNIFORM_BUFFER, 0, cameraBuffer);

  gl.bindBuffer(gl.UNIFORM_BUFFER, perObjectBuffer);
  gl.bufferData(gl.UNIFORM_BUFFER, perObjectBytes, gl.DYNAMIC_DRAW);
  gl.bindBufferBase(gl.UNIFORM_BUFFER, 1, perObjectBuffer);

  const cameraBlock = gl.getUniformBlockIndex(program, "block_CameraState_0");
  if (cameraBlock !== gl.INVALID_INDEX)
    gl.uniformBlockBinding(program, cameraBlock, 0);
  const perObjectBlock = gl.getUniformBlockIndex(program, "block_PerObject_0");
  if (perObjectBlock !== gl.INVALID_INDEX)
    gl.uniformBlockBinding(program, perObjectBlock, 1);

  new Float32Array(cameraBytes.buffer, 0, 16).set([
    1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1,
  ]);
  new Float32Array(cameraBytes.buffer, 64, 16).set([
    1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1,
  ]);
  cameraData.setUint32(156, 1, true);
  uploadCameraUbo();
}

const host = {
  aether_input_apply_cursor_mode(mode) {
    requestedCursorMode = mode;
    if (mode === CURSOR_CAPTURED) {
      canvas.style.cursor = "none";
    } else {
      if (document.pointerLockElement === canvas) {
        suppressNextPointerUnlock = true;
        document.exitPointerLock();
      }
      canvas.style.cursor = mode === CURSOR_HIDDEN ? "none" : "";
    }
  },
  aether_canvas_width() {
    return canvas.width;
  },
  aether_canvas_height() {
    return canvas.height;
  },
  aether_surface_init(width, height, titlePtr, titleLen) {
    document.title = str(titlePtr, titleLen);
    resizeCanvas(width, height);
    canvas.focus();
  },
  aether_surface_present() {},
  aether_webgl_init(vp, vl, fp, fl) {
    gl = canvas.getContext("webgl2", { alpha: false, antialias: false });
    if (!gl) return false;
    const vs = compileShader(gl.VERTEX_SHADER, str(vp, vl));
    const fs = compileShader(gl.FRAGMENT_SHADER, str(fp, fl));
    program = gl.createProgram();
    gl.attachShader(program, vs);
    gl.attachShader(program, fs);
    gl.linkProgram(program);
    if (!gl.getProgramParameter(program, gl.LINK_STATUS))
      throw new Error(gl.getProgramInfoLog(program));
    gl.useProgram(program);
    initUniformBlocks();
    const sampler = gl.getUniformLocation(program, "u_combinedTexture_0");
    if (sampler) gl.uniform1i(sampler, 0);
    gl.enable(gl.DEPTH_TEST);
    gl.enable(gl.CULL_FACE);
    gl.frontFace(gl.CCW);
    gl.cullFace(gl.BACK);
    gl.enable(gl.BLEND);
    gl.blendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA);
    return true;
  },
  aether_webgl_deinit() {
    if (cameraBuffer) gl.deleteBuffer(cameraBuffer);
    if (perObjectBuffer) gl.deleteBuffer(perObjectBuffer);
    cameraBuffer = null;
    perObjectBuffer = null;
  },
  aether_webgl_set_clear_color(r, g, b, a) {
    gl.clearColor(r, g, b, a);
  },
  aether_webgl_set_alpha_blend(enabled) {
    enabled ? gl.enable(gl.BLEND) : gl.disable(gl.BLEND);
    cameraData.setUint32(156, enabled ? 1 : 0, true);
    uploadCameraUbo();
  },
  aether_webgl_set_depth_write(enabled) {
    gl.depthMask(enabled);
  },
  aether_webgl_set_culling(enabled) {
    enabled ? gl.enable(gl.CULL_FACE) : gl.disable(gl.CULL_FACE);
  },
  aether_webgl_set_uv_offset(u, v) {
    cameraData.setFloat32(160, u, true);
    cameraData.setFloat32(164, v, true);
    uploadCameraUbo();
  },
  aether_webgl_set_fog(enabled, start, end, r, g, b) {
    cameraData.setUint32(128, enabled ? 1 : 0, true);
    cameraData.setFloat32(132, start, true);
    cameraData.setFloat32(136, end, true);
    cameraData.setFloat32(144, r, true);
    cameraData.setFloat32(148, g, true);
    cameraData.setFloat32(152, b, true);
    uploadCameraUbo();
  },
  aether_webgl_set_proj_matrix(ptr) {
    setMat4Bytes(cameraBytes, 64, ptr);
    uploadCameraUbo();
  },
  aether_webgl_set_view_matrix(ptr) {
    setMat4Bytes(cameraBytes, 0, ptr);
    uploadCameraUbo();
  },
  aether_webgl_start_frame(width, height) {
    gl.viewport(0, 0, width, height);
    gl.clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT);
    return true;
  },
  aether_webgl_end_frame() {},
  aether_webgl_clear_depth() {
    gl.clear(gl.DEPTH_BUFFER_BIT);
  },
  aether_webgl_create_mesh() {
    const handle = nextMeshHandle++;
    const buffer = gl.createBuffer();
    const indexBuffer = gl.createBuffer();
    const vao = gl.createVertexArray();
    gl.bindVertexArray(vao);
    gl.bindBuffer(gl.ARRAY_BUFFER, buffer);
    gl.bindBuffer(gl.ELEMENT_ARRAY_BUFFER, indexBuffer);
    gl.enableVertexAttribArray(0);
    gl.enableVertexAttribArray(1);
    gl.enableVertexAttribArray(2);
    gl.vertexAttribPointer(0, 3, gl.SHORT, true, 16, 0);
    gl.vertexAttribPointer(1, 4, gl.UNSIGNED_BYTE, true, 16, 8);
    gl.vertexAttribPointer(2, 2, gl.SHORT, true, 16, 12);
    gl.bindVertexArray(null);
    meshes.set(handle, { buffer, indexBuffer, vao, vertexCount: 0, indexCount: 0 });
    return handle;
  },
  aether_webgl_destroy_mesh(handle) {
    const mesh = meshes.get(handle);
    if (!mesh) return;
    gl.deleteVertexArray(mesh.vao);
    gl.deleteBuffer(mesh.buffer);
    gl.deleteBuffer(mesh.indexBuffer);
    meshes.delete(handle);
  },
  aether_webgl_update_mesh(handle, vertexPtr, vertexLen, indexPtr, indexLen) {
    const mesh = meshes.get(handle);
    if (!mesh) return;
    gl.bindBuffer(gl.ARRAY_BUFFER, mesh.buffer);
    gl.bufferData(gl.ARRAY_BUFFER, copyBytes(vertexPtr, vertexLen), gl.STATIC_DRAW);
    gl.bindVertexArray(mesh.vao);
    gl.bindBuffer(gl.ELEMENT_ARRAY_BUFFER, mesh.indexBuffer);
    gl.bufferData(gl.ELEMENT_ARRAY_BUFFER, copyBytes(indexPtr, indexLen), gl.STATIC_DRAW);
    gl.bindVertexArray(null);
    mesh.vertexCount = vertexLen / 16;
    mesh.indexCount = indexLen / 2;
  },
  aether_webgl_draw_mesh(handle, modelPtr) {
    const mesh = meshes.get(handle);
    if (!mesh) return;
    if (mesh.vertexCount === 0) return;
    gl.useProgram(program);
    uploadPerObjectUbo(modelPtr);
    gl.bindVertexArray(mesh.vao);
    if (currentTexture) gl.bindTexture(gl.TEXTURE_2D, currentTexture);
    if (mesh.indexCount > 0) {
      gl.drawElements(gl.TRIANGLES, mesh.indexCount, gl.UNSIGNED_SHORT, 0);
    } else {
      gl.drawArrays(gl.TRIANGLES, 0, mesh.vertexCount);
    }
  },
  aether_webgl_create_texture(width, height, ptr, len) {
    const handle = nextTextureHandle++;
    const tex = gl.createTexture();
    textures.set(handle, { tex, width, height });
    gl.bindTexture(gl.TEXTURE_2D, tex);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.REPEAT);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.REPEAT);
    gl.texImage2D(
      gl.TEXTURE_2D,
      0,
      gl.RGBA,
      width,
      height,
      0,
      gl.RGBA,
      gl.UNSIGNED_BYTE,
      copyBytes(ptr, len),
    );
    return handle;
  },
  aether_webgl_update_texture(handle, ptr, len) {
    const texture = textures.get(handle);
    if (!texture) return;
    gl.bindTexture(gl.TEXTURE_2D, texture.tex);
    gl.texSubImage2D(
      gl.TEXTURE_2D,
      0,
      0,
      0,
      texture.width,
      texture.height,
      gl.RGBA,
      gl.UNSIGNED_BYTE,
      copyBytes(ptr, len),
    );
  },
  aether_webgl_bind_texture(handle) {
    const texture = textures.get(handle);
    currentTexture = texture ? texture.tex : null;
    gl.activeTexture(gl.TEXTURE0);
    gl.bindTexture(gl.TEXTURE_2D, currentTexture);
  },
  aether_webgl_destroy_texture(handle) {
    const texture = textures.get(handle);
    if (texture) gl.deleteTexture(texture.tex);
    textures.delete(handle);
  },
  aether_audio_init(sampleRate, maxSlots) {
    audioSampleRate = sampleRate;
    audioMaxSlots = maxSlots;
  },
  aether_audio_deinit() {
    for (const slot of audioSlots.keys()) host.aether_audio_stop_slot(slot);
    if (audioContext) audioContext.close();
    audioContext = null;
    gainRoot = null;
  },
  aether_audio_update() {},
  aether_audio_play_slot(slot, ptr, len, sampleRate, channels, bitDepth) {
    if (
      slot >= audioMaxSlots ||
      bitDepth !== 16 ||
      channels < 1 ||
      channels > 2
    )
      return false;
    host.aether_audio_stop_slot(slot);
    const rawBytes = copyBytes(ptr, len);
    const state = {
      rawBytes,
      sampleRate: sampleRate || audioSampleRate,
      channels,
      bitDepth,
      source: null,
      gain: null,
      pan: null,
      gainValue: 1.0,
      panValue: 0.0,
      active: true,
      started: false,
    };
    audioSlots.set(slot, state);
    if (audioContext && audioContext.state === "running")
      startAudioSlot(slot, state);
    return true;
  },
  aether_audio_stop_slot(slot) {
    const s = audioSlots.get(slot);
    if (s) {
      s.active = false;
      if (s.source) tryStop(s.source);
      audioSlots.delete(slot);
    }
  },
  aether_audio_set_slot_gain_pan(slot, gain, pan) {
    const s = audioSlots.get(slot);
    if (!s) return;
    s.gainValue = gain;
    s.panValue = pan;
    if (s.gain) s.gain.gain.value = gain;
    if (s.pan) s.pan.pan.value = pan;
  },
  aether_audio_is_slot_active(slot) {
    const s = audioSlots.get(slot);
    return !!s && s.active;
  },
};

function tryStop(source) {
  if (source)
    try {
      source.stop();
    } catch {}
}

function ensureAudioContext() {
  if (audioContext) return true;
  const AudioCtx = window.AudioContext || window.webkitAudioContext;
  if (!AudioCtx) return false;
  audioContext = new AudioCtx({ sampleRate: audioSampleRate });
  gainRoot = audioContext.createGain();
  gainRoot.connect(audioContext.destination);
  return true;
}

function startAudioSlot(slot, state) {
  if (!audioContext || !state.active || state.started) return;

  const raw = new Int16Array(
    state.rawBytes.buffer,
    state.rawBytes.byteOffset,
    Math.floor(state.rawBytes.byteLength / 2),
  );
  const frames = Math.floor(raw.length / state.channels);
  const buffer = audioContext.createBuffer(
    state.channels,
    frames,
    state.sampleRate,
  );
  for (let ch = 0; ch < state.channels; ch++) {
    const out = buffer.getChannelData(ch);
    for (let i = 0; i < frames; i++)
      out[i] = raw[i * state.channels + ch] / 32768;
  }

  const source = audioContext.createBufferSource();
  const gain = audioContext.createGain();
  const pan = audioContext.createStereoPanner();
  gain.gain.value = state.gainValue;
  pan.pan.value = state.panValue;
  source.buffer = buffer;
  source.connect(gain).connect(pan).connect(gainRoot);
  state.source = source;
  state.gain = gain;
  state.pan = pan;
  state.started = true;
  source.onended = () => {
    const current = audioSlots.get(slot);
    if (current === state) current.active = false;
  };
  try {
    source.start();
  } catch {}
}

function startQueuedAudio() {
  for (const [slot, state] of audioSlots) startAudioSlot(slot, state);
}

function resizeCanvas(defaultWidth = 1280, defaultHeight = 720) {
  const dpr = window.devicePixelRatio || 1;
  const w = Math.max(1, Math.floor((canvas.clientWidth || defaultWidth) * dpr));
  const h = Math.max(
    1,
    Math.floor((canvas.clientHeight || defaultHeight) * dpr),
  );
  if (canvas.width !== w || canvas.height !== h) {
    canvas.width = w;
    canvas.height = h;
  }
}

function mods(e) {
  return (
    (e.shiftKey ? 1 : 0) |
    (e.ctrlKey ? 2 : 0) |
    (e.altKey ? 4 : 0) |
    (e.metaKey ? 8 : 0)
  );
}

function mouseButtonCode(button) {
  switch (button) {
    case 0:
      return 0; // DOM left -> Aether Left
    case 2:
      return 1; // DOM right -> Aether Right
    case 1:
      return 2; // DOM middle -> Aether Middle
    default:
      return -1;
  }
}

function cancelMouseDefault(e) {
  e.preventDefault();
  e.stopPropagation();
}

const keyMap = {
  Space: 32,
  Quote: 39,
  Comma: 44,
  Minus: 45,
  Period: 46,
  Slash: 47,
  Semicolon: 59,
  Equal: 61,
  BracketLeft: 91,
  Backslash: 92,
  BracketRight: 93,
  Backquote: 96,
  Escape: 256,
  Enter: 257,
  Tab: 258,
  Backspace: 259,
  Insert: 260,
  Delete: 261,
  ArrowRight: 262,
  ArrowLeft: 263,
  ArrowDown: 264,
  ArrowUp: 265,
  PageUp: 266,
  PageDown: 267,
  Home: 268,
  End: 269,
  CapsLock: 280,
  ScrollLock: 281,
  NumLock: 282,
  PrintScreen: 283,
  Pause: 284,
  F1: 290,
  F2: 291,
  F3: 292,
  F4: 293,
  F5: 294,
  F6: 295,
  F7: 296,
  F8: 297,
  F9: 298,
  F10: 299,
  F11: 300,
  F12: 301,
  Numpad0: 320,
  Numpad1: 321,
  Numpad2: 322,
  Numpad3: 323,
  Numpad4: 324,
  Numpad5: 325,
  Numpad6: 326,
  Numpad7: 327,
  Numpad8: 328,
  Numpad9: 329,
  NumpadDecimal: 330,
  NumpadDivide: 331,
  NumpadMultiply: 332,
  NumpadSubtract: 333,
  NumpadAdd: 334,
  NumpadEnter: 335,
  NumpadEqual: 336,
  ShiftLeft: 340,
  ControlLeft: 341,
  AltLeft: 342,
  MetaLeft: 343,
  ShiftRight: 344,
  ControlRight: 345,
  AltRight: 346,
  MetaRight: 347,
  ContextMenu: 348,
};
for (let i = 0; i <= 9; i++) keyMap[`Digit${i}`] = 48 + i;
for (let i = 0; i < 26; i++)
  keyMap[`Key${String.fromCharCode(65 + i)}`] = 65 + i;

function installInput() {
  const sendText = (text) => {
    const data = textEncoder.encode(text);
    const ptr = instance.exports.aether_wasm_alloc(data.length);
    if (!ptr) return;
    bytes().set(data, ptr);
    instance.exports.aether_input_text(ptr, data.length);
    instance.exports.aether_wasm_free(ptr, data.length);
  };
  canvas.addEventListener("keydown", (e) => {
    if (!e.ctrlKey && !e.altKey && !e.metaKey && e.key && e.key.length === 1) {
      sendText(e.key);
    }
    const key = keyMap[e.code];
    if (key !== undefined) {
      instance.exports.aether_input_key(key, true, e.repeat, mods(e));
      e.preventDefault();
    }
  });
  canvas.addEventListener("keyup", (e) => {
    const key = keyMap[e.code];
    if (key !== undefined) {
      instance.exports.aether_input_key(key, false, false, mods(e));
      e.preventDefault();
    }
  });
  const canvasPoint = (e) => {
    if (document.pointerLockElement === canvas) {
      return { x: canvas.width * 0.5, y: canvas.height * 0.5 };
    }
    const r = canvas.getBoundingClientRect();
    const sx = canvas.width / r.width;
    const sy = canvas.height / r.height;
    return { x: (e.clientX - r.left) * sx, y: (e.clientY - r.top) * sy };
  };
  canvas.addEventListener("pointermove", (e) => {
    const p = canvasPoint(e);
    if (ignorePointerMoveCount > 0) {
      ignorePointerMoveCount--;
      instance.exports.aether_input_mouse_move(p.x, p.y, 0, 0);
    } else {
      instance.exports.aether_input_mouse_move(
        p.x,
        p.y,
        e.movementX,
        e.movementY,
      );
    }
  });
  canvas.addEventListener("pointerdown", (e) => {
    cancelMouseDefault(e);
    canvas.focus();
    if (
      requestedCursorMode === CURSOR_CAPTURED &&
      document.pointerLockElement !== canvas
    ) {
      canvas.requestPointerLock();
    }
    const button = mouseButtonCode(e.button);
    if (button < 0) return;
    const p = canvasPoint(e);
    instance.exports.aether_input_mouse_move(p.x, p.y, 0, 0);
    instance.exports.aether_input_mouse_button(button, true, p.x, p.y);
  });
  canvas.addEventListener("pointerup", (e) => {
    cancelMouseDefault(e);
    const button = mouseButtonCode(e.button);
    if (button < 0) return;
    const p = canvasPoint(e);
    instance.exports.aether_input_mouse_move(p.x, p.y, 0, 0);
    instance.exports.aether_input_mouse_button(button, false, p.x, p.y);
  });
  canvas.addEventListener("auxclick", cancelMouseDefault);
  canvas.addEventListener("contextmenu", cancelMouseDefault);
  canvas.addEventListener(
    "wheel",
    (e) => {
      instance.exports.aether_input_mouse_wheel(e.deltaX, -e.deltaY);
      e.preventDefault();
    },
    { passive: false },
  );
  window.addEventListener("focus", () =>
    instance.exports.aether_input_focus(true),
  );
  window.addEventListener("blur", () =>
    instance.exports.aether_input_focus(false),
  );
  document.addEventListener("pointerlockchange", () => {
    const wasLocked = pointerLocked;
    pointerLocked = document.pointerLockElement === canvas;
    ignorePointerMoveCount = 2;
    if (
      wasLocked &&
      !pointerLocked &&
      requestedCursorMode === CURSOR_CAPTURED
    ) {
      if (suppressNextPointerUnlock) {
        suppressNextPointerUnlock = false;
      } else {
        instance.exports.aether_input_key(KEY_ESCAPE, true, false, 0);
        pendingSyntheticEscapeUp = true;
      }
    }
    canvas.style.cursor =
      pointerLocked || requestedCursorMode === CURSOR_HIDDEN ? "none" : "";
  });
}

function pollGamepads() {
  const pads = navigator.getGamepads ? navigator.getGamepads() : [];
  const pad = pads && pads[0];
  if (pad) {
    pad.buttons
      .slice(0, 15)
      .forEach((b, i) =>
        instance.exports.aether_input_gamepad_button(i, b.pressed),
      );
    const axes = [
      pad.axes[0] || 0,
      pad.axes[1] || 0,
      pad.axes[2] || 0,
      pad.axes[3] || 0,
      pad.buttons[6]?.value || 0,
      pad.buttons[7]?.value || 0,
    ];
    axes.forEach((v, i) => instance.exports.aether_input_gamepad_axis(i, v));
  }
}

async function main() {
  try {
    resizeCanvas();
    await preloadResourceDirectory();
    const wasm = await WebAssembly.instantiateStreaming(
      fetch("./Aether.wasm"),
      {
        wasi_snapshot_preview1: WASI,
        aether_host: host,
      },
    );
    instance = wasm.instance;
    memory = instance.exports.memory;
    installInput();
    if (!instance.exports.aether_wasm_init(canvas.width, canvas.height))
      throw new Error("Aether init failed");
    setStatus("Running");
    const frame = () => {
      resizeCanvas();
      pollGamepads();
      const keepRunning = instance.exports.aether_wasm_frame();
      if (pendingSyntheticEscapeUp) {
        instance.exports.aether_input_key(KEY_ESCAPE, false, false, 0);
        pendingSyntheticEscapeUp = false;
      }
      if (keepRunning) requestAnimationFrame(frame);
      else setStatus("Stopped");
    };
    requestAnimationFrame(frame);
    window.addEventListener("resize", () => resizeCanvas());
    const resumeAudio = async () => {
      if (!ensureAudioContext()) return;
      await audioContext.resume();
      startQueuedAudio();
    };
    window.addEventListener("pointerdown", resumeAudio, { once: true });
    window.addEventListener("keydown", resumeAudio, { once: true });
  } catch (err) {
    console.error(err);
    setStatus(`Error: ${err.message}`);
  }
}

main();
