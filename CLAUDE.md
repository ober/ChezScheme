# Chez Scheme - CLAUDE.md

## Project Overview

Chez Scheme (v10.4.0) is a self-hosting Scheme compiler and runtime. The compiler is written mostly in Scheme (`s/`), with a C runtime kernel (`c/`) for GC, OS interaction, and performance-critical operations. It supports 7+ architectures and 10+ operating systems.

**License**: Apache 2.0

## Build Commands

```bash
./configure                # Detect platform, create workarea (e.g. ta6le/)
make                       # Full build: C kernel + Scheme bootstrap
make kernel                # Build only the C kernel (fast)
make run                   # Run built scheme without installing
make install               # Install to system (default /usr)
make uninstall             # Remove installation
```

### Testing

```bash
make test-one              # Single quick smoke test
make test-some-fast        # Fast representative set (no interpreter)
make test-some             # Representative set
make test                  # Standard full test suite (~1 hour)
make test-more             # Comprehensive including slow tests
```

Tests can run in parallel with `-j`. From inside a workarea (e.g. `ta6le/`):
```bash
zuo . 7.mo                 # Run tests from mats/7.ms
zuo . o=0                  # Test in safe mode (catches errors)
zuo . o=3                  # Test in unsafe mode (optimized)
```

### Cross-Compilation

```bash
./configure --pb && make bootquick XM=<target>  # Create boot files via portable bytecode
./configure --cross --force -m=<target> && make  # Build for target
```

### Documentation

```bash
make docs                  # Generate HTML/PDF docs
make csug                  # User's Guide only
make release_notes         # Release notes only
```

## Repository Structure

### Core Source

| Directory | Contents |
|-----------|----------|
| `s/` | Scheme compiler and libraries (~125 files, ~136K lines) |
| `c/` | C runtime kernel and GC (~63 files, ~26K lines) |
| `boot/` | Pre-compiled boot files for bootstrapping (pb/, ta6le/, etc.) |
| `mats/` | Test suite (~80 `.ms` test files) |

### Key Scheme Files (`s/`)

| File | Purpose |
|------|---------|
| `cmacros.ss` | Object layouts, global constants (shared with C kernel) |
| `primdata.ss` | **All bindings must be declared here** |
| `syntax.ss` | Hygienic macro expander |
| `cpnanopass.ss` | Main compiler (nanopass framework, ~600KB) |
| `cpprim.ss` | Primitive inlining (~427KB) |
| `cp0.ss` | Constant propagation optimizer (~308KB) |
| `cptypes.ss` | Type lattice and inference |
| `cpletrec.ss` | Letrec optimization |
| `compile.ss` | User-facing compilation interface |
| `x86_64.ss`, `arm64.ss`, `arm32.ss` | Architecture-specific backends |
| `*.def` | Platform-specific constants and backend selection |
| `5_1.ss`–`5_7.ss`, `6.ss`, `7.ss` | Standard library procedures |
| `bytevector.ss` | Bytevector operations |
| `cafe.ss` | REPL implementation |
| `expeditor.ss` | Interactive expression editor |
| `back.ss` | Backend code generation support |
| `base-lang.ss`, `expand-lang.ss` | Language definitions for nanopass |

### Key C Files (`c/`)

| File | Purpose |
|------|---------|
| `gc.c` | Generational garbage collector (132KB) |
| `scheme.c` | Core runtime system |
| `fasl.c` | Fast-load serialization format |
| `prim5.c` | 500+ primitive operations |
| `expeditor.c` | C side of expression editor |
| `number.c` | Numeric operations |
| `io.c`, `new-io.c` | I/O subsystem |
| `ffi.c`, `foreign.c` | Foreign Function Interface |
| `main.c` | Entry point |
| `alloc.c` | Memory allocation |
| `intern.c` | Symbol interning |
| `compress-io.c` | Compression support (zlib/lz4) |
| `system.h` | Core system definitions and types |

### Supporting Directories

| Directory | Contents |
|-----------|----------|
| `nanopass/` | Nanopass compiler framework (submodule) |
| `zuo/` | Zuo build system (submodule) |
| `zlib/`, `lz4/` | Compression libraries (submodules) |
| `stex/` | Documentation tooling (submodule) |
| `unicode/` | Unicode data tables |
| `csug/` | Chez Scheme User's Guide (`.stex` format) |
| `release_notes/` | Release notes (`.stex` format) |
| `examples/` | Example Scheme programs |
| `makefiles/` | Build system templates and utilities |
| `tools/` | Utility scripts (e.g. `gen-static-ffi.sh`) |
| `wininstall/` | Windows installer scripts |
| `rpm/`, `pkg/` | Package management files |

### Workarea Directories

