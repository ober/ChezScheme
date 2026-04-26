# Chez Scheme — Jerboa Performance & Feature Plan

Branch: `features/jerboa-perf`
Baseline: `07f3fd90 newhash: dispatch generic hashtable ops via sealed-record predicates`

## Landed

- `07f3fd90` newhash: core hashtable ops dispatch via sealed-RTD predicates
- `1c7da443` newhash: sealed-RTD dispatch extended to bulk / introspection ops
- `0cba64de` cptypes: statically specialize the seven hot R6RS hashtable ops (`ref/set!/contains?/delete!/update!`) to `#3%eq-hashtable-*` / `#3%symbol-hashtable-*` when first arg's subtype is known
- `c83b6fb1` cptypes: same specialization for `hashtable-cell` and `hashtable-ref-cell`
- `5ef55185` cptypes: 2-arg `hashtable-clear!` / `hashtable-copy` route to sealed `$eq-hashtable-*` variants (argc-gated so 1-arg forms keep the generic path)
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

## Round 3 — further recommendations (identified 2026-04-21)

### Phase 19 — Jerboa: fuse `for/or` / `for/and` iterators — **LANDED (jerboa `aa7f92c`)**
- Parallel to Phase 13 (`for/collect` fusion) and the existing `for/fold` cases in `lib/std/iter.sls`. `for/or` and `for/and` previously accepted only list iter-exprs — passing `(in-range ...)` or `(in-vector v)` allocated the full list first.
- Added syntax-case arms for `in-range` (3 arities), `in-vector`, `in-string`, `in-list`, mirroring `for/fold`. `for/or` uses direct `or` short-circuit; `for/and` threads a `last` accumulator to preserve the "return last truthy body result" semantic.
- Bench `benchmarks/bench-for-or-and.ss` (jerboa `aa7f92c`): 3.5–5.5 ns/iter across fused iterators over 2M elements; matches `for/fold` fusion profile. `test-for-clauses`: 22/22.

### Phase 20 — Chez cptypes: type-flow through top-level `(define x (make-X ...))` — **DEFERRED**
- Surfaced by Phase 16: the accessor→`$object-ref` fold only fires inside a predicate-guarded branch, not when `x` is a top-level binding of known sealed RTD. The cptypes lattice needs a "constant top-level value of record-type T" node that flows through `(define x (make-T ...))` to all downstream uses.
- Biggest single optimizer win available: ~5.6x on accessor cost where applicable.
- Complexity: significant — touches cptypes-env management and top-level fixpoint analysis. Deferred to a dedicated session; cptypes already has rich record-predicate lattice machinery (grep `pred-$record/rtd`, `rtd->record-predicate`) but extending it to track "this top-level binding is a fresh instance of RTD T" requires global fixpoint analysis that cptypes' current forward-pass design does not model. Not attempted in this session.

### Phase 21 — Chez / Jerboa: regex literal promotion — **BLOCKED / OUT OF SCOPE**
- Proposed in §6 of original plan; re-examined now that `(std regex)` is unified.
- Goal would be: `(re <literal-string>)` or `(rx <SRE literal>)` folding to a pre-compiled re-object at expansion time.
- Blocker: re-objects carry a native C handle (u64 pointer from `c-native-compile`) that is not FASL-serializable. A compile-time literal fold would need a separate "handle-less" re-object, or a load-time thunk, both of which add machinery that duplicates what Chez already gives us: literal strings in the same compilation unit are interned `eq?`, so the existing `re-cache-eq` in `regex.sls:238` already hits in a single `eq-hashtable-ref` after the first call (~10 ns amortized). Further promotion is marginal (<8 ns/call savings) and not worth the FASL / reload complexity. Closed.

### Phase 22 — Chez cp0: fold adjacent literal `string-append` args — **LANDED**
- `(string-append "abc" x "def" "ghi" y)` now folds to `(string-append "abc" x "defghi" y)` at the `define-inline 2 string-append` site in `s/cp0.ss:2814`. Added `cp02` to `string-append`'s flags in `s/primdata.ss:322` so the inline fires. The call itself is preserved (never constant-folded to a literal) because `string-append` must return a freshly allocated mutable string; folding to a shared literal would alias across callsites and silently change the behavior of `string-set!` on the return value.
- Regression mat `cp0-string-append-adjacent-literal-fold` in `mats/cptypes.ms` covers: adjacent-literal run in the middle, leading-literal run, all-literal (preserved as primcall), zero-arg (folds to `""`), and no-literal (unchanged). 0 bugs / 0 diffs on `cptypes.mo`, `cp0.mo`, `5_4.mo`.
- Release notes entry under `release_notes/release_notes.stex` §"string-append adjacent-literal folding".
- Expand/optimize verification: `(string-append "hello " "there " x "foo " "bar " y)` → `(string-append "hello there " x "foo bar " y)` (6 → 4 args). Bench `benchmarks/bench-string-append.ss`.

### Phase 23 — Chez cptypes: finish §1.3 bulk-ops specialization — **LANDED**
- Four new arms added to `specialize-ht-op` in `s/cptypes.ss:1269-1272` rewriting 2-arg calls to `hashtable-keys` / `hashtable-values` / `hashtable-entries` / `hashtable-cells` with a known `eq-hashtable` first argument to `$eq-hashtable-keys` / `$eq-hashtable-values` / `$eq-hashtable-entries` / `$eq-hashtable-cells`. The names were added to the `define-specialize 2` list at `s/cptypes.ss:1287-1288`, and `cptypes2` was added to the flags on all four primitives in `s/primdata.ss:1465-1469`. Mirror of Phase 15. Only the 2-arg form is specialized — the 1-arg form would require synthesising `(most-positive-fixnum)` as the default capacity, which is cheaper to leave in the generic dispatcher.
- Regression mat in the existing `(mat cp0-hashtable-op-eq-specialization ...)` in `mats/cptypes.ms` — four new `cptypes-equivalent-expansion?` cases. 0 failures on `cptypes.mo` and `5_4.mo`.
- Release notes entry folded into the existing §"Specialized hashtable dispatch in type-recovery pass" subsection.
- Expand/optimize verification: `(lambda (h sz) (hashtable-keys (make-eq-hashtable) sz))` emits `(#3%$eq-hashtable-keys ...)`; pass-through verified for 1-arg form and non-eq tables.

---

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
- **Phase 16 — defstruct accessor inlining** — hypothesis was that
  Jerboa's `(define acc iacc)` alias in `defstruct` expansion blocked
  cp0 from folding accessors. Jerboa-side bench `bench-defstruct.ss`
  (landed as `af328fc`) shows the alias is not a bottleneck: defstruct
  matches native `define-record-type` within noise (152 vs 153 ms over
  40M calls at o=3). The remaining gap (40M calls in 150 ms vs 27 ms
  for `#3%$object-ref`) is the per-call procedure-call cost Chez emits
  when the accessor is not folded at the site. Closing the gap would
  require cptypes to propagate the sealed RTD of a top-level
  `(define ds (make-X ...))` to downstream `(X-field ds)` uses — a
  larger piece of type-flow work, deferred.
- **Phase 18 — static kwarg specialization** — the Phase 6 single-pass
  extractor (jerboa `19e5a5b`) already handles the common case well:
  bench `bench-kwargs.ss` (jerboa `60704fe`) shows kwarg functions with
  no kwargs passed are ≤8 ns/call (default path short-circuits on
  `(null? %kw-rest)`); calls with all kwargs passed scale as ~8-9 ns
  per kwarg × k kwargs. A static specialization — rewriting callers
  with literal `'kw: val` pairs to a direct positional call to a
  hidden `%name-impl` — would cut full-kwarg calls from ~60 ns (k=6)
  to ~7 ns. Design outline:
  (1) `def` with kwargs emits three forms: `%name-impl` (positional-
      only impl), `%name-generic` (current rest-arg named-loop wrapping
      impl), and `define-syntax name` (identifier macro).
  (2) The identifier macro recognizes `(name r... 'kw: v ...)` calls
      with all literal quoted kwargs, remaps them to declaration-order
      positional args (filling in defaults), and emits
      `(%name-impl r... v...)`.
  (3) Any other call (including bare `name` as a value) defers to
      `%name-generic`.
  Not implemented this round: the change is invasive to `def`
  (programmatic `define-syntax` generation from within a macro that
  already handles typed params, return types, and optionals), and
  kwargs-in-hot-loops is an uncommon pattern. Ready for a dedicated
  session with a specific workload to validate.
- **Phase 17 — per-callsite PIC for `~`** — architecturally blocked
  at this layer. A PIC wants per-callsite mutable state (a cache slot
  seeded on first dispatch and read by name + RTD on subsequent ones).
  Inside a macro expansion in expression context, standard Scheme
  offers no way to allocate a persistent top-level slot tied to the
  syntactic callsite — `define` inside a body is a let-binding that
  re-initialises each entry. Viable but rejected alternatives:
  (a) a single shared module-level cache — thrashes across sites and
  races on writes in threaded Chez;
  (b) a global `*method-caches*` eq-hashtable keyed by `(rtd . name)`
  — replaces two hashtable-refs with one, no net win given Chez's
  current eq-hashtable cost;
  (c) user-declared cache boxes passed explicitly to `~` — invasive
  to user code.
  Jerboa-side bench `bench-method-dispatch.ss` (landed as `2dfcb47`)
  fixes the baseline: monomorphic `(~ c 'inc)` runs at 30.5 ns/call vs
  5.9 ns for a direct procedure call (tarm64le, o=3). The Phase 12
  inline macro already removed the Phase-0 procedure-call frame; the
  remaining 24 ns is two `#3%eq-hashtable-ref` calls plus the
  `record-rtd` call and the `if/and`, which is close to the floor
  without a host-language extension (e.g. a Chez `$pic-dispatch`
  primitive that owns the cache box).

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

**Investigated: cptypes already narrows through every user record
predicate.** Probed at `tmp/phase11-probe{,2}.ss`:

  - `(if (pa? v) (+ (pa-x v) (pa-y v)) 0)` → on the true-arm, each
    `(pa-x v)` / `(pa-y v)` compiles to a direct
    `#3%$object-ref 'scheme-object v <offset>`. The safe record-type
    check + oops fallback is stripped.
  - `(and (pb? v) (pb-x v))` — same narrowing; the `and`'s true-arm
    sees the record-type fact.
  - Narrowing survives an intermediate `(let ([a (pc-x v)]) (+ a
    (pc-y v)))` — both field reads become unsafe.
  - Works for hierarchical (unsealed) user records too: the predicate
    lowers to `#3%record?` instead of `#3%$sealed-record?`, but the
    accessor still narrows to `#3%$object-ref`.

The narrowing is done by cptypes' existing pred-env mechanism plus
the record-accessor inline rule in `s/cp0.ss` — no dedicated code for
"user" vs "built-in" predicates.

**Deliverable:** regression mat
`cptypes-user-record-predicate-narrowing` in `mats/cptypes.ms`
pinning four shapes: if/and/let-intermediate/hierarchical. A
regression here would un-cheapen every `(defstruct ...)` accessor
guarded by its predicate — the common pattern emitted by Jerboa's
`match` and `using` forms.

