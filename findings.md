# Chez Scheme Security & Code Review Findings

## Summary

| Severity | Count |
|----------|-------|
| Critical | 3 |
| High | 7 |
| Medium | 10 |
| Low | 5 |

**Fixed:** 1-6, 10-11, 13-14, 16, 19-22 (see commit history)
**Unfixed (design-level):** 7-9, 12, 15, 17-18, 23-29

---

## Critical

### 1. Integer underflow in FASL decompression size calculation

**File:** `c/fasl.c:461-462`

```c
iptr dest_size = S_fasl_uptrin(f, &bytes_consumed);
iptr src_size = size - (2 + bytes_consumed);
```

`size`, `bytes_consumed`, and `dest_size` all come from the FASL file (untrusted input). If `2 + bytes_consumed > size`, `src_size` underflows to a large value. This corrupted `src_size` is then passed to `PREPARE_BYTEVECTOR` (line 464) and `S_fasl_bytesin` (line 466), potentially causing massive allocation or heap buffer overflow.

**Exploit:** Crafted `.so`/`.boot` file with manipulated compression header.

### 2. Unbounded pointer arithmetic in `fasl_record`

**File:** `c/fasl.c:1210-1254`

```c
n = uptrin(f);           // field count from untrusted FASL
*x = p = S_record(size_record_inst(size));
addr = (uptr)TO_PTR(&RECORDINSTIT(p, 0));
for (; n != 0; n -= 1) {
    padty = bytein(f);   // untrusted padding/type byte
    addr += padty >> 4;  // 0-15 bytes, no bounds check against allocation
    // ... writes to addr ...
}
```

The field count `n` and padding `padty` are read from untrusted input. There is no validation that `addr` stays within the bounds of the record allocated at line 1214. An attacker can craft a FASL file that walks `addr` past the record allocation, enabling heap buffer overflow.

### 3. Integer overflow in `stringin`

**File:** `c/fasl.c:754-764`

```c
end = start + (n = uptrin(f));  // no overflow check
if (Sstring_length(*pstrbuf) < end) {
    ptr newp = S_string((char *)0, end);  // allocates based on potentially wrapped value
```

If `start + n` overflows, `end` wraps to a small value, the length check passes, and subsequent writes at indices `[start, end)` overflow the string buffer. Called from symbol deserialization paths (lines 792, 798).

---

## High

### 4. Missing underflow check before `size -= 2`

**File:** `c/fasl.c:482`

```c
case fasl_type_uncompressed: {
    in_f = f;
    old_mode = f->buffer_mode;
    size -= 2;  /* no check that size >= 2 */
```

If `size` is 0 or 1, this underflows. The corrupted value is then assigned to `f->remaining` at line 485, enabling reading far past the end of the file buffer.

### 5. Multiplication overflow in FFI array type

**File:** `c/ffi.c:252-256`

```c
len = UNFIX(Scdr(type));
ffi_prep_cif(&cif, abi, 0, elem_out, NULL);
out->size = elem_out->size * len;  // no overflow check
```

If `elem_out->size * len` overflows, libffi receives an incorrect size, potentially causing buffer overflows during FFI calls with large array types.

### 6. `size_t` to `INT` truncation in LZ4 decompression

**File:** `c/compress-io.c:432-433`

```c
lz4->in_pos += (INT)in_len;
lz4->out_len = (INT)out_len;
```

`in_len` and `out_len` are `size_t` but cast to `INT` without overflow checking. If decompression produces output exceeding `INT_MAX`, these silently wrap, corrupting buffer position tracking.

### 7. Unsafe DLL downloads in CI without checksum verification

**File:** `.github/workflows/build.sh:16-22`

```sh
curl -Ls https://github.com/burgerrg/win-iconv/releases/download/v0.0.10/iconv-x64.dll > ...
```

Downloads third-party DLLs with no SHA256 verification, no timeout, and silent mode (`-s`) hiding failures. Supply-chain attack vector for Windows builds.

---

## Medium

### 8. Missing vector/bytevector size validation in FASL

**File:** `c/fasl.c:826-868`

Vector and bytevector sizes read via `uptrin(f)` are passed directly to `S_vector(n)` and `S_bytevector(n)` without checking for negative values or unreasonable sizes. A malicious FASL file could trigger excessive memory allocation (denial of service).

### 9. Deterministic symbol hash enables algorithmic DoS

**File:** `c/intern.c:113-136`

The symbol hash function is deterministic with no randomization (no hash seed). An attacker who can cause many symbols to be interned (e.g., via `read`) can craft inputs with hash collisions, degrading the oblist from O(1) to O(n) lookups.

### 10. Shell injection via unquoted sed variable in configure

**File:** `configure:1188`

```sh
sed -e 's/$(w)/'$w'/g' "$srcdir"/makefiles/"$makefile_in" > Makefile
```

`$w` (workarea path) is interpolated unquoted into a sed expression. Paths containing `/`, `&`, or regex metacharacters break the sed command or inject arbitrary sed expressions.

### 11. Unquoted variables in configure mkdir/cp/cat

**File:** `configure:1191-1204`

```sh
mkdir -p $w
cp "$srcdir"/makefiles/workmain.zuo $w/main.zuo
cat > $w/Mf-config << END
```

`$w` is unquoted, so paths with spaces or glob characters cause word-splitting.

### 12. GitHub Actions not pinned to commit SHAs

**File:** `.github/workflows/ci.yml`

```yaml
uses: actions/checkout@v4
uses: actions/upload-artifact@v4
```

Using version tags instead of full commit SHAs allows silent updates that could introduce supply-chain compromises.

