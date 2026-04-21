# Chez Scheme — Jerboa Performance & Feature Plan

Branch: `features/jerboa-perf`
Baseline: `07f3fd90 newhash: dispatch generic hashtable ops via sealed-record predicates`

## Landed

- `07f3fd90` newhash: core hashtable ops dispatch via sealed-RTD predicates
- `1c7da443` newhash: sealed-RTD dispatch extended to bulk / introspection ops
- `0cba64de` cptypes: statically specialize the seven hot R6RS hashtable ops (`ref/set!/contains?/delete!/update!`) to `#3%eq-hashtable-*` / `#3%symbol-hashtable-*` when first arg's subtype is known
- `c83b6fb1` cptypes: same specialization for `hashtable-cell` and `hashtable-ref-cell`
- `9e389cc7` plan: Phase 4 landed record
- `2df03b20` mats/cptypes.ms: regression-guard mat (`cptypes-hashtable-specialization`) asserting each of the seven ops rewrites at compile time
- `bench/jerboa-bench.ss`: baseline Jerboa-shaped workload bench
- Verified: `hash.mo`, `cptypes.mo`, `5_6.mo`, `record.mo` all clean

## Jerboa-side (companion changes in `~/jerboa`, landed)

Landed as `b5c0471 result/runtime: seal ok/err, macro-ize ~ dispatch`.
These pair with the Chez-side landings above:

- `lib/std/result.sls` — `result-ok` / `result-err` are now `sealed` and
  `nongenerative` with stable UIDs.  With the Chez sealed-RTD work, this lets
  cp0 fold `(ok? (ok x))` → `#t` and lets cptypes narrow `result?` to
  `ok?` / `err?` in each arm of a predicate `if`.
- `lib/jerboa/runtime.sls` — `~` is now an identifier macro that expands
  `(~ obj 'm arg ...)` directly to `(call-method obj 'm arg ...)`,
  eliminating one `apply` + rest-list allocation per method call.  A
  bare `~` still evaluates to a procedure value (`~proc`) for
  higher-order use.  The underlying `*method-tables*` is an
  eq-hashtable, which now flows through Chez's new
  `#3%eq-hashtable-ref` specialization.

Verified: `make build` clean, 65/65 reader, 68/68 core, 65/65 stdlib.
`(~ q 'norm)` confirmed to expand to `(call-method q 'norm)` with no
`apply` in the optimized output.

## Still out of scope

- **§3.3 full method-cache primitive** (beyond the `~` macro-ization):
  would need a per-call-site inline cache.  Skipping until a Jerboa
  workload profile identifies method dispatch as a measured hot spot
  beyond what the eq-hashtable specialization plus `~` inlining
  already buys.
- **§5.1 iterator fusion** — `for/collect` / `for/fold` deforestation
  is invasive; worth a dedicated session with before/after benchmarks
  on Jerboa workloads.
- **§6.1 regex literal promotion** — `(re <string>)` folding to a
  pre-compiled re-object would need the re-object to be
  FASL-serializable; unverified.
- **§10.2 CI perf-regression hook** — `.github/workflows/ci.yml`
  changes need explicit user sign-off.

## Context

Jerboa is a Gerbil-inspired Scheme dialect that sits on Chez. Its prelude funnels user code through a handful of hot primitives: hashtables, records (defstruct / defrecord / defclass), method dispatch (`~` / `{method obj ...}`), pattern matching (`match`), iterators (`for`, `for/collect`, `for/fold`), result types (`ok` / `err`), regex, and string ops. The commit above tightened hashtable hot-op dispatch from `case (xht-type)` to sealed-RTD predicates. This plan extends that approach across the rest of the surfaces Jerboa programs hit in a tight loop.

Everything below is scoped to **this repo only** — no changes to Jerboa itself or sibling repos.

---

## 1. Finish the hashtable dispatch tightening (quick wins)

`07f3fd90` covered the seven hot R6RS ops. The remaining `case (xht-type h)` sites in `s/newhash.ss` are cheap wins — same pattern, different functions.

### 1.1 Predicates
- `hashtable-weak?` (`s/newhash.ss:793`) — currently a 4-branch `case`. Replace with `(and (xht? h) (or (eq-ht? h) ...))` cascade. Trivial.
- `hashtable-ephemeron?` (`s/newhash.ss:802` area) — same shape.

