defmodule FetchPoolExample do
  use Web

  def run do
    governor = CountingGovernor.new(2)

    requests =
      for path <- ["/delay/1", "/delay/2", "/delay/3", "/delay/4"] do
        Governor.with(governor, fn ->
          fetch("https://httpbin.org#{path}")
        end)
      end

    requests
    |> Promise.all()
    |> await()
    |> Enum.map(& &1.status)
  end
end

IO.inspect(FetchPoolExample.run(), label: "Statuses")
