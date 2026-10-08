require "../src/debouncer"

# Read the peak resident set size from the process status, in kibibytes.
def hwm_kb : Int64
  File.read("/proc/self/status").each_line do |line|
    if line.starts_with?("VmHWM:")
      return line.split[1].to_i64
    end
  end
  0_i64
end

# Read the current resident set size, in kibibytes.
def rss_kb : Int64
  File.read("/proc/self/status").each_line do |line|
    if line.starts_with?("VmRSS:")
      return line.split[1].to_i64
    end
  end
  0_i64
end

# Print one measurement. The block is the timed work.
def bench(label : String, count : Int32, &)
  GC.collect
  hwm0 = hwm_kb
  rss0 = rss_kb
  bytes0 = GC.stats.total_bytes
  started = Time.instant
  yield
  elapsed = started.elapsed
  bytes1 = GC.stats.total_bytes
  hwm1 = hwm_kb
  rss1 = rss_kb
  seconds = elapsed.total_seconds
  puts "#{label}"
  puts "  count=#{count}"
  puts "  seconds=#{seconds}"
  puts "  ops_per_sec=#{count / seconds}"
  puts "  alloc_bytes=#{bytes1 &- bytes0}"
  puts "  alloc_bytes_per_op=#{(bytes1 &- bytes0).to_f / count}"
  puts "  hwm_before_kb=#{hwm0} hwm_after_kb=#{hwm1} hwm_delta_kb=#{hwm1 &- hwm0}"
  puts "  rss_before_kb=#{rss0} rss_after_kb=#{rss1}"
end

n = 1_000_000

bench("after_call", n) do
  debouncer = Debouncer.new(1.hour) { }
  n.times { debouncer.call }
  debouncer.cancel
end

bench("after_latest", n) do
  debouncer = Debouncer.for(String, 1.hour) { |_text| }
  n.times { debouncer.call("item") }
  debouncer.cancel
end

# Steady state. The first call starts the worker. The sleep lets that worker park.
# The loop then only stores a new deadline.
debouncer = Debouncer.new(1.hour) { }
debouncer.call
sleep 1.millisecond
bench("after_hot_path", n) do
  n.times { debouncer.call }
end
debouncer.cancel

latest = Debouncer.for(String, 1.hour) { |_text| }
latest.call("item")
sleep 1.millisecond
bench("after_latest_hot_path", n) do
  n.times { latest.call("item") }
end
latest.cancel

cycles = 2_000
runs = Atomic(Int32).new(0)
bench("after_windows", cycles) do
  cycles.times do
    debouncer = Debouncer.new(1.millisecond) { runs.add(1) }
    debouncer.call
    sleep 3.milliseconds
  end
end
puts "  window_runs=#{runs.get}"

count = 1_000
bench("after_live_instances", count) do
  list = [] of Debouncer
  count.times do
    debouncer = Debouncer.new(1.hour) { }
    debouncer.call
    list << debouncer
  end
  bytes_mid = GC.stats.total_bytes
  puts "  live_hwm_kb=#{hwm_kb} live_rss_kb=#{rss_kb}"
  list.each(&.cancel)
  sleep 20.milliseconds
  puts "  after_cancel_rss_kb=#{rss_kb} note_bytes_mid=#{bytes_mid}"
end