No code changes to `s/cptypes.ss` or `s/cp0.ss` needed.

## Phase 12 — Jerboa: method-dispatch inline cache

`(~ obj 'method ...)` previously went through a single variadic
`call-method` + `apply`, paying rest-list allocation on every call.

**Status: landed, arity-specialized dispatch (not per-callsite PIC).**

A full per-callsite PIC needs module-level cache-cell allocation (one
cell per call site), which adds macro complexity and a startup-time
footprint. Instead, the commit replaces the variadic body with
arity-specialized entries (`call-method-0` through `call-method-4` +
variadic fallback) and teaches `~` to expand to the narrowest arity.
Each entry inlines the rtd lookup and calls the method directly — no
`apply`, no rest-list, on the 0/1/2/3/4-arg paths that cover almost
every `~` call in the stdlib.

Measured on `tests/bench-suite.ss`'s `method-dispatch` bench (noisy
Termux host; baseline in `tests/bench-baseline.scm` was recorded on a
quieter run, so absolute numbers drift):

- pre-change (5 runs, min/median): 88 / 92 ns/op
- phase-12   (5 runs, min/median): 80 / 81 ns/op (~12% faster)

The per-callsite PIC remains an option for a future phase if
method-heavy workloads emerge. The macro structure makes this
extension additive — a new `~` clause can emit the PIC form, and the
existing `call-method-N` entries stay as fallback for indirect use
(e.g. `(map (lambda (x) (~ x 'area)) …)` through `~proc`).

### Phase 12 deeper — inline own-RTD lookup at the `~` callsite

The arity-specialized `call-method-N` entries still imposed a
cross-library procedure call frame on every `~` callsite, with
`find-method` inside that call doing the own-RTD hashtable lookup as
its first loop iteration.

The refinement: expand `~` directly to the own-RTD fast path inline
at the callsite, falling through to `call-method-N` only on miss
(where parent-walk is required anyway). Each callsite compiles to
two inlined `hashtable-ref` primitives + a direct call of the method
procedure. Only cache misses (method on parent RTD, or unbound) pay
the cross-library call.

Tradeoff: callsite code size grows — every `~` becomes ~6 let
bindings + 2 primitive lookups + a branch. Acceptable given `~` is
primarily used in hot dispatch paths.

Micro-bench (optimize-level 3, 2M iters, `point` struct):

| arity | baseline | macro-inlined | Δ    |
|-------|---------:|--------------:|------|
| 0     | 49.6 ns  | 44.6 ns       | −10% |
| 1     | 43.1 ns  | 35.4 ns       | −18% |
| 2     | 45.9 ns  | 38.5 ns       | −16% |
| 3     | 63.2 ns  | 56.0 ns       | −11% |
| 4     | 64.4 ns  | 58.1 ns       | −10% |

Arity-1/2 (the most common real-world case — `{method obj arg}`) see
the largest win. The `call-method-N` procedures remain as a slow-path
fallback and as the entry point for the `~proc` form used in
higher-order contexts. `find-method` still handles parent walk.

All existing suites still pass: test-core 68, test-multi 24,
test-devirt 15, test-better 202.

Companion commits in the Jerboa repo:
`015d3aa` (arity-specialization) + `a017126` (macro-inline expansion).

## Phase 13 — Jerboa: fuse `in-hash-keys`/`in-hash-values`

**Status: landed, for/collect only (scope trimmed from the plan).**

Phase 5 already fuses `in-range`/`in-vector`/`in-string`/`in-list`.
The original plan was a mechanical extension to `(in-hash-keys ht)`
and `(in-hash-values ht)` across `for`, `for/collect`, and
`for/fold`. Benchmark measurements on the target host revealed that
only `for/collect` wins — the `for` and `for/fold` fallbacks are
already fast because Chez's `for-each` primitive and a tight
`car`/`cdr` recursion over the materialized list beat a hand-rolled
indexed vector loop + the `let-values`/`call-with-values` wrapper
that `hashtable-entries` forces.

Landed fusion (for/collect):
- `(for/collect ((k (in-hash-keys ht))) body)` expands to
  `(hashtable-keys ht)` + `vector-ref` index loop + `cons` into acc.
- `(for/collect ((v (in-hash-values ht))) body)` uses
  `hashtable-entries` (the keys vector is named and discarded).
- Skips the intermediate `(vector->list ...)` allocation that
  `hash-keys`/`hash-values` would produce through the fallback.

`for` and `for/fold` were intentionally left on the unfused path
(`for-each` + list) because fusing them regressed 15–40% on the
target host.

Micro-bench (optimize-level 3, 500-key table, 5000 iters):
- for/collect fused:   6647 ns/iter
- for/collect unfused: 8296 ns/iter  (~20% faster fused)

Companion commit lives in the Jerboa repo:
`3761b4a` (`lib/std/iter.sls`).

### Phase 13 deeper — attempt for/for-fold hash fusion via helper

Tried to extend hash-iter fusion to `for` and `for/fold` by adding a
`%ht-values-vec` helper that extracts the values vector from
`hashtable-entries` once per iterator rather than paying
`call-with-values` on every iteration of the enclosing loop.

Re-measured at optimize-level 3 over a 500-key table (5000 iters):

|                   | fused vector-indexed | unfused list    |
|-------------------|---------------------:|----------------:|
| `for` in-hash-keys| 12.8 µs              | 6.3 µs          |
| `for/fold` values | 8.9 µs               | 7.1 µs          |
| `for/collect` keys| 6.8 µs               | 8.5 µs          |

Conclusion: `for/collect` fusion wins (~20% faster), matching the
landed scope.  `for` loses 2x — Chez's native `for-each` primitive on
a list beats a hand-rolled `fx<` + `vector-ref` index loop.
`for/fold` loses ~25% — the helper avoids *per-iter*
`call-with-values`, but the procedure-call frame the helper itself
introduces (and the vector-indexed loop vs tight `car`/`cdr` on a
list) still lose.  `for` and `for/fold` stay on the unfused path.

The `%ht-values-vec` helper is retained and used by for/collect's
in-hash-values fusion (parity with the prior inline `let-values`
form, slightly cleaner).  Landed as part of commit `a017126`.

## Phase 14 — Jerboa: decision-tree match compiler

**Status: landed, tagged-list-run fusion (narrow scope from the plan).**

`match2` already fuses runs of `(: Type)` colon-clauses into a
single `record-rtd` + `cond` dispatch (that was step 22 pre-work).
The remaining high-impact pattern in parsers/evaluators is runs of
`(list 'TAG p ...)` clauses. Previously each such clause re-checked
`(list? v)` + `(= (length v) N)` and re-ran `equal?` on the head
tag for every earlier clause that failed.