### 1.2 Size / introspection
- `hashtable-size` (`s/newhash.ss:1089–1101`) — the eqv path adds two sizes; make it a `cond` with sealed predicates instead of `case`. Other paths become one-compare.
- `hashtable-hash-function`, `hashtable-equivalence-function` — short `case` dispatch, same rewrite.

### 1.3 Bulk ops (deprioritised)
- `hashtable-copy` (`s/newhash.ss:954`), `hashtable-clear!` (`s/newhash.ss:967`), `hashtable-keys` / `-values` / `-entries` / `-cells` (1025–1087). These are O(n) and dispatch cost is amortised, but the rewrite is mechanical and keeps the file internally consistent. Do it for hygiene, not for measurable win.

### 1.4 Regression guard
- Add a `mats/` bench (e.g. `mats/hash.ms`) that does ≥10M `hashtable-ref` / `hashtable-set!` on an eq-hashtable and records wall time. Fail on > ~10% regression vs a baseline captured after this plan lands. This prevents a future `case`-style rewrite from silently undoing `07f3fd90`.

**Estimated impact**: ~same dispatch savings as `07f3fd90` but in less-hot code paths. Ship in one commit.

---

## 2. Sealed-record dispatch audit across the tree

The `07f3fd90` idea generalises: any `case` on a type-tag symbol that could be a `cond` on sealed-RTD predicates is a candidate. Audit passes:

- `s/5_4.ss`, `s/5_6.ss`, `s/io.ss`, `s/port.ss` — look for `case (port-type …)` or `case (record-tag …)` forms.
- `s/syntax.ss` around the expander's internal record dispatch.
- `s/cp0.ss` / `s/cpnanopass.ss` — any `case` on node type where the subtypes are already sealed records.

For each site: measure with `jerboa_eval` or a Chez microbench before/after. Only rewrite sites with measurable cost; skip cold paths.

---

## 3. Record / method dispatch wins

