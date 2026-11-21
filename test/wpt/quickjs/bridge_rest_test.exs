defmodule Web.WPT.QuickJS.BridgeRestTest do
  # The rest check of the bridge cannot see a process that waits for the
  # code server: see `Web.Test.QuickJS.Bridge.__load_code__/0`.
  use ExUnit.Case, async: true

  alias Web.Test.QuickJS.Bridge

  test "a run loads the code of the library and of its applications first" do
    modules =
      for app <- [:web | Application.spec(:web, :applications)],
          module <- Application.spec(app, :modules) || [],
          do: module

    assert :ok = Bridge.__load_code__()
    assert Enum.reject(modules, &:code.is_loaded/1) == []
  end
end
