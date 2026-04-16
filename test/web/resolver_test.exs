defmodule Web.ResolverTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Web.Resolver
  alias Web.URL

  property "resolves HTTP specific scheme prefixes naturally" do
    check all(path <- string(:alphanumeric)) do
      assert Resolver.resolve("http://#{path}") == Web.Dispatcher.HTTP
      assert Resolver.resolve("https://#{path}") == Web.Dispatcher.HTTP
    end
  end

  property "resolves TCP specific schemes precisely" do
    check all(path <- string(:alphanumeric)) do
      assert Resolver.resolve("tcp://#{path}") == Web.Dispatcher.TCP
    end
  end

  property "resolves remote syntax colon based variants to TCP default fallback" do
    check all(remote <- string(:alphanumeric, min_length: 1), path <- string(:alphanumeric)) do
      assert Resolver.resolve("#{remote}:#{path}") == Web.Dispatcher.TCP
    end
  end

  test "resolves default or fallback to HTTP cleanly" do
    assert Resolver.resolve("unknown_uri_scheme_no_colon") == Web.Dispatcher.HTTP
  end

  test "resolves URL structs for rclone and unknown protocols" do
    assert Resolver.resolve(URL.new("my_s3:path/to/file")) == Web.Dispatcher.TCP
    assert Resolver.resolve(URL.new("foo://example.com")) == Web.Dispatcher.HTTP
  end
end
