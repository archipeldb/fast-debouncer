require "spec"
require "wait_group"
require "../src/debouncer"

# Wait until the block returns true, or raise when the time limit is reached.
def wait_until(timeout = 2.seconds, &)
  limit = Time.instant + timeout
  until yield
    raise "The wait timed out." if Time.instant >= limit
    sleep 1.millisecond
  end
end
