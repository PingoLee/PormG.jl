## Connection-pool wait is now direct-handoff (event-driven), not a busy-poll

- **PormG ref**: issue #124 (follow-up to #37) ; `src/ConnectionPool.jl`
- **Recorded**: 2026-07-16
- **Severity**: internal mechanism — **no action needed**. `acquire_connection`'s signature
  (`timeout_seconds`, `max_retries`, SQLite `mode`) and the `PoolTimeoutError` fields are unchanged.

### What changed

When the pool is saturated, `acquire_connection` used to `sleep(0.1)` and rescan (up to the
timeout/retry budget). It now **parks** the caller and is woken the instant a connection is
released — the returner hands the freed slot *directly* to the oldest compatible waiter (FIFO, no
barging; HikariCP / Go `database/sql` style). Handoff latency drops from up to ~100 ms to
sub-millisecond, waiters are served fairly, and there is no more per-100 ms rescan spam. A genuine
saturation still throws the same catchable `PoolTimeoutError`.

### Nothing to grep

No API changed. One **diagnostic** nuance: `PoolTimeoutError.attempts` now counts scan iterations
(typically `1` on a clean saturated timeout) rather than the old ~`timeout/0.1s` poll count. If you
log or assert on `attempts`, expect a much smaller number; it remains `>= 1`.
