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
pub fn worker() -> Int32? {
  None
}

///|
pub async fn supervise(
  _config : @config.Config,
  env? : Map[String, String],
) -> Unit {
  ignore(env)
  @async.pause()
  fail("workers above 1 need native processes")
}
