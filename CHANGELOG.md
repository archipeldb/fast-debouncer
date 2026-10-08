# Changelog

## 0.2.0 - 2026-10-08

### Changed

* The action is set once, when you create the debouncer.
* A call stores a new deadline. A call does not allocate memory while a run is waiting.
* The worker sleeps until the deadline. It reads the deadline again after the sleep.
* Requires Crystal 1.21 or later.

### Added

* `call` moves the deadline forward.
* `cancel` drops a waiting action.
* `flush` runs a waiting action on the caller fiber.
* `pending?` reports a waiting run.
* `Debouncer.for` keeps the latest value and passes it to the action.