Build outputs go into machine-specific workareas (not in-source):
- `ta6le/` — Threaded AMD64 Linux (primary dev platform)
- `pb/` — Portable bytecode
- `xc-ta6le/` — Cross-compilation outputs

## Machine Type Naming Convention

Format: `[t]<arch><os>` where `t` = threaded

| Code | Meaning |
|------|---------|
| `t` prefix | Threaded build |
| `i3` | x86 32-bit |
| `a6` | x86-64 |
| `arm32` | ARM 32-bit |
| `arm64` | ARM 64-bit |
| `ppc32` | PowerPC 32-bit |
| `rv64` | RISC-V 64-bit |
| `la64` | LoongArch 64-bit |
| `pb` | Portable bytecode |
| `le` | Linux |
| `nt` | Windows |
| `osx` | macOS |
| `fb` | FreeBSD |
| `ob` | OpenBSD |
| `nb` | NetBSD |
| `s2` | Solaris |

Example: `ta6le` = threaded, AMD64, Linux

## Compilation Pipeline

```
Source (.ss) → Syntax Expansion (syntax.ss) → Macro Expansion (cmacros.ss)
  → Type Analysis (cptypes.ss) → Optimization (cp0.ss, cpletrec.ss)
  → Nanopass Compiler (cpnanopass.ss) → Backend (x86_64.ss, arm64.ss, ...)
  → Machine Code → FASL format (.so/.boot)
```

## Coding Conventions

### Scheme Style
- 2-space indentation (consistent throughout)
- Naming: `?` suffix for predicates, `!` for mutations, `$` prefix for internal helpers
- Comments: `;;;` for section headers, `;;` for code-level comments
- All bindings registered in `primdata.ss`
- Internal helpers prefixed with `$` and registered as system-level in `primdata.ss`
- Shorter code is preferred — quality is inversely proportional to code size
- Study existing code for consistent structure and indentation

### C Style
- Custom pointer types: `ptr` (Scheme object), `iptr` (signed machine word), `uptr` (unsigned machine word)
- Macro-heavy for bit manipulation and object access
- Apache 2.0 license header on every file
- Static function declarations at file top
- `system.h` is the primary header; `scheme.h` and `equates.h` are generated by the Scheme compiler

### Testing Conventions
- Tests in `mats/*.ms` files using `mat` macro
- Each test is an expression returning `#t` for success
- Use `error?` form for expected exceptions
- Expected errors tracked in `root-experr-*` and `patch-*` files
- Test configurations encode: `[compile|interpret]-[0|3]-[f|t]-[f|t]-[f|t]`
  - Mode, optimization level (0=safe/3=unsafe), suppress-prim-inlining, cp0, compile-interpret-simple
- More test code than implementation code is expected for new features

## Adding New Functionality

1. If possible, implement purely in Scheme in the appropriate `s/*.ss` file
2. **All bindings must be declared in `primdata.ss`** — this is mandatory
3. Internal helpers: prefix with `$`, register as system-level in `primdata.ss`
4. Implement as safe (check arguments fully); code will be compiled as unsafe
5. Test with `zuo . o=0` in safe mode to catch argument errors
6. Write comprehensive tests in `mats/*.ms`
7. Update documentation in `csug/*.stex` and `release_notes/release_notes.stex`
8. Bootstrap considerations: declarations can be added before implementation; use `make re.boot` if stuck

## Contributing Guidelines

- Include tests and documentation with all code changes
- Consistency with existing code style is critical
- Performance matters — benchmark when changes might affect it
- Features should be minimal and generally applicable (avoid feature bloat)
- Consider publishing significant extensions as independent projects
- All contributions under Apache 2.0

## CI/CD

GitHub Actions workflow (`.github/workflows/ci.yml`) tests across 14+ configurations:
- Linux: i3le, ti3le, a6le, ta6le (+ re-bootstrap + extended test variants)
- macOS: a6osx, ta6osx, arm64osx, tarm64osx
- Windows: i3nt, ti3nt, a6nt, ta6nt (VS and GCC toolchains)
- Portable: tpb
- 60-minute timeout per test run

## Submodules

| Submodule | Repository |
|-----------|------------|
| `zuo` | github.com/racket/zuo |
| `nanopass` | github.com/nanopass/nanopass-framework-scheme |
| `zlib` | github.com/madler/zlib |
| `lz4` | github.com/lz4/lz4 |
| `stex` | github.com/dybvig/stex |

## Bootstrap Model

Chez Scheme is self-hosting — it requires an existing Chez Scheme to build itself. The bootstrap chain:
1. Pre-compiled boot files in `boot/` (or portable bytecode in `boot/pb/`)
2. C kernel compiled first → `scheme` executable
3. Existing scheme compiles Scheme sources → new boot files
4. New boot files used for next-generation bootstrap

Portable bytecode (`pb`) allows bootstrapping on any platform without pre-existing native boot files.
