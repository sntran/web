defmodule WebTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  doctest Web
  doctest Web.Headers
  doctest Web.Request
  doctest Web.Response
  doctest Web.Resolver

  defmodule MockDispatcher do
    @behaviour Web.Dispatcher
    def fetch(%Web.Request{url: "mock://success"} = req) do
      {:ok, Web.Response.new(status: 200, url: req.url)}
    end
    def fetch(%Web.Request{url: "mock://error"}) do
      {:error, :simulated_error}
    end
  end

  test "Web.fetch routes to provided dispatcher directly via options" do
    assert {:ok, %Web.Response{ok: true, url: "mock://success"}} = 
      Web.fetch("mock://success", dispatcher: MockDispatcher)

    assert {:error, :simulated_error} = 
      Web.fetch("mock://error", dispatcher: MockDispatcher)
  end

  test "Web.fetch routes to resolved dispatcher when missing from options" do
    # Resolver.resolve("tcp://localhost:9999") -> Web.Dispatcher.TCP
    # Attempting a real TCP fetch will result in :econnrefused or :nxdomain
    assert {:error, _} = Web.fetch("tcp://localhost:59999")
  end
end
