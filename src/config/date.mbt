// The `Date` response header (RFC 7231 §7.1.1.1). uvicorn stamps one on every response and
// refreshes it once a second rather than per request, because formatting a date is dearer than
// comparing two integers and a response is only ever dated to the second anyway.

///|
/// Floor division, so a pre-epoch instant lands on the day that contains it rather than the one
/// after. Truncating division would round negatives towards zero.
fn floor_div(a : Int64, b : Int64) -> Int64 {
  if a >= 0L {
    a / b
  } else {
    (a - b + 1L) / b
  }
}

///|
/// Format a Unix-epoch millisecond count as an HTTP-date in the IMF-fixdate form RFC 7231 §7.1.1.1
/// makes mandatory for a `Date` header: `Sun, 06 Nov 1994 08:49:37 GMT`, always GMT, always
/// fixed-width.
///
/// The calendar and the format are moondate's; what is here is the millisecond clock
/// mooncat reads, brought down to the whole second the header is written to.
pub fn http_date(ms : Int64) -> String {
  @moondate.Moment::of_epoch(floor_div(ms, 1000L)).http_text() catch {
    // Only a bare time has no HTTP date, and an epoch instant is never one.
    _ => abort("an epoch instant always has an HTTP date")
  }
}

///|
/// The formatted date and the epoch second it was formatted for, so a second's worth of responses
/// share one formatting pass (← uvicorn, which refreshes its `Date` on a one-second tick).
let date_cache : Ref[(Int64, String)] = Ref((-1L, ""))

///|
/// The current instant as an HTTP-date, reformatted only when the epoch second has moved on.
pub fn http_date_now() -> String {
  let ms = @async.now()
  let sec = floor_div(ms, 1000L)
  let (at, text) = date_cache.val
  if at == sec {
    return text
  }
  let fresh = http_date(ms)
  date_cache.val = (sec, fresh)
  fresh
}

///|
/// The IMF-fixdate examples RFC 7231 §7.1.1.1 itself gives, plus the epoch, a leap day, and a
/// pre-epoch instant that only floor division dates correctly.
test "http_date renders the RFC 7231 §7.1.1.1 fixdate form" {
  // The spec's own example: Sun, 06 Nov 1994 08:49:37 GMT.
  assert_eq(http_date(784111777000L), "Sun, 06 Nov 1994 08:49:37 GMT")
  // The epoch itself was a Thursday.
  assert_eq(http_date(0L), "Thu, 01 Jan 1970 00:00:00 GMT")
  // A leap day, which the 400-year era arithmetic has to place.
  assert_eq(http_date(951782400000L), "Tue, 29 Feb 2000 00:00:00 GMT")
  // Sub-second remainders are dropped, not rounded.
  assert_eq(http_date(999L), "Thu, 01 Jan 1970 00:00:00 GMT")
  // One millisecond before the epoch belongs to the previous day, not the epoch day.
  assert_eq(http_date(-1L), "Wed, 31 Dec 1969 23:59:59 GMT")
}

///|
/// Every field is fixed-width, so a parser can index into the string: `Sun, 06 Nov 1994 08:49:37
/// GMT` is 29 characters and nothing shorter is legal.
test "http_date pads every field to the fixed width" {
  let d = http_date(1L)
  assert_eq(d.length(), 29)
  assert_eq(d, "Thu, 01 Jan 1970 00:00:00 GMT")
  // A single-digit hour, minute and second all keep their leading zero.
  assert_eq(http_date(3723000L), "Thu, 01 Jan 1970 01:02:03 GMT")
}

///|
/// The cache hands back the same second's rendering and it is a well-formed date, whatever the
/// clock happens to say when the suite runs.
test "http_date_now caches within the second and stays well-formed" {
  let a = http_date_now()
  let b = http_date_now()
  assert_eq(a, b)
  assert_eq(a.length(), 29)
  assert_eq(a[25:].to_owned(), " GMT")
}
