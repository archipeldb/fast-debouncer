require "./spec_helper"

# Subclass used to force the idle and claim races.
class IdleProbe < Debouncer
  property? rearm = false
  property? steal = false
  property gate : Channel(Nil)? = nil

  protected def before_idle : Nil
    return unless rearm?
    self.rearm = false
    call
  end

  protected def after_idle : Nil
    channel = gate
    return unless channel
    self.gate = nil
    channel.send(nil)
    channel.receive
  end

  protected def before_claim(target : UInt64) : Nil
    return unless steal?
    self.steal = false
    call
  end
end

describe Debouncer do
  describe ".new" do
    it "rejects a zero delay" do
      expect_raises(ArgumentError, "The delay must be greater than zero.") do
        Debouncer.new(0.seconds) { }
      end
    end

    it "rejects a negative delay" do
      expect_raises(ArgumentError, "The delay must be greater than zero.") do
        Debouncer.new(Time::Span.new(nanoseconds: -1)) { }
      end
    end

    it "rejects a delay that does not fit in the monotonic clock" do
      seconds = (Int64::MAX // Time::NANOSECONDS_PER_SECOND) + 1
      long = Time::Span.new(seconds: seconds)
      expect_raises(ArgumentError, "The delay is too long.") do
        Debouncer.new(long) { }
      end
    end
  end

  it "exposes the version" do
    Debouncer::VERSION.should eq("0.1.0")
  end

  it "runs the action once after the quiet period" do
    runs = Atomic(Int32).new(0)
    debouncer = Debouncer.new(20.milliseconds) { runs.add(1) }
    debouncer.pending?.should be_false

    debouncer.call
    debouncer.pending?.should be_true
    sleep 5.milliseconds
    runs.get.should eq(0)

    wait_until { runs.get == 1 }
    wait_until { !debouncer.pending? }
    sleep 30.milliseconds
    runs.get.should eq(1)
  end

  it "collapses a burst into one run" do
    runs = Atomic(Int32).new(0)
    debouncer = Debouncer.new(30.milliseconds) { runs.add(1) }
    1_000.times { debouncer.call }
    wait_until { runs.get == 1 }
    wait_until { !debouncer.pending? }
    runs.get.should eq(1)
  end

  it "starts a new quiet period after the action runs" do
    runs = Atomic(Int32).new(0)
    debouncer = Debouncer.new(20.milliseconds) { runs.add(1) }
    debouncer.call
    wait_until { runs.get == 1 }
    debouncer.call
    wait_until { runs.get == 2 }
  end

  it "schedules another run when the action calls the debouncer" do
    runs = Atomic(Int32).new(0)
    holder = [] of Debouncer
    holder << Debouncer.new(20.milliseconds) do
      previous = runs.add(1)
      holder[0].call if previous == 0
    end
    holder[0].call
    wait_until { runs.get == 2 }
    wait_until { !holder[0].pending? }
  end

  it "does not run a canceled action" do
    runs = Atomic(Int32).new(0)
    debouncer = Debouncer.new(1.hour) { runs.add(1) }
    debouncer.call
    debouncer.cancel
    debouncer.cancel
    sleep 20.milliseconds
    runs.get.should eq(0)
    debouncer.pending?.should be_false
  end

  it "runs again when a call follows cancel" do
    runs = Atomic(Int32).new(0)
    debouncer = Debouncer.new(20.milliseconds) { runs.add(1) }
    debouncer.call
    debouncer.cancel
    debouncer.call
    wait_until { runs.get == 1 }
  end

  it "runs a waiting action on flush and does not run it again" do
    runs = Atomic(Int32).new(0)
    debouncer = Debouncer.new(1.hour) { runs.add(1) }
    debouncer.call
    debouncer.flush
    sleep 20.milliseconds
    runs.get.should eq(1)
    debouncer.pending?.should be_false
    debouncer.flush
    runs.get.should eq(1)
  end

  it "does nothing on flush when no call is waiting" do
    runs = Atomic(Int32).new(0)
    debouncer = Debouncer.new(20.milliseconds) { runs.add(1) }
    debouncer.flush
    sleep 30.milliseconds
    runs.get.should eq(0)
  end

  it "raises a stored action error on the next call" do
    runs = Atomic(Int32).new(0)
    debouncer = Debouncer.new(20.milliseconds) do
      previous = runs.add(1)
      raise "boom" if previous == 0
    end
    debouncer.call
    wait_until { runs.get == 1 }
    expect_raises(Exception, "boom") { debouncer.call }
    wait_until { runs.get == 2 }
  end

  it "raises a stored action error on flush" do
    runs = Atomic(Int32).new(0)
    debouncer = Debouncer.new(20.milliseconds) do
      runs.add(1)
      raise "boom"
    end
    debouncer.call
    wait_until { runs.get == 1 }
    expect_raises(Exception, "boom") { debouncer.flush }
  end

  it "raises when flush runs an action that fails" do
    debouncer = Debouncer.new(1.hour) { raise "now" }
    debouncer.call
    expect_raises(Exception, "now") { debouncer.flush }
    sleep 10.milliseconds
    debouncer.pending?.should be_false
  end

  it "keeps one run when a call replaces the deadline before the claim" do
    runs = Atomic(Int32).new(0)
    debouncer = IdleProbe.new(20.milliseconds) { runs.add(1) }
    debouncer.steal = true
    debouncer.call
    wait_until { runs.get == 1 }
    wait_until { !debouncer.pending? }
    sleep 30.milliseconds
    runs.get.should eq(1)
  end

  it "continues the same worker when a call arrives before the idle phase" do
    runs = Atomic(Int32).new(0)
    debouncer = IdleProbe.new(20.milliseconds) { runs.add(1) }
    debouncer.rearm = true
    debouncer.call
    wait_until { runs.get == 2 }
    wait_until { !debouncer.pending? }
  end

  it "exits the old worker when a new worker starts during idle" do
    runs = Atomic(Int32).new(0)
    debouncer = IdleProbe.new(20.milliseconds) { runs.add(1) }
    gate = Channel(Nil).new
    debouncer.gate = gate
    debouncer.call
    gate.receive
    debouncer.call
    gate.send(nil)
    wait_until { runs.get == 2 }
    wait_until { !debouncer.pending? }
  end

  it "accepts calls from many fibers" do
    runs = Atomic(Int32).new(0)
    debouncer = Debouncer.new(40.milliseconds) { runs.add(1) }
    WaitGroup.wait do |group|
      4.times do
        group.spawn do
          250.times { debouncer.call }
        end
      end
    end
    wait_until { runs.get == 1 }
    wait_until { !debouncer.pending? }
    runs.get.should eq(1)
  end

  it "accepts calls from parallel fibers" do
    workers = System.cpu_count.clamp(2, 8)
    Fiber::ExecutionContext.default.resize(workers)
    begin
      5.times do
        runs = Atomic(Int32).new(0)
        debouncer = Debouncer.new(50.milliseconds) { runs.add(1) }
        WaitGroup.wait do |group|
          workers.times do
            group.spawn do
              1_000.times { debouncer.call }
            end
          end
        end
        wait_until { runs.get == 1 }
        wait_until { !debouncer.pending? }
        runs.get.should eq(1)
      end
    ensure
      Fiber::ExecutionContext.default.resize(1)
    end
  end

  it "runs many debouncers" do
    runs = Atomic(Int32).new(0)
    debouncers = Array.new(16) { Debouncer.new(20.milliseconds) { runs.add(1) } }
    debouncers.each(&.call)
    wait_until { runs.get == 16 }
  end
end
