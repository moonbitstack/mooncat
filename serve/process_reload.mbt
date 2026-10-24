// The `--reload` file watcher (← uvicorn's `--reload`), kept in a native-only file: it is backed by
// `@fs.Watcher`, which the async `fs` library provides only on native (inotify / kqueue / Windows) —
// there is no wasm or js file-watch backend. The rest of the process model (the graceful acceptor,
// `ShutdownHandle`) rides `@socket`, which compiles on every target, so it stays target-neutral.

///|
/// Watch `path` for source changes and fire `on_reload` on each batch of events
/// (← uvicorn's `--reload` file watcher). Backed by `@fs.Watcher`, which
/// debounces and reports child-file events, so a save to any file under `path`
/// triggers one reload. `on_reload` is where a supervisor re-execs the server;
/// wiring it to a `ShutdownHandle` turns a file save into a graceful restart.
/// Loops until its task is cancelled, always closing the watcher.
pub async fn reload_watch(path : String, on_reload : async () -> Unit) -> Unit {
  let watcher = @fs.Watcher::Watcher(path, report_child_event=true)
  defer watcher.close()
  for ;; {
    let events = watcher.wait()
    if events.length() > 0 {
      on_reload()
    }
  }
}

///|
/// The reload watcher fires on a genuine file change: write a file, start the
/// watcher over its directory, modify the file, and observe the callback run.
async test "reload watcher fires on a real file change" {
  @async.with_task_group(g => {
    let dir = @fs.tmpdir(prefix="mooncat-reload")
    let file = "\{dir}/app.mbt"
    @fs.write_file(file, b"one", create_mode=CreateOrTruncate)
    let hits = Ref(0)
    let task = g.spawn(() => reload_watch(dir, () => hits.val = hits.val + 1))
    @async.sleep(200)
    @fs.write_file(file, b"two", create_mode=CreateOrTruncate)
    @async.sleep(500)
    task.cancel()
    assert_eq(hits.val >= 1, true)
    @fs.rmdir(dir, recursive=true)
  })
}
