# Debouncer

A debouncer runs one action after calls stop.

You set the action when you create the debouncer. Each later call moves the deadline forward. The action runs once, after the delay passes with no new call.

A call does not allocate memory while a run is waiting.

Crystal 1.21 or later is required.

## 1. Install

Add the shard to `shard.yml`:

```yaml
dependencies:
  debouncer:
    github: archipeldb/fast-debouncer
    version: ">= 0.1.0"
```

Then run `shards install`.

Load it with `require "debouncer"`.

## 2. Run one action

```crystal
require "debouncer"

save = Debouncer.new(50.milliseconds) { store }
save.call
```

`call` returns before the action runs. The action runs on a worker fiber.

Call `save.call` again before the delay ends. The action still runs once.

## 3. Keep the latest value

```crystal
search = Debouncer.for(String, 50.milliseconds) { |text| find(text) }
search.call("a")
search.call("ab")
```

The action receives `"ab"`.

The first call creates one small box for the value. Later calls reuse that box.

Use this form for a struct too. Pass the struct type as the first argument.

## 4. Stop or run now

`cancel` drops a waiting action. The action does not run.

`flush` runs a waiting action immediately. The action runs on the caller fiber.

`pending?` is true while a run is waiting.

```crystal
save.cancel
save.flush
save.pending?
```

## 5. Errors

An error in the action does not stop the debouncer.

`call` and `flush` raise that error on their next use. The error is raised once.

## 6. Fibers

You can call one debouncer from many fibers.

The worker stops when no run is waiting. The process can then exit.

`flush` can run the action on the caller fiber. Keep the action safe for that fiber.

## 7. Speed and memory

A call during a wait only stores a new time. That call allocates no memory.

The figures below come from one release build on Linux, with Crystal 1.21.1. A later run on your machine can differ. The pattern stays the same.

Repeat the test with:

```
crystal build bench/run.cr -o /tmp/debouncer-bench --release && /tmp/debouncer-bench
```

### While one debouncer is waiting

| Use | Calls per second | Allocated memory |
|---|---:|---:|
| One action | 40.7 million | 0 bytes per call |
| Latest value | 37.4 million | 0 bytes per call |

Peak memory stays flat during these calls.

The first call starts one worker fiber. In a run of one million calls, that start allocated **464 bytes**. Peak memory grew by **28 KB**.

The latest-value form creates one small box on the first call. Every later call reuses that box. After that box exists, further calls allocate **0 bytes**.

### More than one debouncer

Count the debouncers that are waiting, not the calls.

Each waiting debouncer has one worker fiber. The fiber stops when the action runs, or when you call `cancel`. A burst of calls on those debouncers adds no further memory.

| Waiting at the same time | Heap for each | Peak memory growth |
|---|---:|---:|
| 1 | 464 bytes for the start | 28 KB |
| 1,000 | about 680 bytes | about 4 MB (4,044 KB) |

Most of the 4 MB is the fibers. Plan for about **4 KB** of peak memory for each debouncer that is waiting.

If each debouncer finishes before you create the next one, the worker does not stay. A test of **2,000** finished uses allocated about **820 bytes** per use. Peak memory grew by **884 KB** for the whole test.

## 8. License

MIT. See `LICENSE`.
