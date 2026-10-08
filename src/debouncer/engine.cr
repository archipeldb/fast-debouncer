# Declare the class before the nested modules in this file.
class Debouncer
end

# The timer state for one debouncer.
#
# A call stores a new deadline. The deadline is an absolute monotonic time in
# nanoseconds. Zero means that no run is waiting.
# The call does not allocate memory when a worker is already active.
# The worker sleeps until the deadline. The worker then reads the deadline again.
# A later call can move the deadline forward during that sleep.
#
# The caller and the worker use two atomic values.
# The caller stores the deadline, then reads the phase.
# The worker stores the idle phase, then reads the deadline.
# One side then sees the write from the other side.
# This order is required because fibers can move between threads.
#
# :nodoc:
module Debouncer::Engine
  # No worker is active. The process can exit.
  PHASE_IDLE = 0_u32

  # A worker is active. The worker will observe a new deadline.
  PHASE_ACTIVE = 1_u32

  # The channel is created once. A later window reuses it.
  # Phase starts idle. `initialize` replaces `@delay_ns` before the object is used.
  macro included
    @delay_ns : UInt64 = 0_u64
    @deadline = Atomic(UInt64).new(0_u64)
    @phase = Atomic(UInt32).new(0_u32)
    @error = Atomic(Exception?).new(nil)
    @wake = Channel(Nil).new(1)
  end

  # Store the deadline. Start a worker only when none is active.
  @[AlwaysInline]
  private def arm : Bool
    now = Crystal::System::Time.ticks
    @deadline.set(now &+ @delay_ns, :sequentially_consistent)
    return false unless @phase.get(:sequentially_consistent) == PHASE_IDLE

    _, won = @phase.compare_and_set(
      PHASE_IDLE,
      PHASE_ACTIVE,
      :sequentially_consistent,
      :sequentially_consistent,
    )
    won
  end

  # Run the action after the quiet period. Then stop the worker if no call is waiting.
  private def run_timer(& : -> Nil) : Nil
    drain_wake

    loop do
      now = Crystal::System::Time.ticks
      target = @deadline.get(:acquire)

      if target > now
        sleep_for(target &- now)
        next
      end

      if target != 0_u64
        before_claim(target)
        _, won = @deadline.compare_and_set(target, 0_u64, :acquire_release, :acquire)
        if won
          begin
            yield
          rescue error : Exception
            remember(error)
          end
        end
      end

      # A call during the action stored a new deadline. Wait for that deadline.
      next if @deadline.get(:acquire) != 0_u64

      before_idle
      @phase.set(PHASE_IDLE, :sequentially_consistent)
      after_idle

      # A call stored a deadline after the worker decided to stop.
      # Continue when this worker wins the phase. Exit when the caller started another worker.
      if @deadline.get(:sequentially_consistent) != 0_u64
        _, won = @phase.compare_and_set(
          PHASE_IDLE,
          PHASE_ACTIVE,
          :sequentially_consistent,
          :sequentially_consistent,
        )
        next if won
      end
      return
    end
  end

  # Start the worker fiber. The fiber stops when the debouncer is idle.
  private def spawn_worker : Nil
    spawn name: "debouncer" do
      run_timer { deliver }
    end
  end

  # Arm the timer. Then raise an error from an earlier action, when one is stored.
  @[AlwaysInline]
  private def schedule : Nil
    spawn_worker if arm
    raise_stored_error
  end

  # Drop a waiting run. Wake the worker so the process can exit.
  def cancel : Nil
    @deadline.set(0_u64, :sequentially_consistent)
    poke
  end

  # Run a waiting action now, on the caller fiber.
  # Wake the worker so it does not run the same action later.
  def flush : Nil
    target = @deadline.swap(0_u64, :sequentially_consistent)
    poke
    deliver if target != 0_u64
    raise_stored_error
  end

  # Return true when a run is waiting.
  def pending? : Bool
    @deadline.get(:acquire) != 0_u64
  end

  # A subclass can change the deadline before the worker claims it.
  # :nodoc:
  protected def before_claim(target : UInt64) : Nil
    return if target == 0_u64
  end

  # A subclass can schedule another call before the worker goes idle.
  # :nodoc:
  protected def before_idle : Nil
  end

  # A subclass can observe the idle phase before the worker reads the deadline again.
  # :nodoc:
  protected def after_idle : Nil
  end

  # Sleep until the deadline, or until cancel or flush wakes the worker.
  private def sleep_for(nanoseconds : UInt64) : Nil
    span = Time::Span.new(nanoseconds: nanoseconds.to_i64)
    select
    when @wake.receive
    when timeout(span)
    end
  end

  # Remove a wake token left by an earlier cancel or flush.
  private def drain_wake : Nil
    loop do
      select
      when @wake.receive
      else
        break
      end
    end
  end

  # Wake a sleeping worker. Do not wait when a token is already stored.
  private def poke : Nil
    select
    when @wake.send(nil)
    else
    end
  end

  # Keep the latest action error. A later call or flush raises it.
  private def remember(error : Exception) : Nil
    @error.set(error, :release)
  end

  # Raise the stored action error once. Do nothing when no error is stored.
  private def raise_stored_error : Nil
    if error = @error.swap(nil, :acquire_release)
      raise error
    end
  end
end

# Convert a delay to nanoseconds on the monotonic clock.
# :nodoc:
module Debouncer::Delay
  NS_PER_SECOND = 1_000_000_000_u64
  MAX_SECONDS   = Int64::MAX // Time::NANOSECONDS_PER_SECOND

  def self.nanoseconds(delay : Time::Span) : UInt64
    unless delay.positive?
      raise ArgumentError.new("The delay must be greater than zero.")
    end

    seconds = delay.to_i
    if seconds > MAX_SECONDS
      raise ArgumentError.new("The delay is too long.")
    end

    seconds.to_u64 &* NS_PER_SECOND &+ delay.nanoseconds.to_u64
  end
end