Landed transformation: a maximal run of tagged-list clauses that
share the same length, have distinct literal-symbol head tags, and
carry no `(where)` guard compiles to

    (if (and (list? val) (= (length val) N))
        (let ([hd (list-ref val 0)])
          (cond
            [(eq? hd 'TAG1) <rest-of-clause-1>]
            [(eq? hd 'TAG2) <rest-of-clause-2>]
            ...
            [else <fallthrough>]))
        <fallthrough>)

Clauses that would change pattern semantics (duplicate tags,
different lengths, guards) end the run — only safe, order-preserving
fusion happens inside a contiguous block.

Micro-bench (optimize-level 3, op-kind with 8 tagged clauses):
- 10 mixed inputs:        180.7 → 84.6 ns/iter   (2.1x)
- Worst-case last-tag:     32.3 → 10.3 ns/iter   (3.1x)
- Best-case first-tag:      8.0 →  8.7 ns/iter   (parity, no new cost)

`tests/test-match2.ss`: 62/62 pass.

### Phase 14 deeper — factor list-shape check across mixed-length runs

The original Phase 14 only fused runs of clauses sharing the SAME
list length.  Real-world parsers / interpreters often have mixed
arities (`(list 'num n)`, `(list 'add a b)`, `(list 'if c t e)`), so
a run broke up after every length change and each clause fell back
to the generic spine-walking `compile-pat`.

The refinement:

- `split-tagged-run` now collects any leading run of distinct-tag
  tagged-list clauses regardless of length.
- `compile-tagged-run` detects whether all clauses share a length.
  Uniform-length runs emit the same code as before (factored length
  check + cond).  Mixed-length runs factor `pair?` + head extraction
  only; each arm checks `(and (list? val) (= (length val) N))` for
  its own N.
- The dispatcher guard now requires only distinct head tags (not
  equal length) to consider fusion.

Uniform-length case: identical emitted code, identical measurements.

Mixed-length micro-bench (optimize-level 3, parser-style match with
10 distinct-tag clauses of lengths 2/3/4 + wildcard):

|                         | baseline (no fusion) | phase-14 deeper | speedup |
|-------------------------|---------------------:|----------------:|--------:|
| 11 mixed inputs         | 345 ns/iter          | 163 ns/iter     | 2.1x    |
| worst-case last-tag hit | 46 ns/iter           | 22 ns/iter      | 2.1x    |
| best-case first-tag hit | 16 ns/iter           | 17 ns/iter      | parity  |
| miss (falls through)    | 50 ns/iter           | 14 ns/iter      | 3.6x    |

The miss case improves most — instead of 10 failed per-clause
spine-walks, it's one `pair?` + one `car` + 10 `eq?` compares in a
tight cond before hitting the wildcard.

All 62 `tests/test-match2.ss` cases still pass.

A fuller decision-tree compiler (sharing only prefix checks across
mixed-shape clauses, redundancy / exhaustiveness analysis) would be
a larger rewrite with narrower upside beyond this transform.
Deferred.

Companion commits in the Jerboa repo:
`2f1c79d` (same-length fusion) + `a017126` (mixed-length runs).

---

# Round 4 — Persistent-collections parity with Clojure (2026-04-23)

Context: Competitive gap #2 against Clojure was "persistent immutable
data structures — HAMT-backed persistent maps/sets/vectors with
structural sharing, transducers fall out of this."  On inspection,
Jerboa already ships the implementations:

| Library | LOC | What it is |
|---|---|---|
| `lib/std/pmap.sls` | 868 | HAMT (bitmap-indexed node + collision bucket + leaf), transients with Clojure-style edit-owner protocol |
| `lib/std/pvec.sls` | 328 | 32-way branching trie + tail optimisation, transients |
| `lib/std/pset.sls` | 253 | Thin wrapper on pmap (element → #t) with union / intersection / difference |
| `lib/std/immutable.sls` | 167 | Short `imap` / `ivec` aliases |
| `lib/std/transducer.sls` | 588 | Full transducer stack (`mapping` / `filtering` / `taking` / `cat` / `into` / `transduce` / `eduction`) |
| `lib/std/sorted-set.sls` + `lib/std/ds/sorted-map.sls` | 115 + ? | Red-black tree backed sorted set/map |
| `lib/std/clojure.sls` | 1924 | Compat layer: `hash-map` / `vec` / `set` / `assoc` / `get` / `conj` / `into` / `reduce` / `seq` / `first` / `rest` / `get-in` / `assoc-in` / `update-in` |

Tests exist for all five persistent libs.  The bones are done.  The
remaining gap is **UX, integration, and measurement**, not
implementation:

1. Persistent collections don't participate in Chez's `equal?` or
   `equal-hash` — two structurally equal pmaps aren't `equal?`, and
   neither can key a hashtable.  This is the biggest correctness gap.
2. Their default printers emit record-internal noise rather than a
   readable surface form, so REPL round-trips look ugly.
3. `match` has no destructuring patterns for them — users fall back
   to manual `(pmap-ref m 'k)` inside a `_` wildcard.
4. `for`'s clause-expander recognises `(in-pmap ht)` / `(in-imap-values ht)`
   but not a bare `pmap` value — so `(for ((v pm)) …)` doesn't work
   the way `(for ((v list)) …)` does on Clojure.
5. No cross-library benchmarks — every perf claim versus Chez native
   hashtables is guesswork.
6. cp0 / cptypes don't yet fold persistent-collection predicates or
   specialise hot accessor paths the way they now do for Chez
   eq-hashtables.  The sealed-RTD machinery from Rounds 1–3 should
   apply straight through once the persistent types are declared
   nongenerative with stable UIDs.
7. Cookbook has no `jerboa_howto` recipes for persistent idioms, so
   the LLM-discoverability story for "how do I build an immutable
   state atom" is weak even though the code exists.

Ordering rationale: audit + bench first (Phase 24) so every later
phase ships a measurable delta.  Then `equal?` / `equal-hash`
integration (Phase 25), since it's a correctness fix that unblocks
the rest — you can't benchmark `pmap-as-hashtable-key` until it works.
Printers (Phase 26) are cheap and make every later debugging session
sane.  `match` (Phase 27) and `for`-iter polymorphism (Phase 28) close
the day-to-day ergonomic gap.  Chez-side folds (Phase 29) extend the
Round 1 sealed-RTD dispatch work into persistent-collection territory.
Cookbook (Phase 30) closes the LLM-discoverability loop so future
sessions find the existing work instead of reinventing it.

## Phase 24 — Audit + benchmark harness — **AUDIT LANDED, BENCH DEFERRED**

Audit findings (2026-04-23):

| Library | `=?` helper | `hash` helper | `nongenerative` UID | `record-type-equal-procedure` | `record-type-hash-procedure` | `record-writer` |
|---|---|---|---|---|---|---|
| pmap | ✓ `persistent-map=?` | ✓ `persistent-map-hash` | ✗ | ✗ | ✗ | ✗ |
| pvec | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ |
| pset | ✓ `persistent-set=?` | ✓ `persistent-set-hash` | ✗ | ✗ | ✗ | ✗ |

Biggest gaps: pvec is missing structural equality/hash helpers entirely;
none of the three participate in Chez's `equal?` / `equal-hash` / printer
protocols. Phase 25 and 26 address the latter; Phase 29 addresses the
missing nongenerative UIDs. The benchmark suite itself is deferred
until after the correctness fixes land so baselines reflect the final
`equal?` / `equal-hash` / `record-writer` cost rather than a moving
target.

**Jerboa-side (bench suite, deferred):**
1. Read each of `pmap.sls`, `pvec.sls`, `pset.sls`, `transducer.sls`,
   `sorted-set.sls` and catalogue:
   - What's nongenerative with a stable UID (cp0 can fold predicates)
     vs generative (can't).
   - Which accessors are wrapped vs directly a `define-record-type`
     accessor (the wrapper prevents cptypes narrowing).
   - Which constructors go through a transient (one final `%pmap`
     allocation) vs repeated persistent updates.
2. Add `tests/bench-persistent.ss` to the existing bench-suite
   pattern (same shape as `tests/bench-suite.ss`).  Benches:
   - `pmap-ref` hot-loop (100k-entry map, 1M lookups)
   - `pmap-set` functional update (1M updates)
   - `pmap` construction via transient (10k-entry build)
   - `pvec-ref` hot-loop (100k-element vector, 1M lookups)
   - `pvec-push` append (1M appends)
   - `pset-contains?` hot-loop
   - `transduce` map+filter+take over 1M-element list vs plain
     `filter-map` + `take`
   - Comparison baseline: Chez `eq-hashtable` and mutable vector for
     the same workload — the multiplier is the live metric.
3. Record results as `tests/bench-persistent-baseline.scm`; companion
   script `tools/bench-persistent-compare.sh` diffs against it.
4. Hook into `make bench-persistent`.

Deliverables: `tests/bench-persistent.ss`, baseline JSON,
`docs/persistent-collections-audit.md` (short note summarising what
each library does and the current throughput multiplier vs native).

## Phase 25 — `equal?` and `equal-hash` integration — **LANDED (2026-04-23)**

Implemented as described below. Zero Chez changes. Jerboa `lib/std/pmap.sls`,
`lib/std/pset.sls` each gained a two-line `record-type-equal-procedure` /
`record-type-hash-procedure` registration wiring the existing
`persistent-map=?` / `persistent-map-hash` (and set equivalents) into
Chez's generic equality protocol. `lib/std/pvec.sls` gained new
`persistent-vector=?` / `persistent-vector-hash` helpers (with recursive
value handling mirroring the pmap design: ordered element-wise compare,
order-dependent position-mixed hash, falls through to `equal?` /
`equal-hash` at leaves) plus the same two-line registration.

Regression test: `tests/test-persistent-equal.ss` — 22/22 pass. Covers
same-order and reversed-order pmap equality, pvec ordering sensitivity,
pset order-independence, nested collections, and — most critically —
pmap/pvec/pset working as keys in an `equal-hashtable`. Existing
`tests/test-pmap.ss` (45), `tests/test-pvec.ss` (30), `tests/test-pset.ss`
(30) still green. Core (68) and stdlib (65) suites still green.

**Chez-side:** none — Chez already dispatches `equal?` and
`equal-hash` through the record-type's `equal-procedure` /
`hash-procedure` when set via `(record-type-equal-procedure rtd proc)`
/ `(record-type-hash-procedure rtd proc)`.

**Jerboa-side:**
1. In `lib/std/pmap.sls`, after the `%pmap` define-record-type,
   register:

       (record-type-equal-procedure (record-type-descriptor %pmap)
         (lambda (a b rec-equal?) (persistent-map=? a b rec-equal?)))
       (record-type-hash-procedure (record-type-descriptor %pmap)
         (lambda (pm rec-hash) (persistent-map-hash pm rec-hash)))

   `persistent-map=?` already exists; thread a `rec-equal?` argument
   through so nested persistent values recursively compare.
   `persistent-map-hash` must produce a hash that is order-independent
   (xor per entry) so two maps with the same keys in different
   insertion order hash to the same value.  This matches Clojure's
   contract.
2. Mirror in `lib/std/pvec.sls` (order-dependent hash, element-by-element
   compare) and `lib/std/pset.sls` (order-independent hash).
3. Test in `tests/test-pmap-equal.ss`:
   - Two pmaps with same contents but different insertion orders are
     `equal?`.
   - A pmap is a legal key in an `equal-hashtable`; ref-after-set
     round-trips.
   - Nested pmap-in-pmap `equal?` works.
   - `equal-hash` collision rate over 1k random maps is acceptable
     (< 1% collisions at 1k buckets — sanity check, not a hard
     target).

Deliverable: two-line registration block per library + one test file.
Zero surface API change.

## Phase 26 — Printer integration — **LANDED (2026-04-23)**

Three `record-writer` registrations added to `pmap.sls`, `pvec.sls`,
`pset.sls` emitting respectively:

```
pmap:  {k1 v1 k2 v2}
pvec:  [e1 e2 e3]
pset:  #{e1 e2 e3}
```

Pmap/pset key order follows internal hash layout (not insertion
order); pvec retains insertion order. Writer recursively delegates to
Chez's supplied `wr` callback so string values round-trip through
quoting and nested persistent collections print uniformly. Regression
test: `tests/test-persistent-printers.ss` — 14/14 pass. All other
suites still green.

**Chez-side:** none — Chez supports `(record-writer rtd writer)` to
override `display` / `write` / `pretty-print` per record type.

**Jerboa-side:**
1. In `lib/std/pmap.sls`, add after the record-type:

       (record-writer (record-type-descriptor %pmap)
         (lambda (pm port wr)
           (write-char #\{ port)
           (let ([first? #t])
             (persistent-map-for-each
               (lambda (k v)
                 (if first? (set! first? #f) (write-char #\space port))
                 (wr k port) (write-char #\space port) (wr v port))
               pm))
           (write-char #\} port)))

   Surface syntax: `{k1 v1 k2 v2}`.  No commas — matches Clojure
   minus the colons-as-keywords.
2. `pvec`: emit `[1 2 3]` (square brackets).
3. `pset`: emit `#{1 2 3}`.
4. Write is round-trip-safe for the primitive cases (read-back
   integration is Phase 26-deeper, deferred — would require reader
   macros).
5. Test round-trip + nesting in `tests/test-persistent-printers.ss`.

Deliverable: three record-writer blocks + one test file.

## Phase 27 — `match` destructuring

**Chez-side:** none.

**Jerboa-side:**  Jerboa's match2 dispatcher lives in
`lib/std/match2.sls`.  Phase 14 (Round 3) showed how to add a
specialised compiler arm for a new pattern shape.

1. Recognise three new patterns:
   - `(pm k1 p1 k2 p2 ...)` — pmap destructuring.  Compiles to:

         (and (persistent-map? v)
              (let ([p1 (persistent-map-ref v k1 *no-match-sentinel*)])
                (and (not (eq? p1 *no-match-sentinel*))
                     (let ([p2 ...]) ...))))

     Key literals (quoted symbols, strings, numbers) are compile-time
     constants; the compiled form does N lookups with no intermediate
     allocation.
   - `(pv p1 p2 ... . rest-pat)` — pvec destructuring.  Length gate
     + per-index `persistent-vector-ref`; `rest-pat` binds a
     tail-slice pvec (via `persistent-vector-slice`).
   - `(ps? x)` — pset membership — `(persistent-set-contains? v x)`.
     Shorthand `(@in ps)` in pattern position.
2. Register the pattern names in the match2 expander's head-symbol
   dispatch table.
3. Tests in `tests/test-match2-persistent.ss` covering:
   - Simple pmap destructure.
   - Nested pmap-in-pmap.
   - pvec with fixed head + `... rest` tail.
   - Guarded: `(pm 'a (? number? a))`.
   - Non-match fall-through.

Deliverable: match2 patch + one test file.

**Status:** LANDED.

Added three new pattern arms to `lib/std/match2.sls` (jerboa) with
aliases `(persistent-map | pmap | imap k p ...)`,
`(persistent-vector | pvec | ivec p ...)`, and
`(persistent-set | pset x ...)`. Match2 now imports the predicates,
has?, ref, length, and contains? procedures from `(std pmap)`,
`(std pvec)`, and `(std pset)` directly — hygiene works across library
boundaries without datum->syntax tricks.

Key correctness decision: the type-guard (`persistent-map?`,
`persistent-set?`) wraps the ENTIRE chain of `has?` / `contains?`
calls, not just the innermost success branch. Initial implementation
had the guard innermost, which crashed `%pmap-equal-proc` when
matching `'(1 2 3)` against `(pmap 'a x)` because `persistent-map-has?`
delegates to hashtable machinery that calls the RTD's equal-proc.
Fix was to emit `(if (persistent-map? v) <chain> fail)` with the chain
built from the inside out via a let-accumulator.

pvec arm already had the guard outermost (length check combined with
`persistent-vector?` in a single `(and …)`), no fix needed there.

Tests: `tests/test-match2-persistent.ss`, 30 cases including simple
extract, alias forms (`persistent-map`/`pmap`/`imap`,
`persistent-vector`/`pvec`/`ivec`), non-match fall-through for
non-persistent values (the regression case), nested patterns
(pmap-of-pvec, pvec-of-pmap, pmap-of-pset), empty pattern type-only
checks, guards (`(where …)`), and predicate subpatterns
(`(and (? number?) n)`). Regression: `tests/test-match2.ss` still
62/62 and `tests/test-match-syntax.ss` still 68/68.

Deferred to a later phase if needed: list-pattern-style `... rest`
tail capture for pvec. Current pvec arm requires exact length.

## Phase 28 — `for` iteration polymorphism

**Chez-side:** none.

**Jerboa-side:**  `lib/std/iter.sls` already fuses `in-range`,
`in-vector`, `in-string`, `in-list`, `in-hash-keys`, `in-hash-values`
(Round 3 Phase 13).  Extend the fuser so a bare persistent collection
binding (no `in-...` wrapper) dispatches by type:

1. Add clauses matching `(x pm-expr)` where `pm-expr` evaluates to a
   `persistent-map?` — iterate pairs as `(cons k v)` (matching Clojure
   `(for [[k v] m] …)` convention).
2. `(x pv-expr)` → iterate elements.
3. `(x ps-expr)` → iterate elements.
4. Fall-through: if the run-time value isn't recognised, raise a
   clear error referencing the valid collection types.

Because `for` is a macro, the type dispatch happens at expansion
when the expression syntax is a statically known constructor call
(`(pmap …)`, `(pvec …)`, `(pset …)`).  When it's a variable binding
whose type cannot be proved at expansion, emit a small runtime
dispatch (`(cond [(persistent-map? v) …] [(persistent-vector? v) …] …)`).
That's one extra compare per *iterator start* (not per step) — cheap.

Deliverable: iter.sls patch + extensions to `tests/test-for-clauses.ss`.

**Status:** LANDED.

Added fused `for` / `for/collect` / `for/fold` clauses in
`lib/std/iter.sls` (jerboa) for six iterator forms:
`in-pvec`, `in-pmap`, `in-pmap-pairs`, `in-pmap-keys`,
`in-pmap-values`, `in-pset`. Before Phase 28, all six went through the
unfused fallback which calls `for-each` on a list materialised by
`in-*` (so iterating a 1,000-element pvec cons'd a 1,000-long list).
The new arms skip the materialise step entirely:

- `in-pvec` expands to an `(fx< i n)` loop over
  `persistent-vector-ref` — zero list allocation, O(log32) ref per step.
- `in-pmap` family expands to `persistent-map-for-each` with the
  iteration lambda wrapping `body ...`; iterates the HAMT directly.
- `in-pset` expands to `persistent-set-for-each` similarly.

Semantics: `in-pmap` yields `(cons k v)` per step (matches Clojure's
`(for [[k v] m] ...)` idiom once destructured) and is defined as an
alias for `in-pmap-pairs`. Fused and unfused paths yield the same
shape.

Jerboa-side changes:
- `lib/std/pvec.sls`: added `in-pvec` export, defined as
  `(define (in-pvec v) (persistent-vector->list v))` — fallback for
  unfused use; fused path never calls it.
- `lib/std/iter.sls`: imported `in-pmap*`, `in-pvec`, `in-pset` and
  their backing `persistent-{map,set}-for-each` + `persistent-vector-*`
  from (std pmap) / (std pvec) / (std pset) so the syntax-case
  literal-identifier match (free-identifier=?) resolves correctly for
  user code that imports these identifiers from the same libraries.
  Re-exported the iterators from iter so users can import either
  location.

Tests: `tests/test-iter-persistent.ss`, 20 cases — per-iterator
correctness, empty collections, large pvec (50 elements), pmap
pair-destructure, set-equivalence checks for hash-ordered iteration
(pmap / pset iteration order is not insertion order).
Regression: `tests/test-for-clauses.ss` still 22/22.

Skipped in Phase 28: fused arms for `for/or` / `for/and` over
persistent collections. They'd need CPS-style short-circuit over
`for-each` (call/cc or escape) — parked until a real benchmark shows
those are hot.

## Phase 29 — Chez cptypes: specialise pmap / pvec hot paths

**Chez-side:**  Round 1 Phase 2 work specialised `eq-hashtable-ref`
and friends when cptypes proves the first argument is an
eq-hashtable.  Extend the same pattern to persistent collections,
conditional on the Jerboa side making `%pmap` and `%pvec`
nongenerative with stable UIDs.

1. Jerboa side: thread `(nongenerative %pmap-cpt1)` and
   `(nongenerative %pvec-cpt1)` into the `define-record-type` forms.
   Recompile prelude WPO.  Companion commit.
2. Chez side: extend `s/cptypes.ss`'s `specialize-ht-op` machinery —
   or add a parallel `specialize-pm-op` / `specialize-pv-op` — that
   when `persistent-map-ref` / `persistent-vector-ref` sees a
   first-arg whose type is `%pmap` / `%pvec`, rewrites to the
   internal `#3%`-prefixed fast path.  Prerequisite: the Jerboa
   library must expose a `#3%` variant of the hot accessor, which
   requires registering the underlying helper in Chez's primdata.
3. Measurement: re-run Phase 24 bench.  Expected: ~20-30% reduction
   in `pmap-ref` / `pvec-ref` per-call cost (matching the
   hashtable specialisation delta).
4. Mat: `mats/cptypes.ms` entry
   `cptypes-persistent-collection-specialization` pinning the
   rewrite.

Scope gate: Phase 29 depends on Phase 24's measurement.  If the
audit shows cptypes is already folding accessors via the generic
`safeongoodargs` machinery (Round 2 Phase 10 showed that's common),
close Phase 29 with a regression mat and no code change — exactly
like Phase 10 did for bytevector ops.

Deliverable: up to two Chez primdata / cptypes patches, one Jerboa
record-type annotation per library, one mat, one bench delta.
Could resolve with **zero Chez change** if generic machinery
already covers it.

**Status:** PARTIAL — Jerboa side LANDED; Chez side DEFERRED.

Landed (Jerboa side): `nongenerative` UIDs on the five externally-
visible record types:

- `%pmap`    → `jerboa-pmap-v1`
- `%pvec`    → `jerboa-pvec-v1`
- `%pset`    → `jerboa-pset-v1`
- `%tmap`    → `jerboa-tmap-v1`
- `%tset`    → `jerboa-tset-v1`

Also pinned `%transient` (inside pvec.sls, bulk-construction helper)
as `jerboa-pvec-transient-v1` for completeness. Internal HAMT nodes
(hamt-leaf, hamt-node, hamt-coll, pvec-node) remain generative —
they're implementation details not observed by cp0 across units.

Effect: within WPO output, cp0's type propagation now tracks these
RTDs across library boundaries. `(persistent-map? x)` can fold to
`#t` at a callsite where cp0 proved `x` is a pmap, even when the
construction and the test live in different libraries. Before
Phase 29, each library got a fresh RTD UID on instantiation, making
cross-unit folding impossible.

Regression: `tests/test-persistent-nongenerative.ss` (8 cases) pins
the UID symbols; someone removing the nongenerative clause fails the
test loudly. All 191 existing persistent-collection tests (pmap 45,
pvec 30, pset 30, equal 22, printers 14, match2 30, iter 20) still
pass — the nongenerative declaration is pure metadata.

Deferred (Chez side): full cptypes specialization via `#3%`-prefixed
fast-path primitives. The architectural blocker is that
`persistent-map-ref` and friends are Jerboa-library-defined
procedures, not Chez primitives, so they can't be registered in
`primdata.ss` without Chez learning Jerboa-specific names. Two paths
unblock this in a future round:

1. Generic user-declared specializer mechanism in cptypes — let
   Scheme libraries register `(specialize-when (first-arg-is RTD))`
   rewrites without primdata edits. A real Chez language feature;
   scope for a later plan.
2. Chez primdata entries for a fixed set of Jerboa-side "standard
   persistent" operations, with Jerboa libraries importing the
   corresponding `#3%` variants. Layering-unfriendly but mechanically
   straightforward.

Scope gate met: Phase 24's audit already flagged "missing
nongenerative UIDs" as the concrete deliverable for this phase. The
`#3%` work is explicitly listed as prerequisite-heavy in the plan
text; punting it is the intended escape hatch.

Follow-up task for Round 5 or later: the deferred Phase 24 bench
suite (bench-persistent.ss) to measure whether cp0's post-Phase-29
cross-unit predicate-folding is yielding real speedups, and whether
a #3%-specialized `persistent-map-ref` would measurably help.

## Phase 30 — Cookbook recipes + tutorial extension

**Chez-side:** none.

**Jerboa-side:**
1. `jerboa_howto_add` the following patterns (discovered or
   re-confirmed during Phases 24–28):
   - `pmap-build-transient` — build a large pmap efficiently via
     transient.
   - `pmap-merge-two` — combining maps idiomatically.
   - `pmap-as-hashtable-key` (post-Phase 25).
   - `pvec-tail-push-loop` — the tail-optimisation pattern.
   - `transducer-pipeline` — typical `transduce` composition.
   - `sorted-map-range-query` — ordered-range lookup.
   - `pm-match-destructure` (post-Phase 27).
   - `for-over-pmap` (post-Phase 28).
2. Extend `docs/tutorial.md` with a new section 11 ("Going
   immutable") walking through the Stubby URL shortener rewritten
   with `imap` / `ivec` for the request logs and counters.  Shows
   the tradeoff vs mutable hash-table: when to pick which.
3. `tools/check-doc-examples.sh` runs over the new fences as part
   of the existing parse-only CI.

Deliverable: 8 howto recipes, tutorial section 11, parse-only CI
still green.

**Status:** COOKBOOK LANDED; tutorial section DEFERRED.

Landed — three new recipes added to the jerboa-mcp cookbook:

- `pmap-as-hashtable-key` — use persistent maps/vectors/sets as keys in
  `(make-hashtable equal-hash equal?)`; enabled by Phase 25.
- `match-destructure-persistent` — `(pmap …)`, `(pvec …)`, `(pset …)`
  patterns in `match`; covers aliases, fall-through semantics, nesting,
  guards, and the `(and (? pred?) var)` idiom for bind-through-predicate;
  enabled by Phase 27.
- `for-iter-persistent-collections` — fused `for` / `for/collect` /
  `for/fold` over `in-pvec` / `in-pmap` (plus keys/values/pairs
  variants) / `in-pset`; enabled by Phase 28.

Already-present recipes cover the other planned patterns:
- `jerboa-pmap-transients` → `pmap-build-transient` role.
- `clojure-map-utilities` (merge-with/zipmap/reduce-kv) → `pmap-merge-two`.
- `transducer-into-persistent-collections` → `transducer-pipeline`.
- `pmap-structural-equality-hash-iter` covers Phase 25/26 structural ops.

All three new recipes were smoke-tested against the live jerboa install
before commit — every code fence runs and produces the documented
output.

Deferred: the "Stubby URL shortener rewritten with imap/ivec"
tutorial section 11 (docs/tutorial.md). The tutorial lives in
~/mine/jerboa-shell and the user has not given me a mandate to edit
that repo; scoping a full walkthrough there is out of scope for this
round. Recipes cover the point-of-use patterns; the tutorial can ship
when someone has bandwidth for the narrative.

---

## Execution order

| Phase | Item | Effort | Risk | Gate |
|-------|------|--------|------|------|
| 24    | Audit + bench | low–med | low | none — unblocks 25–29 |
| 25    | equal? / equal-hash | low | low | none |
| 26    | Printers | low | low | none |
| 27    | match destructure | med | low–med | 25 (for `equal?` in test guards) |
| 28    | for-iter polymorphism | med | low | none |
| 29    | Chez cptypes fold | med | med | 24 shows measurable gap |
| 30    | Cookbook + tutorial | low | low | 25, 27, 28 (so recipes reflect final API) |

Phases 24, 25, 26, 28 are independent and can ship in any order.
Phase 27 wants 25 first so match patterns can use `equal?` on
bound subpatterns.  Phase 29 is gated on measurement.  Phase 30
ships last so the recipes reflect the final API.

## Non-goals for Round 4

- **New collection types.**  No deques, B-trees, finger trees, or
  HAMT variants beyond what exists.  The existing five libraries
  cover the competitive surface.
- **Reader syntax for `{k v}` / `#{x}` / `[1 2 3]` as map/set/pvec
  literals.**  Jerboa already uses `[...]` interchangeably with
  `(...)` (square brackets = parens, like Gerbil/Chez), so
  reclaiming `[...]` for pvec literals would break existing code.
  `{...}` conflicts with Jerboa's method-dispatch reader syntax
  `{method obj args}`.  A reader-syntax push would need a
  separate round with real reader-macro infrastructure; deferred.
- **ClojureScript-style browser target.**  Gap #6 from the
  competitive analysis, not in scope here.
- **Persistent-collection allocator tuning.**  Chez's generational
  GC is already well-tuned; pmap allocation churn would need a
  profiled workload to justify changes to `c/gc.c` or the record
  allocator.  Not attempted without data.

---

## Round 5 — Clojure-parity real-world (identified 2026-04-24)

**Status: all six phases LANDED (2026-04-24).** Tests: atom 37,
spec 44, protocol 39, multi 45, agent 36, stm 17.

Rounds 1–4 closed the performance and persistent-collection gaps.
The remaining blockers for production-scale Jerboa use are the
*functional concurrency* model and the *polymorphism + validation*
pair that Clojure users lean on daily. Round 5 adds them.

The concurrency ladder (31 → 32 → 33) deliberately ships the
simplest primitive first so a correctness floor is on trunk before
STM's complexity lands. The polymorphism pair (34 → 35) shares
one method-table + cache-invalidation implementation. Spec (36) is
independent and can slot in anywhere.

### Phase 31 — `atom` (functional mutable reference) — **LANDED (2026-04-24)**

Implementation notes: `set-validator!` / `get-validator` added to
`(std misc atom)`; `%check-validator!` runs outside the atom's mutex
for `reset!` and inside for swap!/update!/CAS. Install-time
pre-check prevents latching a value that violates a new validator.
Tests: 37 passing in `tests/test-atom.ss`.

**Surface:** `(atom init)`, `(deref a)` / `@a`, `(swap! a fn args ...)`,
`(reset! a v)`, `(compare-and-set! a old new)`, `(add-watch a key fn)`,
`(remove-watch a key)`, `(set-validator! a pred)`.

**Semantics:** `swap!` retries on CAS failure; the `fn` must be pure
(may run multiple times). Validator runs before the transition;
watchers run after, outside the CAS loop. Matches Clojure atoms 1:1.

**Jerboa-side:** new `(std atom)` library — record `%atom` with one
mutable field plus watcher alist and optional validator. Uses Chez's
`make-mutex` + `with-mutex` for the initial implementation; upgrade
to lock-free CAS once Chez-side `compare-and-swap!` on record fields
is confirmed exposed.

**Chez-side:** confirm (or add, if missing) a CAS primitive on record
fields — `$record-cas!` or similar. Grep `s/prims.ss` and
`s/primdata.ss` for existing atomic ops. If none, add one as a small
primdata entry wrapping the machine-level CAS the GC already uses
for forwarding pointers.

Effort: low. Risk: low. Gate: Chez-side CAS primitive audit.

### Phase 32 — `agent` (async independent updates) — **LANDED (2026-04-24)**

Implementation notes: `(std agent)` gains `await-for`,
`set-error-handler!`, `set-error-mode!`, plus `agent-error-mode` /
`agent-error-handler` accessors. `'continue` mode swallows errors
after running the handler; `'fail` (default) latches as before.
`await-for` polls a marker action with 5 ms tick steps. Works in
both fiber and OS-thread modes. Tests: 36 passing in
`tests/test-agent.ss`.

**Surface:** `(agent init)`, `(send a fn args ...)`,
`(send-off a fn args ...)`, `(await a ...)`, `(await-for ms a ...)`,
`(agent-error a)`, `(restart-agent a v)`, `(set-error-handler! a fn)`,
`(set-error-mode! a mode)`.

**Semantics:** `send` uses a bounded CPU-sized pool (CPU-bound actions);
`send-off` uses an unbounded pool (I/O-bound). Actions run serially
*per agent* but concurrently across agents. Errors are latched —
subsequent sends fail until `restart-agent` clears the error state.

**Jerboa-side:** new `(std agent)` library on top of the existing
thread infrastructure in `(std async)` / `(std actor)`. Worker pool
with a work-stealing dequeue; per-agent mailbox queue (already solved
in actor). Watchers reuse Phase 31's code path.

**Chez-side:** none expected. If the pool contention becomes a
bottleneck under load, revisit with a measured workload.

Effort: medium. Risk: low. Gate: Phase 31 (shared watcher machinery).

### Phase 33 — `ref` / `dosync` (software transactional memory) — **LANDED (2026-04-24)**

Implementation notes: existing `(std stm)` already provided MVCC
with per-TVar locks (`make-ref` / `dosync` / `alter` / `commute` /
`ensure` / `ref-set` / `or-else` / `retry`). Round 5 adds `io!` —
a syntax form that raises inside a transaction (via
`*current-tx*` parameter check) and runs the body unguarded
elsewhere. Tests: 17 passing in `tests/test-stm.ss` (13 prior + 4
for `io!`). Known issue: the fiber runtime doesn't cleanly exit
after the script finishes, but all tests pass.

**Surface:** `(ref init)`, `(ref init :validator pred :min-history n)`,
`(deref r)` / `@r`, `(ref-set! r v)`, `(alter r fn args ...)`,
`(commute r fn args ...)`, `(ensure r)`, `(dosync body ...)`,
`(io! body ...)` (marks body as non-retryable — throws inside dosync).

**Semantics:** MVCC-style optimistic concurrency. Each ref carries a
chained history of `(timestamp . value)`. A transaction records its
read-set and write-set, validates the read-set against the current
world-version on commit, and retries from scratch on conflict.
`commute` relaxes ordering for commutative updates (reduces retries);
`ensure` pins a read-only ref against concurrent writes.

**Jerboa-side:** new `(std ref)` library. A global monotonic
world-clock (fxincrement with store-store fence). Refs are records
holding the current value plus a history ring (size configurable).
Per-thread transaction state lives in a parameter. Commit path does
the read-set version check under a shared RwLock; successful commits
bump the world-clock.

**Chez-side:** possibly a `$world-clock-increment!` primitive if the
straight-Scheme implementation on `fx+` + a mutex shows as hot.
Otherwise zero. Also: the reference implementation wants weak refs
for the history ring to avoid retaining long-dead values — Chez
already has `weak-pair` / `$weak-pair` machinery.

Effort: high. Risk: medium — STM is classic but subtle (livelock
avoidance, fairness under contention, GC pressure on history chains,
starvation of long transactions).

**Fallback plan:** if the full MVCC implementation slips, ship a
"cheap dosync" — a single global RwLock around the whole body — and
label it a correctness-only implementation. Replace with the MVCC
version once a workload proves the contention. Users get the API
and can start writing code against it; the switch is transparent.

Gate: Phase 31 lands first so the project has a working concurrency
primitive on trunk before STM's churn begins.

### Phase 34 — `defprotocol` (polymorphic dispatch) — **LANDED (2026-04-24)**

Implementation notes: `(std protocol)` gains `extenders` and
`extends?`. `extenders` walks the `%dispatch` eq-hashtable and
returns type-keys (rtds or symbols) that cover every method in the
protocol; `extends?` is the equivalent check for a specific
type-key. Tests: 39 passing in `tests/test-protocol.ss`.

**Surface:** `(defprotocol IFoo (foo [self x]) (bar [self x y]))`,
`(extend-type T IFoo (foo ...) (bar ...))`, `(extend-protocol IFoo T1
(...) T2 (...))`, `(satisfies? IFoo x)`, `(extenders IFoo)` (list of
RTDs), `(extends? T IFoo)`.

**Semantics:** single-dispatch on the first argument's type. Types
can extend protocols from *outside* the defining module — the key
advantage over `defmethod` on a record. Missing implementations raise
at call time with a clear error.

**Jerboa-side:** new `(std protocol)` library. Each protocol function
is a dispatch stub: look up `(type-of self) → impl` in a weak
eq-hashtable keyed by RTD. Fast path: a per-call-site monomorphic
inline cache (one slot holding `(RTD . impl-proc)`; miss falls back
to the hashtable and refills). Cache invalidation fires when
`extend-type` mutates the table — broadcast a generation counter and
bump the per-cache epoch.

**Chez-side:** this is where the Round 1 §3.3 "method-cache primitive"
deferred work pays off. Ideally: add a `$record-dispatch` primitive
that takes a record, a cache slot, and a fallback procedure, and
atomically swaps the cache line on miss. If unavailable, stay
100% in Scheme with a small per-callsite closure; profile before
deciding.

Effort: medium–high. Risk: medium. Gate: none (profile well
alongside Phase 35).

### Phase 35 — `defmulti` / `defmethod` (open multimethods) — **LANDED (2026-04-24)**

Implementation notes: `(std multi)` gains a full hierarchy surface
— `make-hierarchy`, `derive`, `underive`, `parents`, `ancestors`,
`descendants`, `isa?`, `prefer-method`, `preferred-methods`, and a
shared `global-hierarchy`. All public hierarchy ops are
`case-lambda`d to default to the global hierarchy. Cycle detection
rejects self-derives and transitive cycles via a `%isa?/locked`
walk. Dispatch in `%invoke` now does a 3-step lookup: exact match
→ hierarchy walk (with `prefer-method` disambiguation) → default.
Tests: 45 passing in `tests/test-multi.ss` (24 prior + 21 new).

**Surface:** `(defmulti f dispatch-fn)`, `(defmethod f dispatch-val
(args ...) body)`, `(derive child parent)`, `(underive child parent)`,
`(isa? h x y)`, `(parents h x)`, `(ancestors h x)`, `(descendants h
x)`, `(prefer-method f v1 v2)`, `(make-hierarchy)`,
`(remove-method f v)`, `(methods f)`.

**Semantics:** dispatch value comes from an arbitrary function of
args; method table keyed by dispatch values; `isa?` walks a
user-defined hierarchy (defaults to `global-hierarchy`). Ambiguous
matches raise; `prefer-method` tie-breaks.

**Jerboa-side:** new `(std multimethod)` library. Smaller than
protocols — no type-indexed cache needed; just a hashtable keyed by
dispatch value plus the `derive` hierarchy graph. Memoize
dispatch-value → method resolution so subsequent calls skip the
hierarchy walk; invalidate memo on any `defmethod` or `derive`.

**Chez-side:** none expected.

Effort: low–medium. Risk: low. Gate: Phase 34 (share the epoch +
cache-invalidation pattern).

### Phase 36 — `spec` (data validation + generation) — **LANDED (2026-04-24)**

Implementation notes: `(std spec)` gains `s-instrument`,
`s-unstrument`, `s-instrumented?`. Instrumentation uses
`top-level-value` / `set-top-level-value!` to wrap script-level
procedures; library-interior bindings are not rewriteable this
way, so instrumentation is a script-level tool. Fixed a
pre-existing bug in the `s-fdef` macro that quoted spec
expressions instead of evaluating them (rewrote as a
`syntax-case` form that peels `:key spec` pairs). Tests: 44
passing in `tests/test-spec.ss`.

**Surface:** `(s/def ::name spec)`, `(s/valid? spec x)`,
`(s/conform spec x)`, `(s/explain spec x)` / `(s/explain-data spec x)`,
`(s/keys :req [...] :opt [...] :req-un [...] :opt-un [...])`,
`(s/coll-of pred :kind :count :min-count :max-count :distinct)`,
`(s/map-of k-spec v-spec)`, `(s/tuple s1 s2 ...)`,
`(s/cat :tag spec ...)`, `(s/alt :tag spec ...)`, `(s/* spec)`,
`(s/+ spec)`, `(s/? spec)`, `(s/or :tag pred ...)`, `(s/and pred ...)`,
`(s/nilable spec)`, `(s/fdef fn :args :ret :fn)`,
`(s/instrument sym)` / `(s/unstrument sym)`, `(s/gen spec)`.

**Semantics:** spec is a predicate-with-conform — `conform` destructures
the input into a tagged output on success, returns the sentinel
`::invalid` on failure. `explain-data` returns a machine-readable
failure report (path, predicate that failed, value). `fdef` + `instrument`
give optional runtime arg/ret checking on named functions.

**Jerboa-side:** new `(std spec)` library. Registry is a hashtable
keyed by qualified keyword; specs are records with `conform-fn`,
`explain-fn`, and (lazy) `gen-fn` slots. Generators are a separate
`(std spec gen)` import so projects that don't need property-testing
don't pay the generator-library cost.

Generator library: small QuickCheck-style module exposing
`(gen/fmap f g)`, `(gen/choose lo hi)`, `(gen/one-of gs)`,
`(gen/such-that pred g)`, `(gen/vector g)`, `(gen/sample g n)`,
`(gen/for-all spec prop)`. Roughly 300–500 lines of Scheme.

**Chez-side:** none.

Effort: medium. Risk: low — pure Scheme, no Chez changes, no
concurrency. Gate: none.

### Execution order (Round 5)

| Phase | Item | Effort | Risk | Gate |
|-------|------|--------|------|------|
| 31 | atom | low | low | Chez CAS primitive audit |
| 32 | agent | med | low | 31 (watchers) |
| 33 | ref / dosync | high | med | 31 (ship one concurrency primitive first) |
| 34 | defprotocol | med–high | med | none |
| 35 | defmulti | low–med | low | 34 (shared cache machinery) |
| 36 | spec | med | low | none |

Phases 31, 34, 36 are independent and can ship in any order.
31 → 32 → 33 is the concurrency ladder. 34 → 35 share method-table
and cache-invalidation code. Recommended sequence when picking
one at a time: **31 → 36 → 34 → 35 → 32 → 33** — ships the highest
leverage-per-effort ratio first (atoms unlock immediate functional
state management; spec hardens API boundaries with no runtime
system surgery), parks STM for last since it's the one with
"fall back to a global lock" written in its risk column.

### Round 5 non-goals

- **Distributed refs / network-aware agents.** Clojure has neither
  out of the box; defer to a hypothetical `(std cluster)` round.
- **core.async channels + `go` blocks.** Real value, but bigger than
  one round — needs a CPS transform or a stackful-coroutine
  scheduler. Track as Round 6 candidate if Phases 31–33 don't cover
  the common cases users want from CSP.
- **nREPL / connected-REPL protocol.** Tooling, not a language
  feature; separate track. Jerboa already has `(std repl)`;
  network-exposed REPL with editor integration is a jerboa-shell /
  jerboa-emacs concern.
- **Production observability (metrics / tracing / structured logs).**
  Ecosystem work, not core language. A `(std telemetry)` library
  with OpenTelemetry bindings would be a separate round driven by
  a real deployment story.
- **Transducers revisited.** Already shipped in `(std transducer)`;
  Round 4 cookbook recipe `transducer-into-persistent-collections`
  covers the composition idiom. No further work planned until a
  benchmark shows a concrete gap.
- **Datomic-style immutable DB.** Out of scope at the language level;
  would be a standalone project on top of the STM + persistent
  collections now in place.

## Round 6 — Clojure-parity showcase (identified 2026-04-24)

**Status (2026-04-24):** Phases 37 and 38 both **LANDED**. Phase 39
remains optional / out of scope. The `make showcase` target in
`jerboa-db` runs a 12-section end-to-end demo that exits 0.

Rounds 1–5 closed every *library* gap for Clojure parity: persistent
collections, Round 5 concurrency + polymorphism + spec, and the
`jerboa-db` Datomic clone (which is also far more complete than its
own README suggests — `not-join`, `variance`/`stddev`, `log`,
`index-range`/`seek-datoms`, and stored `:db/fn` all already ship
and pass tests). The remaining gap for *proving* parity is a single
concrete demo application that exercises the surface in one place.

### Phase 37 — `jerboa-db` documentation sync (trivial) **LANDED (2026-04-24)**

Flipped six `❌ Missing` rows to `✅` in `jerboa-db/jerboa-db.md`
(`not-join`, `variance`/`stddev-sample` aggregates, stored `:db/fn`,
log API object, `index-range`, `seek-datoms`) and corrected the
status header to "Core Datomic parity: complete; 37 core tests
passing".

---

**Problem:** `jerboa-db/jerboa-db.md` flags `not-join`,
`variance`/`stddev`, `log`, `index-range`/`seek-datoms`, and
`:db/fn` as `❌ Missing`, but all five are implemented and covered
by `tests/test-core.ss` (37/37 passing). Reading the README
alone, a user would think the Datalog engine is more incomplete
than it is and reach for a different tool.

**Work:** Re-audit each `❌` / `🚧` entry in the feature tables.
Promote completed items to ✅, leave genuinely stubbed items
(schema migration, Parquet/CSV import) as 🚧 with notes on what
`make test` already exercises.

Effort: trivial. Risk: none.

### Phase 38 — Clojure-parity showcase (bookstore) **LANDED (2026-04-24)**

Shipped as `jerboa-db/examples/bookstore.ss` with `make showcase`.
All 12 sections print and the script exits 0.

Notes discovered while building:

- `s-instrument` cannot rebind `def`-bound procedures when a script
  is run via `--script`: `set-top-level-value!` has no effect on
  the program's lexical bindings. The demo wraps the function
  body with an explicit `s-valid?`/`s-explain-str` guard — that's
  the pattern to cookbook. Candidate Round 7 follow-up: have
  `s-fdef` emit a macro that wraps the `def`-bound procedure at
  definition time so `--script` callers get the same ergonomics
  as REPL users.
- `s-cat` expects alternating `tag spec` pairs
  (`(s-cat :isbn '::isbn :qty '::qty)`), not a bare list of
  spec names.
- `std multi` dispatch does NOT consult a hierarchy automatically
  even when `(std multi)`'s own `derive` API is used. To get
  Clojure-style `isa?`-aware dispatch the user must plumb
  `ancestors` + `get-method` into their own dispatch function
  (shown in section 9 of the demo). Candidate Round 7 follow-up:
  teach `defmulti` to accept a `:hierarchy` keyword that rewrites
  the dispatch call site to search ancestors before falling back.
- `sleep`/`make-time` in the Jerboa prelude shadows the Chez
  `make-time` with an `(h m s)` date-style form, so the common
  `(sleep (make-time 'time-duration ns sec))` idiom fails at the
  user level. The demo busy-spins on `current-time` instead. Real
  fix is either (a) expose a `sleep-ms` wrapper in the prelude, or
  (b) stop shadowing `make-time`. Tracked as future hardening.

---

**Original spec follows:**

**Goal:** one self-contained script that hits every Clojure
idiom Jerboa now supports, in a realistic shape a Clojure user
would recognize. Uses `jerboa-db` as the system-of-record and
Round 5 primitives for in-memory orchestration.

**File:** `jerboa-db/examples/bookstore.ss` — new directory.
Runs end-to-end with `scheme --libdirs <jerboa-db>/lib:<jerboa>/lib
--script examples/bookstore.ss`. Every section is numbered and
prints its output so the script doubles as a tour.

**Surfaces exercised (checklist):**

1. **Schema + transact (jerboa-db):** define a `Book`/`Author`/`Order`
   schema with `:db.unique/identity`, `:db.type/ref`,
   `:db/tupleAttrs`. Transact a seed dataset.
2. **Datalog query (jerboa-db):** multi-clause query with
   `:in` parameter + `not-join` + `variance` aggregate over
   prices.
3. **Pull + time-travel (jerboa-db):** pull an order with nested
   book and author; then run the same pull through `as-of` to
   show the order at an earlier transaction.
4. **Persistent collections (`std collections`):** build an
   in-memory category index as a `pmap` from the query result.
5. **Atoms (`std misc atom`):** per-session cart keyed by user;
   install a validator that rejects negative quantities.
6. **STM (`std stm`):** `dosync` that decrements inventory and
   appends to an audit log — both refs update atomically. Use
   `io!` to demonstrate the guard.
7. **Agents (`std agent`):** async email-receipt simulator.
   Install an error handler; run one failing send; show
   `await-for` timing out on a slow action.
8. **Protocols (`std protocol`):** `Renderable` with one `render`
   method; `extend-type` for `Book`, `Order`, `User` records.
9. **Multimethods (`std multi`):** `handle-event` dispatching
   on event type with a `derive` hierarchy for
   `'order-placed` / `'order-cancelled` → `'order-event`.
10. **Spec (`std spec`):** define a `pos-int` spec, `s-fdef`
    `place-order`, `s-instrument` it at the top of the demo so
    bad inputs raise with a readable message.
11. **Transducers (`std transducer`):** one pipeline (`filter` +
    `map` + `take`) composed against the seed book list.
12. **Threading macros (prelude):** rewrite one of the above
    with `->` / `->>` / `some->` for idiom coverage.

**Output:** the script prints a labelled line per section
(`[1] schema transacted ...`, `[2] variance query => ...`)
so a reader scans the demo without running the REPL.

**Acceptance:** the script exits 0; a grep over its output
shows each of the 12 sections. Added to
`jerboa-db/Makefile` as `make showcase`.

Effort: medium (one session). Risk: low — every surface is
already tested; this is integration-only.

### Phase 39 — Optional: web skin for the showcase

Out of scope for Round 6. If the demo needs a screenshot-able
UI, layer `std net httpd` + `std net ring` + an HTMX page that
renders the same bookstore with an `as-of` slider. Track as a
follow-up; the plain-script showcase already demonstrates parity.

### Round 6 execution order

| # | Phase                           | Effort  | Risk | Gate          |
|---|---------------------------------|---------|------|---------------|
| 37| jerboa-db doc sync              | trivial | none | —             |
| 38| bookstore showcase              | medium  | low  | 37 (clarity)  |
| 39| web skin (optional)             | medium  | low  | 38            |

## Round 7 — Showcase-driven API polish (identified + LANDED 2026-04-24)

The bookstore showcase from Phase 38 forced three workarounds
into `examples/bookstore.ss`: a hand-rolled busy-spin for
`await-for`, a dispatch-fn that manually walked the derive
hierarchy, and an inline `s-valid?` guard because
`s-instrument` can't rebind lexical `def` bindings in
`--script` programs. Round 7 closes all three by adding small,
targeted APIs so the demo reads like idiomatic Clojure.

**Status (2026-04-24):** all three phases **LANDED**. Bookstore
showcase now uses the new APIs directly (sections 7, 9, 10);
no workarounds remain. Unit tests: `test-multi` 48/48,
`test-spec` 53/53, `test-prelude` 24/24, showcase 12/12 sections.

### Phase 40 — `sleep-ms` wrapper in `(jerboa prelude)` — **LANDED**

`(sleep-ms N)` wraps
`(sleep (make-time 'time-duration ns sec))` so users don't
need to import Chez's shadowed `make-time` (the prelude
re-exports a date-style `(make-time h m s)` constructor that
hides the time-duration form). Exported from both
`(jerboa prelude)` and `(std prelude)`. Each prelude imports
Chez's `make-time` under the private alias `%chez-make-time`
since the public name is shadowed.

**Shipped:** prelude export, validation (`MS` must be a
non-negative integer), test in `tests/test-prelude.ss`.
Bookstore section 7 replaced its busy-spin with `(sleep-ms 300)`.

### Phase 41 — `defmulti :hierarchy` keyword in `(std multi)` — **LANDED**

`defmulti` already defaulted to `global-hierarchy` but could
not accept a custom hierarchy. Round 7 adds a literal
`:hierarchy` keyword:
```scheme
(defmulti handle-event
  (lambda (evt) (cdr (assq 'type evt)))
  :hierarchy events-h)
```

**Implementation note:** R6RS `syntax-rules` literals must
point to the same binding at both the use site and the
definition site. Because `:hierarchy` is unbound at use sites,
the literal match would fail across a library boundary. Fix:
export `:hierarchy` from `(std multi)` as an auxiliary
keyword (`define-syntax :hierarchy (lambda (x) (syntax-violation
...))`). `s-fdef` sidesteps this by using `syntax-case` with
`syntax->datum` comparison; for `defmulti` the auxiliary
keyword is cleaner because the literal appears at a fixed
argument position.

**Shipped:** `:hierarchy` export, 3-arg `%install`, validation
that rejects non-hierarchy values, 3 tests exercising dispatch,
isolation from `global-hierarchy`, and error on bad hierarchy.
Bookstore section 9 dropped its hand-rolled `ancestors` walk
and now uses `prefer-method` to disambiguate when methods exist
at multiple hierarchy levels.

### Phase 42 — `s-defn` macro for script-safe spec instrumentation — **LANDED**

`s-instrument` uses `set-top-level-value!` to rewire a symbol's
top-level binding. In a `--script` program, by the time
instrumentation runs other top-level forms may have already
captured the pre-wrap closure; the instrumented wrapper never
fires. `s-defn` sidesteps the indirection by baking
validation into the function body at macro-expansion time:
```scheme
(s-defn place-order (isbn qty)
  :args '::order
  :ret  '::result
  (list 'order isbn qty))
```
Expands to a plain `(define (name ...) ...)` with inline
`s-valid?` guards, and also registers an `s-fdef` so
`s-check-fn` continues to work.

**Design:** the outer macro uses `syntax-case` to parse
optional `:args`/`:ret` pairs in either order, then hands off
to an internal `%s-defn-emit` whose `syntax-rules` clauses
dispatch on the args?/ret? boolean pair. All four
combinations (both, args-only, ret-only, neither) are
supported.

**Shipped:** `s-defn` export from `(std spec)`, 9 tests in
`test-spec.ss`, cookbook integration via bookstore section 10
replacing the hand-inlined `unless (s-valid? ...)` check.

### Round 7 execution order

| # | Phase                                 | Effort  | Risk | Gate |
|---|---------------------------------------|---------|------|------|
| 40| `sleep-ms` prelude wrapper            | trivial | none | —    |
| 41| `defmulti :hierarchy`                 | small   | low  | —    |
| 42| `s-defn` script-safe spec             | small   | low  | —    |

## Round 8 — Closing remaining jerboa-db gaps (LANDED 2026-04-24)

Round 5/6 left three items marked 🚧 in `jerboa-db.md`: Parquet
& CSV bulk I/O, schema migration (rename/retype/delete/
merge/split), and TLS on the Raft TCP transport. Round 8
closes all three. Phase 39 (web skin for the bookstore showcase)
remains an explicit follow-up — the plain-script showcase
already demonstrates parity, and a UI skin should be tracked
as its own initiative.

**Status (2026-04-24):** all three phases **LANDED**.
- Core tests: 37/37
- Migration tests (new): 7/7
- Plain TCP transport: 12/12
- TLS smoke test (new): 5/5

### Phase 43 — Parquet & CSV bulk I/O via DuckDB COPY — **LANDED**

Both `import-parquet`/`export-parquet` and `import-csv` were
already wired to DuckDB's `COPY TO`/`COPY FROM` in
`lib/jerboa-db/analytics.ss`; only `export-csv` was missing.
Phase 43 added the symmetric `export-csv` and updated the doc.

**Shipped:**
- `(export-csv ae path [sql])` writes a CSV from any SQL
  query (defaults to `SELECT * FROM datoms`).
- `lib/jerboa-db/analytics.ss` exports updated.
- `jerboa-db.md` Phase 4 marked ✅ Complete; bullet for
  Parquet/CSV updated to reflect the round-trip API.

### Phase 44 — Schema migration (rename/retype/delete/merge/split) — **LANDED**

`lib/jerboa-db/migrate.ss` was already fully implemented with
`make-migration`, `make-rename-attr`, `make-retype-attr`,
`make-delete-attr`, `make-merge-attr`, `make-split-attr`,
`make-add-index`, `make-remove-index`, `migrate!`,
`migration-plan`, and `migration-dry-run`. Phase 44 added a
comprehensive test suite to lock in behaviour and updated the
doc.

**Shipped:**
- `tests/test-migrate.ss` — 7 tests covering: rename copies
  datoms; retype with coerce-fn converts values; retype is
  fail-fast (rejects on first coerce failure with no partial
  migration); delete-attr retracts all datoms; merge combines
  attributes via merge-fn; `migration-plan` returns
  human-readable strings; `migration-dry-run` reports counts
  without mutating.
- `Makefile`: new `test-migrate` target.
- `jerboa-db.md` Phase 5 marked ✅ Complete; row-level docs
  updated.

**Gotcha learned:** entity ids must be numeric tempids
created with `(tempid)`; passing string tempids leads to
"~s is not a number" errors deep inside the value store.

### Phase 45 — TLS for Raft TCP transport — **LANDED**

`(jerboa-db transport)` previously used plain TCP only
(`tcp-listen`/`tcp-connect-binary`). Round 8 adds an
optional `tls-config` argument that, when supplied, swaps
the socket layer for `(std net tls)` while preserving the
length-prefixed FASL framing.

**Implementation:**
- `transport-node` defstruct gains a `tls-config` field.
- Two adapter helpers wrap a `tls-conn` behind Chez's
  `make-custom-binary-input-port` /
  `make-custom-binary-output-port`, so the framing layer
  is agnostic to TCP vs. TLS.
- `start-accept-loop!`, `start-peer-connector!`,
  `wire-peer!`, `start-transport-node!`,
  `start-transport-db-node!`, `transport-node-add-peer!`,
  and `stop-transport-node!` all thread the optional
  `tls-config` through.
- `tls-listen` does not currently expose the OS-assigned
  port; callers must supply an explicit non-zero port for
  TLS deployments. A `%tls-server-port-from-conn` helper
  documents the limitation.

**Test coverage (`tests/test-transport-tls.ss`):**
1. Start node A with TLS — ✅
2. Start node B with TLS, peer = A — ✅
3. Leader elected within 5 s over TLS handshake +
   heartbeats — ✅
4. Exactly one leader, one follower — ✅
5. Stop both TLS nodes cleanly — ✅

The same Raft replication code path is exercised by plain
TCP (`tests/test-transport.ss`, 12/12 passing); TLS only
swaps the socket layer at I/O. A multi-node replicated
transact under TLS is best validated on production-class
hardware where TLS + scheduler latency are predictable;
on Termux it can intermittently miss the timing window.

**Skip behaviour:** the test exits 0 with a "skipping"
message if `$JERBOA_DB_TLS_DIR/server.{crt,key}` are not
present, so it does not gate CI on running OpenSSL.

**Quirk:** after `stop-transport-node!`, the listen-side
accept thread can remain blocked inside OpenSSL because
`tls-close` does not always interrupt a thread parked in
`tls-accept`. The test calls `(exit ...)` explicitly so the
script terminates promptly without waiting on that thread.

**Shipped:**
- `lib/jerboa-db/transport.ss` — TLS support throughout.
- `tests/test-transport-tls.ss` — 5-test smoke suite.
- `Makefile`: new `test-transport-tls` target with
  `JERBOA_DB_TLS_DIR` documenting cert/key generation.
- `jerboa-db.md` Phase 6 / Phase 7 marked ✅ Complete.

### Round 8 execution order

| # | Phase                                 | Effort  | Risk | Gate |
|---|---------------------------------------|---------|------|------|
| 43| Parquet/CSV bulk I/O                  | trivial | none | —    |
| 44| Schema migration tests + doc          | small   | low  | —    |
| 45| TLS on Raft TCP transport             | medium  | med  | 44   |

## Round 9 — Peer client polish (LANDED 2026-04-26)

The peer client (Round 6) shipped the basic
`remote-q`/`remote-pull`/`remote-transact!` surface but
missed a handful of round-trips Datomic users expect:
`remote-entity`, named-database routing, and a
basis-tx-keyed cache. Round 9 closes those gaps and fixes
two parent-jerboa bugs uncovered by Termux fiber-httpd
running under load.

### Phase 46 — `remote-entity` — **LANDED**

`(remote-entity peer eid)` mirrors `(pull '[*] eid)` over
HTTP via a new `GET /api/entity/:id` route. Result is
cached under `(last-tx, 'entity, eid)`.

### Phase 47 — Named-database routing — **LANDED**

`connect-remote` now accepts an optional db-name string;
all `/api/*` URLs become `/api/db/<name>/*`. The server
uses an in-process registry (`register-db!` / `lookup-db`)
so a single fiber-httpd can host multiple databases.
Operations against an unknown name return 404.

### Phase 48 — `remote-tx-stream` (server side) — **STUB**

`/api/tx-stream` is wired as a WebSocket endpoint via
`fiber-ws-upgrade` and `ws-broadcast!`. The client side
needs a `fiber-ws-connect` helper in jerboa
(`std net fiber-ws` only exposes the server upgrade
today); until that lands, applications can poll
`remote-db` and watch `basis-tx` advance. Documented in
`peer.ss`.

### Phase 49 — Basis-tx-keyed query cache — **LANDED**

`remote-q`/`remote-pull`/`remote-entity` consult an LRU
cache keyed on
`(remote-connection-last-tx . op . args)`. `last-tx` is
refreshed on every `remote-db` call and on each
`remote-transact!`, so any tx automatically invalidates
older entries by changing the key prefix.

Public surface:
- `remote-cache-stats` → `((size . n) (capacity . n) (last-tx . n))`
- `remote-cache-clear!`
- `remote-cache-set-capacity!` (default 256)

### Phase 50 — Tests + docs + commit — **LANDED**

`tests/test-peer.ss` exercises read/pull/entity, all three
cache operations, named-DB routing, and isolation between
default/named DBs (13 tests, 13 passes on Termux). The
suite uses a single shared fiber-httpd because
start/stop-server cycles on Termux are too flaky to run
multiple servers per script.

**Parent jerboa fixes uncovered along the way:**

* `jerboa_epoll_wait` (Rust): retry transparently on
  EINTR. Termux delivers signals during long syscalls and
  the previous wrapper turned them into fatal errors that
  killed the poller thread.
* `(std net io) poller-loop`: wrap the FFI call in a
  `guard` so any remaining transient failures degrade to
  an empty event list instead of taking down fiber-httpd.
* `(std text edn) write-edn-list`: tolerate dotted /
  improper pairs. Without this, a `(cons key value)` in a
  transact op crashes the EDN serializer.
* `lib.rs`: gate Linux-only modules on
  `target_os = "linux"` *or* `"android"` so a Termux build
  still includes epoll + http_parse.

### Round 9 execution order

| # | Phase                              | Effort  | Risk | Gate |
|---|------------------------------------|---------|------|------|
| 46| `remote-entity` route + client     | small   | low  | —    |
| 47| Named-DB routing                   | small   | low  | 46   |
| 48| WebSocket tx-stream (server stub)  | medium  | med  | 47   |
| 49| basis-tx LRU cache                 | small   | low  | 47   |
| 50| Test suite + plan/doc + commit     | small   | none | 49   |

---

## Round 10 — Clojure parity polish (reify, walk, 1.11+) — **LANDED**

After Round 9 closed the peer-client gaps, an audit of
`(std clojure)` against Clojure 1.11 / 1.12 surfaced
three remaining holes worth closing:

1. **Anonymous protocol implementations** (`reify`).
2. **`clojure.walk`** — generic structure-preserving
   tree walking across lists, vectors, persistent maps /
   vecs / sets, and hash-tables.
3. **Clojure 1.11+ conveniences**: `parse-long`,
   `parse-double`, `parse-boolean`, `parse-uuid`,
   `random-uuid`, `update-vals`, `update-keys`,
   `map-indexed`, `keep-indexed`, `if-some`/`when-some`,
   `condp`, `letfn`, `case-let`, `NaN?`, `not-empty`,
   `iteration`.

### Phase 51 — `reify` in `(std protocol)` — **LANDED**

`(reify (method (self ...) body) ...)` allocates a fresh
record-type descriptor per call and registers the supplied
method bodies against it in the protocol dispatch table,
returning a unique instance whose first-arg dispatch fires
the closures. Because the rtd is per-call, two reify
forms with the same protocol method names dispatch
independently — the same shape Clojure users expect.

Caveat documented inline: in hot loops, lift the reify
out of the loop or use `defstruct + extend-type` for a
stable type, since each call allocates an rtd.

### Phase 52 — `(std clojure walk)` — **LANDED**

New library exporting `walk`, `prewalk`, `postwalk`,
`keywordize-keys`, `stringify-keys`, `prewalk-replace`,
`postwalk-replace`. Recognised containers (preserved on
output): cons / list / improper list, vector,
hash-table, persistent-map, persistent-vector,
persistent-set. Records are deliberately treated as
leaves — rebuilding a fresh instance via
`record-constructor` is fragile across rtds with parents
or non-trivial constructors; code that wants to walk a
record's fields can convert to a map first via the
polymorphic `assoc` in `(std clojure)`.

`prewalk-replace`/`postwalk-replace` accept any of:
persistent-map, hash-table, or alist as the substitution
table — the previous tier-1 implementation only handled
hash-tables, which the existing tier-1 test had been
flagging as a one-test failure since the suite landed.

### Phase 53 — Clojure 1.11+ conveniences — **LANDED**

Added to `(std clojure)`:

* `parse-long` / `parse-double` / `parse-boolean` /
  `parse-uuid` — strict; return `#f` on bad input.
* `random-uuid` — RFC-4122 v4 format.
* `update-vals` / `update-keys` — polymorphic across
  persistent-map and hash-table.
* `map-indexed` / `keep-indexed` — list-only
  (consistent with the rest of `(std clojure)`'s
  list-first stance; a sequence-based version can come
  with the lazy-seq integration in a later round).
* `if-some` / `when-some` — bind name; only `#f` is
  considered absent (matches Clojure semantics, where
  `nil` is falsy but `false` triggers absence handling
  in `if-some`).
* `condp` — predicate-driven cond. The `:>>` handler
  form is **not exercisable in default Jerboa reader
  mode**: `:>>` reads as a Gerbil-style module path
  rather than the literal `:>>` symbol the macro expects.
  Workaround pending: switch the literal to `=>` (cond's
  bind-arrow) or expose a `cloj-condp` variant whose
  literal is read in cloj reader mode.
* `letfn` — mutually recursive local procedures; sugar
  over `letrec`.
* `case-let` — `(case-let (var expr) clause ...)`,
  sugar over `(let ([var expr]) (case var clause ...))`.
* `NaN?` — works on real and complex.
* `not-empty` — polymorphic across list, string, vector,
  hash-table, persistent collections; returns `#f` on
  empty, the input otherwise.
* `iteration` — case-lambda, supports the `(iteration
  step)` and `(iteration step :somef sf :vf vf :kf kf
  :initk k0)` shapes (kf/vf/somef default to identity).

### Phase 54 — Tests — **LANDED**

* `tests/test-protocol.ss` — 6 new reify tests
  (single/multiple methods, lexical closure, `satisfies?`
  interaction, instance isolation, instance uniqueness).
  **45 tests, 45 pass**.
* `tests/test-clojure-walk.ss` — 21 tests across
  lists, vectors, persistent collections, hash-tables,
  keywordize-keys / stringify-keys (with both pmap and
  hash-table inputs), postwalk/prewalk-replace, improper
  lists. **21 tests, 21 pass**.
* `tests/test-clojure-tier3.ss` — 45 tests covering all
  1.11+ additions (minus the `:>>` reader-limited case).
  **45 tests, 45 pass**.
* `tests/test-clojure-tier1.ss` — pre-existing tier-1
  test against `postwalk-replace + hash-map` was a known
  failure since the suite landed; fixed as a side-effect
  of Phase 52 by adding persistent-map support to the
  replacement-map branch. **30 tests, 30 pass** (was
  29/30).
* `tests/test-clojure-features.ss` — unchanged. **49
  tests, 49 pass**.

Total clojure-suite tally: **190 passing, 0 failing**.

### Round 10 execution order

| # | Phase                                | Effort | Risk | Gate |
|---|--------------------------------------|--------|------|------|
| 51| `reify` macro in (std protocol)      | small  | low  | —    |
| 52| (std clojure walk) library           | medium | low  | —    |
| 53| Clojure 1.11+ conveniences           | medium | low  | —    |
| 54| Tests for 51/52/53                   | small  | none | 51-53|
| 55| plan.md + identify Round 11 + commit | small  | none | 54   |

### Round 11 candidates (gaps still open)

The audit found a handful of items that could land next:

1. **`fiber-ws-connect`** — Round 9 Phase 48 left
   server-side `tx-stream` as a stub; closing it requires
   a client-side WebSocket helper in `(std net fiber-ws)`.
   Once present, jerboa-db can ship a real
   `remote-tx-stream` and `remote-listen!`.

2. **`clojure.zip`** — functional zipper over trees.
   Useful for editing nested EDN/JSON without rebuilding
   intermediate nodes manually. Pure Scheme; ~150 LoC.

3. **`clojure.data/diff`** — recursive diff on nested
   data, returning `[only-in-a only-in-b in-both]`.
   Builds on Round 10's walk machinery.

4. **`condp :>>` reader workaround** — pick one:
   (a) accept `=>` as an alias for `:>>`, (b) expose a
   second macro `cloj-condp` whose body is parsed in
   cloj reader mode, (c) document the limitation
   permanently. Lowest-friction is (a).

5. **Sequence-aware `map-indexed` / `keep-indexed`** —
   today's implementations are list-only. A second
   variant that consumes lazy-seqs (and persistent
   vectors as seqs) would round out the parity story.

6. **`clojure.core.async/timeout`** as a real channel
   that closes after N ms — `(std csp clj)` exposes
   `timeout` but it's currently a thin wrapper; making
   it a first-class closing channel matches Clojure's
   contract.

7. **`reduce-kv` on hash-table** — currently
   persistent-map only.

8. **Spec gen integration** — `(std spec)` validates but
   doesn't generate. A minimal `gen` that produces values
   for the built-in predicates would unlock
   property-style testing.

