// The banner is not part of the library's interface: no example task in the
// suite prints it, and nothing here pins the shape of an alphabet. What is
// checked is the switch — off until asked for, which is the only promise the
// rest of the package makes to a program that links it.

///|
/// The state is global, so every test begins from a known one.
fn reset() -> Unit {
  @logo.disable()
}

///|
test "off until a program asks for it" {
  reset()
  assert_false(@logo.is_enabled())
  assert_eq(@logo.banner(), "")
  assert_eq(@logo.style(), "")
}

///|
test "enable without a name selects fast" {
  reset()
  @logo.enable()
  assert_true(@logo.is_enabled())
  assert_eq(@logo.style(), "fast")
  assert_true(@logo.banner().length() > 0)
}

///|
test "enable names another built-in alphabet" {
  reset()
  @logo.enable()
  let fast = @logo.banner()
  @logo.enable(name="shadow")
  assert_eq(@logo.style(), "shadow")
  assert_true(@logo.banner() != fast)
}

///|
test "a name that is neither built in nor added falls back to fast" {
  reset()
  @logo.enable(name="no-such-art")
  assert_eq(@logo.style(), "fast")
}

///|
test "art added by a program can be selected by its name" {
  reset()
  @logo.register("two-lines", "moon\ncat")
  @logo.enable(name="two-lines")
  assert_eq(@logo.banner(), "moon\ncat")
  assert_eq(@logo.style(), "custom")
  assert_true(@logo.names().contains("two-lines"))
}

///|
test "disable leaves nothing to print" {
  reset()
  @logo.enable()
  @logo.disable()
  assert_false(@logo.is_enabled())
  assert_eq(@logo.banner(), "")
}

///|
test "the built-in names begin with fast" {
  assert_eq(@logo.names()[0], "fast")
  assert_true(@logo.names().contains("simple"))
}
