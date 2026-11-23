defmodule Web.Test.QuickJS do
  @moduledoc false

  # The JavaScript engine QuickJS, for the tests only: it runs the files of
  # web-platform-tests without change. See `Web.Test.QuickJS.Bridge`.
  #
  # The build of QuickJS with Cosmopolitan libc is one file that runs on
  # Linux, macOS, Windows, and the BSD systems, on x86_64 and ARM64. The
  # tests download a pinned release, examine its SHA-256 hash, and keep the
  # program in the cache of the tests.

  @version "2026-06-04"
  @url "https://bellard.org/quickjs/binary_releases/quickjs-cosmo-#{@version}.zip"
  @sha256 "3335cdf35e3601e3b803b53cfee4dad53ac53d7f817d951ea4eeced6e9b26927"
  @dir Path.expand("tmp/quickjs/#{@version}", File.cwd!())

  @doc "The path of the program `qjs`. The first call downloads it."
  @spec path!() :: Path.t()
  def path! do
    program = Path.join(@dir, "qjs")

    if File.exists?(program) do
      program
    else
      # Tests can start at the same time: one of them downloads.
      :global.trans({__MODULE__, :download}, fn -> download(program) end, [node()], :infinity)
    end
  end

  defp download(program) do
    if File.exists?(program) do
      program
    else
      archive = Web.await(Web.Response.bytes(Web.await(Web.fetch(@url))))
      archive = Web.Uint8Array.to_binary(archive)

      unless Base.encode16(:crypto.hash(:sha256, archive), case: :lower) == @sha256 do
        raise "The QuickJS archive #{@url} does not have the expected SHA-256 hash."
      end

      {:ok, [{_name, binary}]} = :zip.unzip(archive, [:memory, file_list: [~c"qjs"]])
      File.mkdir_p!(@dir)
      part = program <> ".part"
      File.write!(part, binary)
      File.chmod!(part, 0o755)

      # A shell can start the portable program, but Erlang cannot: the
      # program changes itself one time into a native program of this
      # machine.
      {_output, 0} = System.cmd("/bin/sh", [part, "--assimilate"], stderr_to_stdout: true)
      File.rename!(part, program)
      program
    end
  end
end
