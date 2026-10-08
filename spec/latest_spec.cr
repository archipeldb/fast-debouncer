require "./spec_helper"

private record ProbePoint, x : Int32, y : Int32

describe "Debouncer.for" do
  it "passes the latest value to the action" do
    runs = Atomic(Int32).new(0)
    seen = Atomic(String?).new(nil)
    debouncer = Debouncer.for(String, 20.milliseconds) do |text|
      seen.set(text)
      runs.add(1)
    end
    debouncer.call("a")
    debouncer.call("ab")
    debouncer.call("abc")
    wait_until { runs.get == 1 }
    seen.get.should eq("abc")
    wait_until { !debouncer.pending? }
  end

  it "passes nil when nil is the latest value" do
    runs = Atomic(Int32).new(0)
    seen = Atomic(Int32).new(0)
    debouncer = Debouncer.for(String?, 20.milliseconds) do |value|
      seen.set(value ? 1 : 0)
      runs.add(1)
    end
    debouncer.call("set")
    debouncer.call(nil)
    wait_until { runs.get == 1 }
    seen.get.should eq(0)
  end

  it "passes the latest struct value" do
    runs = Atomic(Int32).new(0)
    seen = ProbePoint.new(0, 0)
    debouncer = Debouncer.for(ProbePoint, 20.milliseconds) do |point|
      seen = point
      runs.add(1)
    end
    debouncer.call(ProbePoint.new(1, 2))
    debouncer.call(ProbePoint.new(3, 4))
    wait_until { runs.get == 1 }
    seen.should eq(ProbePoint.new(3, 4))
  end

  it "updates the stored value after the first call" do
    runs = Atomic(Int32).new(0)
    seen = Atomic(Int32).new(0)
    debouncer = Debouncer.for(Int32, 20.milliseconds) do |number|
      seen.set(number)
      runs.add(1)
    end
    debouncer.call(1)
    wait_until { runs.get == 1 }
    debouncer.call(2)
    debouncer.call(3)
    wait_until { runs.get == 2 }
    seen.get.should eq(3)
  end

  it "flushes the latest value" do
    runs = Atomic(Int32).new(0)
    seen = Atomic(Int32).new(0)
    debouncer = Debouncer.for(Int32, 1.hour) do |number|
      seen.set(number)
      runs.add(1)
    end
    debouncer.call(4)
    debouncer.call(9)
    debouncer.pending?.should be_true
    debouncer.flush
    runs.get.should eq(1)
    seen.get.should eq(9)
    debouncer.pending?.should be_false
    sleep 10.milliseconds
    runs.get.should eq(1)
  end

  it "does not run a canceled value" do
    runs = Atomic(Int32).new(0)
    debouncer = Debouncer.for(Int32, 1.hour) { |_number| runs.add(1) }
    debouncer.call(1)
    debouncer.cancel
    sleep 20.milliseconds
    runs.get.should eq(0)
    debouncer.pending?.should be_false
  end

  it "raises a stored error on the next call" do
    runs = Atomic(Int32).new(0)
    debouncer = Debouncer.for(Int32, 20.milliseconds) do |number|
      previous = runs.add(1)
      raise "boom" if previous == 0
      number
    end
    debouncer.call(1)
    wait_until { runs.get == 1 }
    expect_raises(Exception, "boom") { debouncer.call(2) }
    wait_until { runs.get == 2 }
  end

  it "raises when flush runs an action that fails" do
    debouncer = Debouncer.for(Int32, 1.hour) { |_number| raise "now" }
    debouncer.call(1)
    expect_raises(Exception, "now") { debouncer.flush }
    sleep 10.milliseconds
    debouncer.pending?.should be_false
  end

  it "rejects a zero delay" do
    expect_raises(ArgumentError, "The delay must be greater than zero.") do
      Debouncer.for(Int32, 0.seconds) { |_value| }
    end
  end
end
