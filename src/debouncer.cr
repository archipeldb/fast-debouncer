require "./debouncer/engine"
require "sync/mutex"

# Runs one action after calls stop for the given delay.
#
# Create the debouncer with the action. Then call it for each event.
# A burst of calls runs the action once.
# The action runs on a worker fiber.
# `flush` runs a waiting action on the caller fiber.
class Debouncer
  include Engine

  VERSION = "0.2.0"

  # The delay must be greater than zero.
  def initialize(delay : Time::Span, &@action : -> Nil)
    @delay_ns = Delay.nanoseconds(delay)
  end

  # Move the deadline forward. The call returns before the action runs.
  def call : Nil
    schedule
  end

  # Build a debouncer that keeps the latest value and passes it to the action.
  # *type* selects the value type. For example, `Debouncer.for(String, 50.milliseconds)`.
  def self.for(type : T.class, delay : Time::Span, &action : T -> Nil) : Latest(T) forall T
    Latest(T).new(delay, &action)
  end

  private def deliver : Nil
    @action.call
  end

  # Keeps the latest value and passes that value to the action.
  class Latest(T)
    include Engine

    # Holds one value. The object is created on the first call and then reused.
    private class Box(U)
      property value : U

      def initialize(@value : U)
      end
    end

    @slot : Box(T)? = nil

    # The delay must be greater than zero.
    def initialize(delay : Time::Span, &@action : T -> Nil)
      @delay_ns = Delay.nanoseconds(delay)
      # The lock does not cross a yield. The unchecked type skips owner checks.
      @lock = Sync::Mutex.new(:unchecked)
    end

    # Store the latest value and move the deadline forward.
    def call(value : T) : Nil
      store(value)
      schedule
    end

    private def deliver : Nil
      slot = @lock.synchronize { @slot }
      return unless slot

      value = @lock.synchronize { slot.value }
      @action.call(value)
    end

    # Replace the stored value. The first call creates the box. Later calls reuse it.
    private def store(value : T) : Nil
      @lock.synchronize do
        if slot = @slot
          slot.value = value
        else
          @slot = Box(T).new(value)
        end
      end
    end
  end
end
