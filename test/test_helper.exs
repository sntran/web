# The tests with the tag `:cluster` start a second node. They do not run on a
# machine that cannot start Erlang distribution.
exclude =
  if Web.TestCluster.start_distribution() do
    []
  else
    IO.puts("Erlang distribution is not available: the tests with the tag :cluster do not run.")
    [:cluster]
  end

# The tests in `test/wpt/` are ports of web-platform-tests. A test with the
# tag `:wpt_failure` shows a known difference of this library from the
# Standard: a comment above it tells the difference. These tests do not run
# in the gate. Run them with `mix test --only wpt_failure`. Remove the tag
# when the library follows the Standard.
exclude = [:wpt_failure | exclude]

# In `mix test`, the VM loads a module through the code server at its first
# use. Many tests start at the same time, thus a first use can wait for a
# long time, for example the first raise of an exception. The tests then
# fail because of the time limit of a message, not because of a fault. Load
# the modules of the library and of Elixir before the tests start, as a
# release does.
# A module that cannot load, for example one for a different version of
# Erlang/OTP, does not stop the tests.
for app <- [:web, :elixir, :logger, :ex_unit] do
  _result = :code.ensure_modules_loaded(Application.spec(app, :modules))
end

# A machine that is busy can be slow, thus a message has more time to
# arrive than the default 100 ms. A test that passes does not wait.
ExUnit.start(exclude: exclude, assert_receive_timeout: 1_000)
