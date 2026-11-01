// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// A wasm host has neither `exit` nor a way to run this program again, so there are no workers.

///|
fn is_worker() -> Bool {
  false
}

///|
fn leave_failed(_config : @config.Config, _e : Error) -> Unit {

}

///|
fn supervise(_config : @config.Config) -> Unit raise {
  fail("workers above 1 need native processes")
}
