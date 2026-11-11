///|
/// A replayable request is not taken by accident: HTTP/3 on its own offers no early data, and
/// only an explicit policy puts an allowance in a ticket.
test "early data is off unless it is switched on" {
  assert_eq(@config.Config::new().early_data, @config.EarlyData::Off)
  assert_eq(@config.Config::new().early_data_size, @config.early_data_size)
  assert_eq(@config.early_data_size, 16384)
}

///|
test "every early data policy can be named" {
  assert_eq(
    @config.Config::new(early_data=@config.EarlyData::Accept).early_data,
    @config.EarlyData::Accept,
  )
  assert_eq(
    @config.Config::new(early_data=@config.EarlyData::Refuse).early_data,
    @config.EarlyData::Refuse,
  )
  assert_eq(
    @config.Config::new(early_data=@config.EarlyData::Off).early_data,
    @config.EarlyData::Off,
  )
}

///|
test "the allowance and the policy are independent" {
  let config = @config.Config::new(
    early_data=@config.EarlyData::Accept,
    early_data_size=4096,
  )
  assert_eq(config.early_data, @config.EarlyData::Accept)
  assert_eq(config.early_data_size, 4096)
  let config = @config.Config::new(early_data_size=4096)
  assert_eq(config.early_data, @config.EarlyData::Off)
  assert_eq(config.early_data_size, 4096)
}

///|
test "the other defaults are unchanged by the early data default" {
  let config = @config.Config::new()
  assert_eq(config.port, @config.port)
  assert_eq(config.host, "127.0.0.1")
  assert_eq(config.cleartext, true)
  assert_eq(config.workers, 1)
  assert_eq(config.lifespan, @config.Lifespan::Auto)
}
