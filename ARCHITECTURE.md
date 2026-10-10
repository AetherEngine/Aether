# Core and Platform

Aether has two top-level source directories and two Zig build modules. `core/`
implements the game engine using `platform/`, which supplies device services and
the low-level contracts shared with Core. `core/root.zig` is the public facade;
it keeps the existing top-level API names as aliases of the modules exported by
`core/core.zig`.

```text
Game code -> aether module (core/root.zig) -> platform module -> target backends
```

Core imports the named module with `@import("platform")`. Its build dependencies
include Platform and shared configuration options. Platform owns backend SDK
imports such as SDL3, OpenGL, Vulkan, pspsdk, and zitrus, along with generated
shader modules and native library configuration. Target selection and SDK setup
are wired in `build/modules.zig`; game code continues importing `aether`.
Executable roots in `platform/root/` compose the application and engine at
startup; see [Targets and entry](#targets-and-entry).
The test step runs Core and Platform in separate test runners so tests inside
the named Platform dependency remain covered.

## Ownership

| Location | Responsibility |
| --- | --- |
| `core/engine.zig`, `core/State.zig`, `core/state_machine.zig` | Subsystem lifetime, frame scheduling, state transitions, memory accounting |
| `core/app_options.zig` | Application configuration |
| `core/input/` | Actions, bindings, contexts, capture, text editing sessions, event evaluation, display labels, and versioned binding records |
| `core/rendering/` | Mesh/texture ownership, CPU mesh editing, texture loading, cameras/frustums, flipbooks, and billboard batches |
| `core/audio/` | Borrowed/owned streams, buffer and streaming WAV parsing, voices, software mixing, spatial audio |
| `core/ui/` | Widget state/layout, input adaptation, ordered draw lists, clipping, prompts, text wrapping, sprite/font batching, and atlases |
| `core/resources/` | Borrowed asset-source contracts, independent reader owners, and staged decoded asset stores |
| `core/storage.zig`, `core/jobs.zig` | Replacement-write/JSON ownership and bounded serial job execution |
| `core/util/` | Image decoding/regions, indexed ZIP readers, budget configuration, estimates, and public utility aliases |
| `platform/backend.zig` | Target selection and the headless device overlay |
| `platform/gfx.zig`, `surface.zig`, `audio.zig`, `input.zig`, `thread.zig`, `network.zig`, `system.zig`, `paths.zig`, `entry.zig` | One file per subsystem: the backend contract, its error sets, and dispatch to the selected backend, checked at compile time |
| `platform/io.zig` | `AetherIo`, the `std.Io` every application receives |
| `platform/graphics/` | Mesh/texture handles and descriptors, vertex layouts/position encoding, render state, pixel formats |
| `platform/input/` | Device identifiers, raw events, frame storage, event sink, native text input requests |
| `platform/math/` | Shared vectors, matrices, quaternions, bounds, ray/sweep queries, and frustum calculations |
| `platform/util/` | Pool allocation, generational handles, resource tables, circular buffers, logging helpers |
| `platform/logging.zig`, `platform/logging/` | Logging |
| `platform/<target>/` | One folder per target (`desktop`, `psp`, `3ds`, `switch`, `wasm`): process entry, base Io facts, native threads, directories, network sessions, public native services, and devices |
| `platform/headless/` | Device overlay (graphics, surface, input, audio) usable on any target |
| `platform/root/` | Executable roots: the declarations std and target SDKs read from `@import("root")` |
| `platform/shaders/` | Shared built-in shader sources; target-specific shaders stay under their target |
| `build/packaging.zig` | Target artifact packaging and copying application-supplied resources |

Math and storage primitives belong to Platform because both backends and Core
use them. They have no dependency on engine objects. Core exposes them through
`Core.Math` and `Core.Util` so applications retain convenient access.

## Targets and entry

Every target folder has the same shape. `backend.zig` is its manifest; the
other files implement one contract each:

| File | Contract |
| --- | --- |
| `entry.zig` | Process start: native services, `std.process.Init`, and the application's `main` (`entry.Interface`) |
| `io.zig` | Path limits, rename behavior, and where `async`/`concurrent` tasks run |
| `thread.zig` | Native threads and priorities (`thread.Interface`) |
| `system.zig`, `paths.zig`, `network.zig` | Hardware facts, application directories, network sessions |
| `native.zig` | Target services exposed as `aether.Psp`, `aether.N3ds`, or `aether.Web` |
| `gfx`, `surface.zig`, `input.zig`, `audio.zig` | Devices; `texture_pixels` names the CPU texture layout |

Target-private helpers sit beside these files (for example `psp/dialogs.zig`,
`switch/deko.zig`, `desktop/vulkan/`). `headless/` provides only devices:
`-Dgfx=headless` replaces graphics, surface, and input, and `-Daudio=none`
replaces audio, while process services, Io, and threads stay the target's own.

Each executable's root module is `platform/root/<target>.zig`. It declares what
std and the target SDK read from `@import("root")` and calls the target's
`entry.zig`, which runs the application's `pub fn main(std.process.Init)`. The
application never supplies an entry point, panic handler, or std options of
its own; `aether_options` configures them.

`init.io` is an `AetherIo` on every target: the target's base Io, completed
where it lacks concurrency. Each target's `io.zig` declares where tasks run.
Where the base Io implements `async`, `concurrent`, and groups (std.Io.Threaded
on desktop, pspsdk's Io, the browser's single-threaded Io, Zitrus' Horizon Io),
the application receives that Io unchanged, including its cancellation. Switch's
newlib Io has none, so AetherIo forwards every other operation and runs tasks on
libnx threads; those tasks cannot be interrupted, so `cancel` waits like `await`.

The browser has one JS event-loop thread, and Zitrus' Horizon Io (3DS) runs
`async` inline with no `concurrent` or groups. Native threads remain available
through `Util.Thread` on every target but the browser, including 3DS, with
explicit names, stack sizes, and priorities; `Util.PriorityScope` changes the
calling thread's priority. `System.info().background_workers` reports whether
`Util.Thread` can spawn. Jobs executors and engine workers (logging, 3DS audio)
use these threads.

The browser drives frames, so `main` must not block. It initializes and calls
`Engine.run`, which hands the loop to the page and returns. Keep the Engine and
its memory in static storage; the page calls `Engine.deinit` through the host
when it stops the loop.

## Data crossing the boundary

Graphics backends accept handles, upload descriptors, matrices, and render state.
They do not own Core's editable meshes, image loader, camera, or default texture.
Core resolves an omitted render-state texture to its default before submitting
the state. Code calling the low-level `gfx.api.set_render_state` directly must
supply an actual texture handle when drawing textured geometry.

Backends compare RenderState fields before emitting GPU work. State caches belong
to the backend, alongside texture update/destruction and command-buffer lifetime
handling. Fresh Vulkan, Switch, and 3DS command buffers still establish their
required state. OpenGL and WebGL defer shared uniform uploads until drawing, so
several changed fields share one upload. PSP batches a state transition into one
stall-address update and preserves bindings across its display lists. Each 3DS
screen owns its fog table; recording resets invalidate bindings while retaining
the generated table until its depth/fog range changes.

Input backends translate device events into a Platform-owned event sink. Core
adapts that sink to `InputSystem`, accumulates frames, and evaluates actions.
Native keyboards receive a plain request and report a result through the sink;
text editing sessions and their callbacks remain Core responsibilities. The sink
borrows its receiver, so the receiver must remain alive at a stable address until
input has been detached. `Engine` manages that lifetime.

Audio backends consume PCM and slot source contracts from `audio.zig`. Core
owns sound loading, mixing, voices, and spatial calculations. Platform logging
and threads can therefore be used by audio and graphics backends without
depending on the engine utility barrel.

Resource sources are borrowed interfaces; each open transfers an independent
reader owner. Core's archive and WAV adapters keep decoder state at stable
addresses. Owned audio streams release these readers only after backend access
has stopped. Asset stores close loader readers after decoding and stage all
requested values before replacing one store's active set. Source retirement and
transactions across stores/audio remain application responsibilities.
Resource-pack conventions, asset names, archive creation, and pack selection
also belong to applications. ZIP readers and resource stores impose no pack
format or game asset schema.

UI contexts own interaction policy over existing input text sessions. Draw lists
copy labels and prepare geometry in insertion order. Ordinary geometry clips in
Core; custom renderers explicitly advertise and implement partial clipping.
Prepared geometry owns its meshes and borrows textures and renderer state.
Engine text is literal by default. Applications supply any markup parser and
color palette; markup syntax and continuation rules are not engine policy.

Core storage helpers choose Platform's rename behavior and own temporary/backup
file cleanup. Core job executors own their queues and completion protocol while
borrowing jobs and callback inputs. Thread creation, native priorities, cwd
inheritance, networking SDK calls, and browser download integration remain in
Platform. Hardware capabilities describe mechanisms, not application budgets or
quality choices.

## API compatibility

The high-level `aether.Engine`, `Core.InputSystem`, `Audio`, `Rendering`, `Ui`,
`Util`, and `Math` entry points remain available. Source files have moved, so
code importing implementation files by relative path must use their new paths.
`Resources`, `Storage`, `Jobs`, `System`, and `Network` are available through both
Core and the public facade. Their source declarations document ownership,
validation, and lifetime requirements. Browser file export moved to
`aether.Web.FileExport`.

Custom input backends must implement the sink/request signatures in
`PlatformApi.input.Interface`. Engine-managed input attaches these services
through `InputSystem.init_platform` and detaches them with `deinit_platform`.
The optional mesh-update diagnostic flag is now
`Rendering.validate_mesh_updates_outside_frame`; frame synchronization remains
in Platform. Direct graphics backend callers must follow the explicit texture
handle contract described above.

## Dependency rules

- Put new gameplay-facing behavior and ownership in Core. Put SDK calls, native
  layouts, device operations, and the data needed to describe them in Platform.
- Define shared types at the lower layer and alias them from Core when needed.
  Do not duplicate a handle or enum type on both sides of the boundary.
- Core imports shared services/contracts through `@import("platform")`. Do not
  reach across the source directories with relative imports. Backend selection
  belongs to Platform; Core must not import a target implementation directly.
- Attach backend SDK dependencies and generated shaders to the Platform build
  module. Keep Core's dependency on the named Platform module explicit.
- Platform backends must not import Core, the public engine root, or an engine
  module by name. Extend the contract or add a callback when a backend needs to
  report something to Core.
- Executable roots are composition points and separate modules. Files in
  `platform/root/` reach Platform and the application only by module name:
  `root/common.zig` imports `aether` and the application root to validate it and
  adapt its `main`; each target root imports `platform` and that adapter. No
  other file imports a root, and roots import no files by path.

`zig build check-architecture` checks the source tree and import direction for
every target, including targets whose SDKs are unavailable on the current host.
It runs automatically with `zig build test` and `zig build lint`. It checks source
dependencies; target builds are still required to validate backend interfaces.

## Validation

Run the relevant checks with Zig 0.17.0 or newer. Console targets require the
listed SDKs and tools in addition to the Zig package dependencies.

| Command | Coverage / toolchain |
| --- | --- |
| `zig build` | Vulkan desktop build |
| `zig build test` | Desktop unit tests and architecture checks |
| `zig build test -Dgfx=headless -Daudio=none` | Headless unit tests and architecture checks |
| `zig build test-api -Dgfx=headless -Daudio=none` | CPU geometry, worker cwd setup, Io task/group, and serial job lifetime probes on the host |
| `zig build check-api` | Compile public service, resource, audio, UI, and rendering probes; accepts the same target flags as the sample build |
| `zig build -Dgfx=opengl` | OpenGL desktop build |
| `zig build web` | WASM/WebGL bundle, using Slang and spirv-cross |
| `node --test tools/test_web_render_state.mjs` | WebGL command-recording tests for uniforms, texture updates, and depth clears |
| `node --test tools/test_web_file_export.mjs` | Virtual file export bytes, filename/MIME, initiation failure, and URL cleanup |
| `zig build -Dtarget=mipsel-psp` | PSP build, using Zig and the Zig-PSP/pspsdk package tools |
| `zig build -Dtarget=arm-3ds` | 3DS build, using Zig and the zitrus package/toolchain |
| `zig build -Dtarget=aarch64-switch` | Switch build, using devkitA64, libnx, and uam |
| `zig build lint` | Lint and architecture scan |

Browser API probes use `zig build check-api -Dtarget=wasm32-wasi
-Dcpu=baseline+atomics+bulk_memory`. The native/GPU probe exports compile without
being executed by `test-api`; they require a separately initialized harness.
Target compilation does not verify console hardware behavior or visual output.