### 13. `sprintf` without bounds in `prim5.c`

**File:** `c/prim5.c:2231`

```c
sprintf(msg, "cannot find %s in %s", what, dll);
```

Uses `sprintf` instead of `snprintf`. If `what` or `dll` exceed the buffer size, this overflows.

### 14. `strcpy` usage in boot path handling

**File:** `c/scheme.c:654`

```c
strcpy(boot->path, path);
```

While preceded by a length check against `BOOT_PATH_MAX`, using `strcpy` is fragile. Should use `memcpy` with explicit length or `strlcpy`.

### 15. No path validation in `load_shared_object`

**File:** `c/foreign.c:264`

```c
handle = dlopen(path, RTLD_NOW);
```

No C-side validation of the path before `dlopen`. While Scheme-side checks exist, the C entry point accepts arbitrary paths including relative paths and symlinks.

---

## Low

### 16. Typo in configure comment

**File:** `configure:1194`

```sh
# Stub Zuo script to lanch the real one
```

"lanch" should be "launch".

### 17. Environment variables used without length validation

**File:** `c/expeditor.c`

`getenv("TERM")`, `getenv("LINES")`, `getenv("COLUMNS")` are used without validating string length or numeric range. Low risk in practice since these are from the user's own environment.

### 18. Missing null checks in FFI callback paths

**File:** `c/ffi.c:603-698`

The `closure_callback` function dereferences vectors without null checks after GC, relying on immobility guarantees. Defensive null checks would be prudent.

---

## Round 2 Findings

### 19. Out-of-bounds array access in vfasl `find_pointer_from_offset` (FIXED)

**File:** `c/vfasl.c:579-589`

```c
while (p_off >= vspace_offsets[s+1])
    s++;
```

No bounds check on `s` against `vspaces_count`. A crafted vfasl file with an offset exceeding all vspace boundaries causes out-of-bounds read past the `vspace_offsets` array.

### 20. Unchecked array index in vfasl `lookup_singleton` (FIXED)

**File:** `c/vfasl.c:610-614`

```c
v = *(singleton_refs[which-1]);
```

`singleton_refs` has 14 elements. `which` comes from vfasl data via `UNFIX(*ref)`. No bounds check — a crafted vfasl file can cause out-of-bounds read.

### 21. Undefined variable `name` in HPUX branch (FIXED)

**File:** `c/foreign.c:194`

```c
v = proc2entry(v,name);  // should be 's', not 'name'
```

Compilation error on HPUX. The parameter is `s`, not `name`.

### 22. Integer overflow in `path_append` allocation (FIXED)

**File:** `c/self-exe.c:254-257`

```c
char *r = (char *)malloc(l1 + l2 + 2);
```

If `l1 + l2 + 2` wraps around due to overflow, a tiny buffer is allocated and subsequent `memcpy` overflows it.

### High (unfixed — require design-level changes)

### 23. Data race on `in_parallel_sweepers` in parallel GC

**File:** `c/gc.c:384, 399, 3098, 3121`

Global `in_parallel_sweepers` is read by sweeper threads via the `SEGMENT_IS_LOCAL` macro without synchronization, and written without holding any lock. On weakly-ordered architectures (ARM, PowerPC), readers can see stale values, causing incorrect sweep decisions.

### 24. TOCTOU race on mark bitmap initialization

**File:** `c/gc.c:505-537`

In parallel GC mode, multiple sweepers can check `!si->forwarded_flonums` or `!si->marked_mask` concurrently, both find NULL, and both initialize — the second write orphans the first allocation and corrupts mark bits.

### 25. Async-signal-unsafe functions in signal handlers

**File:** `c/schsig.c:315-338, 810-826`

Signal handlers call `fprintf`, `alloc_mutex_acquire`, `get_thread_context`, and Scheme allocation (`Scons`, `do_error`). These are not async-signal-safe per POSIX. If a signal arrives while `alloc_mutex` is held, the handler deadlocks.

### 26. Race on `S_collect_waiting_tcs` slot allocation

**File:** `c/thread.c:549-560`

Multiple threads can find the same slot empty in `S_collect_waiting_tcs[]` and both write to it, losing one thread's registration for parallel collection.

### Medium (unfixed)

### 27. `STORE_FENCE` insufficient for mark bitmap publication

**File:** `c/gc.c:505-512`

`init_mask` uses `STORE_FENCE()` before publishing the mask pointer. On ARM/Power, this only orders stores — a reader thread can see the pointer before the `memset` data, reading uninitialized mark bits.

### 28. Oblist resize not mutex-protected

**File:** `c/intern.c:66-101`

`S_resize_oblist()` rebuilds the hash table without holding `tc_mutex`. Concurrent interning can corrupt the oblist during resize.

### Low (unfixed)

### 29. Unbounded recursion in `wrint`

**File:** `c/print.c:312-318`

`wrint()` recurses once per decimal digit of a bignum. Extremely large bignums could overflow the C stack.

---

## Notes

- **FASL is the primary attack surface.** Findings 1-4 and 8 all involve deserializing untrusted FASL data. If Chez Scheme is used to load `.so`/`.boot` files from untrusted sources, these are exploitable. The mitigating factor is that most deployments only load trusted boot files.
- **The Scheme source files (s/*.ss) are well-balanced and correct.** Agent-based paren-counting reported false positives; manual verification confirms the files are properly structured (the compiler is self-hosting and passes its own test suite).
- **The C runtime follows a consistent pattern** of trusting FASL input, which is reasonable for a compiler loading its own output but risky if the trust model changes.