Jerboa's `defstruct` / `defrecord` / `defclass` all expand to Chez `define-record-type` plus a small wrapper. Method dispatch (`{method obj args}` → `(~ obj 'method args)`) does a vtable lookup keyed by symbol.

### 3.1 Verify sealed-predicate inlining
Confirm cp0 actually inlines the `foo?` predicate generated by `(define-record-type foo (sealed #t) ...)` into a single RTD compare at use sites. Spot-check with `jerboa_expand_macro` on a known hot Jerboa function. If cp0 is leaving it as a call, that's a large latent win — fix in `s/cp0.ss` / `s/cpprim.ss` primitive-inliner rules.

### 3.2 Nongenerative UIDs for stable Jerboa types
Document (in Jerboa's cookbook, separate session) that `defstruct` types used in hot paths should be nongenerative with a stable UID so cp0 can constant-fold predicate checks across boot boundaries.

### 3.3 Method-cache primitive (feature)
If Jerboa's `~` does a symbol-keyed hashtable lookup per call, that's slow. Add a Chez-level monomorphic inline cache: a primitive `$method-cache-ref` that stores `(rtd, symbol) → proc` and invalidates on `define-method`. Wire Jerboa's `~` through it. This is the single largest potential win for OO-heavy Jerboa code.

Gate this on a measurement: if the cache already exists in Jerboa's prelude and is a hashtable, the win here is wrapping it as a sealed record with a fixed-size vector, not a full redesign.

---

## 4. Result type (`ok` / `err`) as sealed records

Jerboa's `ok` / `err` are currently (likely) tagged pairs or `cons`-based. cptypes (`s/cptypes.ss`) can't prove `ok?` / `err?` at call sites, so every `unwrap`, `and-then`, `map-ok`, `->?` does a runtime tag check.

### 4.1 Convert to sealed records
If `ok` / `err` become two sealed `define-record-type`s with a common parent `result?`, cptypes can:
- Prove `result?` at `and-then` / `map-ok` boundaries.
- Eliminate redundant predicate calls within a `->?` chain.
- Constant-fold `(ok? (ok x))` → `#t`.

This is a Jerboa-side change — out of scope for this repo — but **this plan should carry a cptypes enhancement** so that two sealed siblings under a sealed parent get treated as a discriminated union in the type lattice (`s/cptypes-lattice.ss`). That's the reusable payoff.

### 4.2 cptypes: discriminated-union lattice node
Add a lattice value `(disjoint-record rtd1 rtd2 …)` so a value typed as `result?` narrows to `ok?` or `err?` after a successful predicate test in one arm of an `if`. Mirrors how the expander already narrows booleans.

---

## 5. Iterator fusion (`for` / `for/collect` / `for/fold`)

Jerboa's `for/collect` expands to a `cons`-accumulating loop plus `reverse!`. For chained iterators (`for/collect` over a `filter-map` over an `in-list`), that's two allocations per element.

### 5.1 Deforestation in cp0
Teach cp0 to fuse `(for/collect ((x (in-list L))) (f x))` into a direct `map`. Start small: add rewrite rules for the three most common iterator heads (`in-list`, `in-vector`, `in-range`) paired with the three consumers (`for/collect`, `for/fold`, `for/or`).

This is invasive. Scope gate: do it behind a `fusion` parameter, off by default, measured on Jerboa benchmarks before merging.

### 5.2 `in-range` primitive
Recognise `(in-range N)` and `(in-range a b)` as special forms in the expander (Jerboa already does; confirm Chez preserves the shape). Lower to an unboxed fixnum loop directly in `cpnanopass.ss`.

---

## 6. Regex: compile-time literal pattern promotion

Jerboa's `(re "\\d+")` compiles the pattern at call time. For literal string arguments, this should happen once at compile time.

### 6.1 cp0 rewrite rule
Add a cp0 folder: `(re <constant-string>)` → a pre-compiled re-object embedded as a `quote`d constant. Requires the re-object to be `fasl`-serialisable (check this — if not, either fix serialisation or gate the rewrite on a `fasl-safe?` predicate).

### 6.2 SRE `rx` macro
`(rx <sexp>)` is already a macro; verify it fully expands and the resulting re-object is embedded at expand time, not recomputed. This is a check, not a change, if it already works.

---

## 7. String ops Jerboa hits hard

- `string-split` with a char delimiter — the common case. Ensure Chez inlines the char-comparison loop rather than going through a generic predicate. Check in `s/5_6.ss` equivalents.
- `string-contains` returning an index — already a single pass; leave alone.
- `str` (Jerboa's auto-coercing concat) — driven by `number->string` / `display` per argument. If profiling shows pressure here, add a `$fast-num->string` for fixnums (probably already inlined; confirm).

Low-priority section. Only touch if profiling a real Jerboa workload points here.

---

## 8. Primitive-inliner gaps (`s/cpprim.ss`)

Skim `s/cpprim.ss` for primitives that Jerboa's prelude calls frequently but that lack an inlined rule. Candidates:
- Bitwise ops under `ash` / `bitwise-arithmetic-shift` — confirm both Chez names inline identically.
- `fx+` / `fx-` variants in hot loops — already inlined; confirm for fixnum-typed args flowing through cptypes.
- `hashtable-ref` with a constant default — after `07f3fd90`, the dispatch is a single RTD compare, but cp0 should further fold when the hashtable type is known at the call site. Check.

Each gap found: single-line rewrite rule. Cheap.

---

## 9. FFI / boundary

If Jerboa uses FFI heavily (and its cookbook suggests it does — `std/crypto/digest`, `std/net/request`), check:
- `c/ffi.c` for per-call marshalling allocations.
- `foreign-procedure` declarations — confirm Jerboa's FFI wrappers use typed signatures so the foreign call site doesn't need runtime type dispatch.

No concrete change yet; add profiling hooks (below) first, then act on data.

---

## 10. Benchmarks & regression infrastructure (feature)

The biggest missing piece: **there is no Jerboa-oriented benchmark set in this repo**. Without it, every perf change is guesswork.

### 10.1 Benchmark set
Add `mats/jerboa-bench.ms` (or a sibling `bench/` directory — check convention). Cover:
- Hashtable ref/set/update in a tight loop.
- Record predicate + field access.
- Generic method dispatch (simulate Jerboa's `~`).
- `for/collect` over `in-range` — iterator cost.
- `match` on a 10-arm sealed-record dispatch.
- `string-split` + `string-join` round trip.
- Regex search over a 1 MB buffer.

Each bench prints elapsed ms. Harness runs N iterations, reports median.

### 10.2 CI hook
Extend `.github/workflows/ci.yml` with a `bench` job that runs on `features/jerboa-perf` and comments a delta vs `main` on each PR. Optional but closes the loop on §1.4.

---

## 11. Documentation & feature-tracking

- Update `release_notes/release_notes.stex` as changes land. Chez convention is one entry per user-visible change.
- Register new primitives (if any — e.g. `$method-cache-ref` in §3.3) in `s/primdata.ss`. This is mandatory per `CLAUDE.md`.
- Write each win up as a Jerboa cookbook recipe (via `jerboa_howto_add`, separate session) so the Jerboa side learns what Chez now guarantees.

---

## Proposed execution order

| Phase | Item | Effort | Risk | Measurable win |
|-------|------|--------|------|----------------|
| 1 | §1.1 – §1.3 newhash cleanup | low | low | small but real |
| 2 | §10.1 bench set | low | low | unblocks everything else |
| 3 | §3.1 sealed-predicate inlining verification | low | low | large if broken |
| 4 | §4.2 cptypes disjoint-record lattice | medium | medium | large for result-heavy code |
| 5 | §6.1 regex literal promotion | low–medium | low | medium |
| 6 | §3.3 method-cache primitive | medium | medium | potentially largest win |
| 7 | §5.1 iterator fusion | high | high | medium, but invasive |
| 8 | §1.4 + §10.2 regression CI | low | low | keeps gains |

Each phase ships as an independent commit (or small series) with its own benchmark delta recorded in the commit message. Phases 1–3 are safe to land quickly. Phases 4+ want measurement first.

---

## Non-goals

- Rewriting the GC or allocator. `c/gc.c` is well-tuned; no Jerboa-specific win identified.
- Changing FASL format. Out of scope and cross-cuts boot files.
- New syntax in Chez. All Jerboa features live in Jerboa; Chez stays minimal.
- Touching sibling repos (`jerboa-emacs`, `jerboa-mcp`, etc.). Per `CLAUDE.md`, hands off.

---

# Round 2 — follow-on work after Phases 1–7 landed in Jerboa

Phases 1–7 in Jerboa (`~/jerboa`, commits `b5c0471` … `8dc2d71`) landed
the Jerboa-side user-visible wins: sealed structs, match RTD-dispatch,
str literal folding, regex memoization, iterator fusion, single-pass
kwargs, and prelude WPO. The remaining wins are mostly Chez-side
(primitive folds that make the Jerboa work propagate through the
compiler) plus a few Jerboa-side items that were left out the first
time.

Ordering rationale: land the benchmark harness first so every later
commit can carry a concrete delta. Then the Chez sealed-RTD predicate
fold, since that's the single largest multiplier on the Jerboa sealed
structs already in place.

## Phase 8 — Jerboa bench harness + regression gate

Add `~/jerboa/tests/bench-suite.ss` running the micro-benchmarks used
during Phases 1–7 (sealed-struct dispatch, match, str, regex memoize,
for/collect fusion, kwargs, hashtable ops, method dispatch). Each
bench runs N iterations, reports median ns/op. A companion script
diffs against a committed baseline JSON and exits nonzero on > 10%
regression.

Without this, the Phases 1–7 wins silently erode. Also required for
any Round 2 phase that claims a measured speedup.

## Phase 9 — Chez: sealed-RTD record-predicate fold

**Investigated: Chez already folds this correctly.** Verified via two
paths:

1. `expand/optimize` on
   `(let () (define-record-type pt (nongenerative pt-uid) (sealed #t) (fields x)) (lambda (v) (pt? v)))`
   produces `(lambda (v) (#3%$sealed-record? v '#<record type pt-uid>))`.
   The fold is done by the `define-inline 2 record-predicate` rule in
   `s/cp0.ss` (line 3723) — it detects sealed RTDs and emits
   `$sealed-record?` at primref level 3, which `s/cpprim.ss`
   (`build-sealed-isa?`, line 8308) lowers to a single typed-object
   tag check plus an `eq?` against the literal rtd.

2. Micro-bench (`tmp/phase9-lib-bench.ss`) inside a library at
   optimize-level 3: user predicate `point?` and direct
   `#3%$sealed-record?` both clock 1.09 ns/op — identical. Safe mode
   (level 2): both 1.80 ns/op. No gap.

The only case where the fold doesn't apply is top-level script
definitions (cp0 conservatively won't inline top-level `define` RHS
in case someone rebinds). That's not a real workload — Jerboa code
lives in libraries.

**Deliverable:** regression mat `cptypes-sealed-record-predicate-fold`
in `mats/cptypes.ms` that pins the behavior so a future cp0/cpprim
change can't silently un-fold it.

No code changes to `s/cp0.ss` or `s/cpprim.ss` needed.

## Phase 10 — Chez: cptypes specialize bytevector/string ops

**Investigated: the win here is narrower than the hashtable case.**
Chez's generic `fold-primref/try-unsafe` (s/cptypes.ss:1997) already
promotes any primitive flagged `safeongoodargs` in `s/primdata.ss`
when cptypes has proved every argument's type matches its declared
predicate. This covers the bytevector/string ops whose signatures
don't include a runtime range:

  `string-length`, `bytevector-length`, `string-copy`,
  `bytevector-copy`, `string->list`, `bytevector->u8-list`,
  `string-append`, `string->symbol`

Each of these already rewrites to `#3%`-prefixed at compile time when
the source arg's type is proved (e.g. the result of
`make-string`/`make-bytevector`).

The remaining ops — `bytevector-u8-ref`, `string-ref`,
`bytevector-u8-set!`, `string-set!`, `bytevector-u16-native-ref`, …
— are not flagged `safeongoodargs` because their signatures include
`sub-index`: the level-2 check is a fused type-plus-bounds check, and
the level-3 variant elides both. Promoting them when only the type is
proved (i.e., without an in-range index) would introduce memory
corruption. Truly specializing them requires compile-time bounds
analysis — the index must be proved in `[0, (bytevector-length bv))` —
which cptypes does not yet do.

**Deliverable:** regression mat
`cptypes-bytevector-string-safeongoodargs-promotion` in
`mats/cptypes.ms` pinning the eight ops listed above. Also retains
the out-of-scope boundary: we do not specialize indexed ops in this
phase.

No code changes to `s/cptypes.ss`, `s/cpprim.ss`, or `s/primdata.ss`
needed.

**Follow-on (deferred):** compile-time bounds analysis for
bytevector/string indexed ops. A clean separation would be a new
primitive flag (say `safeongoodtypes`) and matching per-primitive
specializer that keeps the bounds check but drops the type check when
the first arg's type is proved. Tracked separately from this phase.

## Phase 11 — Chez: type narrowing through user predicates

`(and (foo? x) (bar x))` should let `bar` see `x:foo` inside the
`and`. Today cptypes narrows through a handful of built-in predicates
(number?, pair?, etc.) — extend to any `record-predicate` derived from
a sealed+nongenerative RTD so the Phase 1 structs benefit.

Depends on Phase 9 (the fold has to land first so cptypes sees the
primitive operation).

## Phase 12 — Jerboa: method-dispatch inline cache

`(~ obj 'method ...)` currently does an eq-hashtable lookup per call
(see `runtime.sls`'s `call-method`). Add a per-call-site monomorphic
cache — one-entry PIC keyed on RTD. On hit, direct call; on miss,
fall back to the hashtable and update the cache.

Expand `~` to wrap the call site in a cache cell. The generated code:

    (let ([cache-rtd #f] [cache-proc #f])
      (lambda (obj . args)
        (let ([r (record-rtd obj)])
          (if (eq? r cache-rtd)
              (apply cache-proc obj args)
              (%slow-dispatch-and-cache obj 'method args)))))

Benchmark target: 5–10x on hot method-heavy loops.

## Phase 13 — Jerboa: fuse `in-hash-keys`/`in-hash-values`

Phase 5 already fuses `in-range`/`in-vector`/`in-string`/`in-list`.
Extend the same macro dispatch to `(in-hash-keys ht)` and
`(in-hash-values ht)` by iterating via `hashtable-keys`/`-entries`
directly into the loop body instead of materializing the key/value
list first.

Mechanical extension of existing Phase 5 machinery.

## Phase 14 — Jerboa: decision-tree match compiler

Current `match2` emits a linear chain of clause tests. Runs of
patterns sharing a prefix (same tag, same list length) each re-check
the whole prefix. Replace with a decision-tree compiler that factors
common prefixes.

Biggest win on large `match` forms (parsers, evaluators). Least
urgent of the Round 2 set.
