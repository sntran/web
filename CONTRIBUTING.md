# Contributing

This file gives the rules for each change to this library. The rules come
from problems that the project found. Each rule tells what to do, and why.

## Writing

Write all text in ASD-STE100 Simplified Technical English: the documents,
the comments in the code, the names, the log text, and the commit messages.

- Use short sentences, and one instruction in each sentence.
- Use the active voice, and the words of the STE dictionary where possible.
- Use the technical names of the Standards and of Erlang/OTP with no
  change, for example `ReadableStream`, `AbortSignal`, or `gen_tcp`.

## Web Standards compliance

The public API of this library is the API of the Web Standards (WHATWG, W3C,
and TC39). Its users must find what a Standard specifies, and nothing that
the Standard does not specify.

- Do not add a public function, callback, option, or field that a Standard
  does not have. An option of a public function is also a public API.
- Keep the calling signature of each public function.
- Put each internal need in a private function, in a function with a name
  that starts and ends with two underscores and `@doc false` (for example
  `__start__/3`), or in a module with `@moduledoc false`, for example the
  modules in `Web.Internal`.
- Follow the behavior of the Standard also where it is not the easy
  behavior. For example, `Response.text/1` decodes UTF-8 and replaces each
  byte that is not valid, and an HTTP/2 response has the status text `""`.
- A behavior that a Standard does not specify, for example a time limit or
  a pool of connections, is a setting of the application, not a public
  option.
- Before you push, compare the public API with the API before your change.
  This script prints each public function, callback, and type:

  ```elixir
  for module <- Enum.sort(Application.spec(:web, :modules)),
      {:docs_v1, _, _, _, doc, _, entries} <- [Code.fetch_docs(module)],
      doc != :hidden,
      {{kind, name, arity}, _, _, entry_doc, _} <- entries,
      entry_doc != :hidden,
      not String.starts_with?(to_string(name), "__") do
    IO.puts("#{inspect(module)} #{kind} #{name}/#{arity}")
  end
  ```

  Sort the two outputs before you compare them: the sequence of the entries
  is different on different versions of Elixir.

## Dependencies

- Do not add a runtime dependency for a feature that the library can have
  on Erlang/OTP or on a small protocol library. For example, the HTTP client
  of `Web.fetch/2` is in the library, on the connection functions of Mint.
- A library that only a benchmark or a test uses is a dependency of the
  environment `:dev` or `:test` only.

## Processes

- A process that owns a resource, for example a socket, must always answer
  its messages: an abort, a reader, and a time limit. It must not wait in a
  blocking call.
- A process asks its socket for one message at a time (`active: :once`),
  and asks for the next message only after it handled the message before.
  Do not let a library ask the socket for a message for you: two requests
  for a message can put two messages in the mailbox, and the mailbox then
  grows with no limit.
- Set a flag before the step that it tells about. For example, a process
  sets its flag "asked" before it asks the socket for a message: the
  message can come before the next line of the code. Thus the flag tells
  the truth at each time, also for a test that suspends the process.
- Each buffer has a limit: 64 KiB of data that no reader took, and one
  message or one decoded piece more. A decoder makes its next piece only
  when the reader has space for it. Thus a small compressed input that
  expands much does not fill the memory.
- A zlib handle belongs to the process that opens it. Open it in the
  process that uses it, for example the worker of a stream, and close it on
  each path to the end: the end of the data, a cancel, and an abort.
- Release each resource on each path to the end of a process: a return of
  a connection to its pool, a close, a stop of a helper process.
- Do a step again only when it cannot run two times. For example, a
  request goes again on a new connection only when the server did not
  process it, and never with a body from a stream.

## TLA+ specifications

Each design where processes work together has a TLA+ specification in
`tla/`, for example the lifetime of a stream, a promise, the pool of the
connections of an origin, and the reads of a socket.

- Write the specification before or with the code.
- Give the specification the constant `Bug`. The value `"none"` is the
  design. Each other value removes one rule of the design. In
  `test/tla/model_check_test.exs`, a test for each value makes sure that a
  property finds it. Thus a property that cannot fail is found.
