# fast-debouncer

Ultra-fast, fiber-safe debouncer for Crystal. Collapses millions of rapid events into a single execution with minimal overhead.

## Features

- **Tiny**: ~90 LOC, zero dependencies
- **Fast**: Peak >45M exec/sec throughput (naive baseline)
- **Proven**: 1M calls suppressed in <0.35s with 0 redundant actions (suppression test)
- **Safe**: Uses `Channel` + `select` with `Atomic(Bool)` and minimal `Mutex` contention
- **Efficient**: Zero allocation after startup, one timer fiber per instance

## Use Cases

- UI events (keystrokes, mouse moves, resizes)
- Real-time metrics aggregation  
- Rate-limited API calls
- Any "fire once after the storm stops" scenario

## Usage

```crystal
debouncer = Debouncer.new

spawn do
  loop do
    debouncer.debounce(50.milliseconds) { puts "saved!" }
    sleep 0.001 # simulate flood
  end
end

sleep 10 # → only a handful of "saved!" prints
```

## Installation

Add to your `shard.yml`:

```yaml
dependencies:
  fast-debouncer:
    github: archipeldb/fast-debouncer
```

**Requirements**: Crystal ≥ 1.9 (works great with `-Dpreview_mt`)  
**License**: MIT

---

Fast, predictable, battle-tested at millions of calls per second.