module Debouncer
  VERSION = "0.1.0"

  class Debouncer
    @trigger_channel : Channel(Nil)?
    @current_action : Proc(Nil)?
    @current_delay : Time::Span
    @running : Atomic(Bool)
    @mutex : Mutex

    def initialize(@current_delay : Time::Span = 0.seconds)
      @running = Atomic(Bool).new(false)
      @mutex = Mutex.new
    end

    private def start
      return if @running.get

      @running.set(true)
      @trigger_channel = Channel(Nil).new(1) # Buffered for signal tolerance

      spawn do
        loop do
          select
          when @trigger_channel.not_nil!.receive
            # Reset timer via continued loop—no-op, just extend
          when timeout(@current_delay)
            @mutex.synchronize do
              if action = @current_action
                begin
                  action.call
                rescue ex
                  # Empty rescue just to prevent crash, without logging
                ensure
                  @current_action = nil
                end
              end
            end
            stop
            break
          end
        end
      rescue Channel::ClosedError
        # Graceful exit
      end
    end

    def debounce(delay : Time::Span, &action : -> Nil)
      @mutex.synchronize do
        unless @running.get
          start
        else
          return if delay <= 0.seconds # Early out for zero-delay
        end

        @current_delay = delay
        @current_action = action
      end

      @trigger_channel.try &.send(nil)
    end

    def stop
      return unless @running.compare_and_set(true, false)

      if channel = @trigger_channel
        channel.close
      end
    end

    def reset # New: Abort pending, prep for reuse
      stop
      @current_action = nil
      @current_delay = 0.seconds
    end
  end
end
