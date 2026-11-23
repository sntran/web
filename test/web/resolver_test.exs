defmodule Web.ResolverTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Web.Resolver
  alias Web.URL

  property "resolves the HTTP schemes to the HTTP dispatcher" do
    check all(path <- string(:alphanumeric)) do
      assert Resolver.resolve(URL.new("http://example.com/#{path}")) == Web.Dispatcher.HTTP
      assert Resolver.resolve(URL.new("https://example.com/#{path}")) == Web.Dispatcher.HTTP
    end
  end

  property "resolves the scheme tcp to the TCP dispatcher" do
    check all(path <- string(:alphanumeric)) do
      assert Resolver.resolve(URL.new("tcp://localhost/#{path}")) == Web.Dispatcher.TCP
    end
  end

  property "resolves a blob URL to the dispatcher of blob URLs" do
    check all(path <- string(:alphanumeric)) do
      assert Resolver.resolve(URL.new("blob:null/#{path}")) == Web.Dispatcher.Blob
      assert Resolver.resolve(URL.new("BLOB:#{path}")) == Web.Dispatcher.Blob
    end
  end

  test "resolves an rclone URL to TCP, and each other scheme to the steps scheme fetch" do
    assert Resolver.resolve(URL.new("my_s3:path/to/file")) == Web.Dispatcher.TCP

    for url <- ["foo://example.com", "about:blank", "data:,x", "file:///etc/hosts", "ws://a/"] do
      assert Resolver.resolve(URL.new(url)) == Web.Dispatcher.Scheme
    end
  end
end
