# The tests with the tag `:cluster` start a second node. They do not run on a
# machine that cannot start Erlang distribution.
exclude =
  if Web.TestCluster.start_distribution() do
    []
  else
    IO.puts("Erlang distribution is not available: the tests with the tag :cluster do not run.")
    [:cluster]
  end

ExUnit.start(exclude: exclude)
