# The tests with the tag `:cluster` start a second node. They do not run on a
# machine that cannot start Erlang distribution.
exclude =
  if Web.TestCluster.start_distribution() do
    []
  else
    IO.puts("Erlang distribution is not available: the tests with the tag :cluster do not run.")
    [:cluster]
  end

# A machine that is busy can be slow, thus a message has more time to
# arrive than the default 100 ms. A test that passes does not wait.
ExUnit.start(exclude: exclude, assert_receive_timeout: 1_000)