- Add a conformance test in `test/tla/`: it does random operations on the
  real code and on the specification at the same time, and compares the
  two states after each step. Use `Web.Test.SpecModel`.
- Where a test cannot control each step of the real system, for example
  the frames of an HTTP/2 server, add a property test that checks the
  properties of the specification on the real code.
- Before you keep a new conformance or property test, put a known fault in
  the code for a moment, and make sure that the test fails. Then remove the
  fault.

## Web Platform Tests

- Run the files of WPT with no change where possible: see "Web Platform
  Tests in QuickJS" in `README.md`.
- Put no logic of a Standard in the WebIDL layer of the runner. The layer
  converts values as WebIDL specifies, and calls the library. Thus a test
  examines the library, not the layer.
- A test that fails because the runner has no feature is a `runner:` group.
  A test that fails because the library differs is a `library:` group. A
  test of the pinned WPT commit that the current Standard changed is a
  `standard:` group: name the step of the Standard in the rule. A test of an
  API that the library will not have, such as `XMLHttpRequest`, is a
  `scope:` group.
- The result of each test must be the same in each run. The bridge answers
  a call, and sends the settled promises, only when the processes of the
  run are at rest. A new kind of message to the bridge must keep this rule.
- A stream or a promise of the library stops when the linger time goes by
  after its end, and a page of JavaScript keeps each object. A suite with
  files that make their objects when the script loads, and use them in a
  later test, sets the linger time to the time limit of the run, with
  `async: false`. See `test/wpt/quickjs/fetch_test.exs`.
- When a change of the library corrects a difference, run
  `WPT_UPDATE=1 mix test test/wpt/quickjs`, and examine the change of the
  lists before you commit it.

## Tests

- Use property tests (`ExUnitProperties`) for each rule that applies to
  many inputs, for example each split of a compressed body.
- A test must not depend on time. Do not use a sleep to wait for a step of
  a different process. Use a monitor, `:sys.get_state/1`,
  `:erlang.suspend_process/1`, `:erlang.trace_delivered/1`, or a helper
  that examines a condition until it is true.
- To put two messages in a known sequence, suspend the process that gets
  them, send the messages, and resume the process.
- To close a socket from the side of the client, with no message to its
  owner, use `:erlang.port_close/1`.
- To make a connect wait, connect to a listener with `backlog: 0` that has
  one connection in its queue: the kernel drops the next connect.
- To examine the state of a process, its mailbox, and its socket as one
  snapshot, suspend the process first.
- A test server must read the request until the client closes the
  connection. A socket that closes with bytes that it did not read sends a
  reset, and the reset can drop the end of the response.
- A process that a test starts with a name must have a new name in each
  run: the operating system can give the same port to a later run.
- A test that measures the memory of the VM must not run at the same time
  as other tests: use `async: false`.
- The coverage is 100 %. Mark a line with `coveralls-ignore` only for a
  branch that a test cannot reach at a known time, for example a race of
  two processes, and write a comment that tells why.

## The gate

Run the full gate on the two versions that the library supports: Elixir 1.20
with Erlang/OTP 29, and Elixir 1.19 with Erlang/OTP 28.

```shell
mix format --check-formatted
MIX_ENV=test mix compile --warnings-as-errors
mix credo --strict
mix test --warnings-as-errors
MIX_ENV=test mix coveralls
```

Run the coverage more than one time. A test that fails only when the
machine is busy has a race: find the race, and do not make a time limit
larger without a reason.

## Benchmarks

- Measure before you write that a change is faster.
- Run the clients in turns in the same benchmark, and compare the medians
  of many rounds: the numbers of one machine change much between runs. See
  `bench/http_clients.exs`.
- Write the ranges of the numbers in `BENCHMARKS.md`, and the reason of
  each result that you can explain.

## Commits and documents

- Write each commit message as `type(scope): text`, for example
  `fix(stream): ...`, `perf(fetch): ...`, `test(fetch): ...`, or `docs: ...`.
- Record each change that a user can see in `CHANGELOG.md`.
- Update `README.md` when a setting or a behavior changes.
