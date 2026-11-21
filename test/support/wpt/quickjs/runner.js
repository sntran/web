// The runner of one file of web-platform-tests in QuickJS.
//
// The runner talks with `Web.Test.QuickJS.Bridge` in lines of JSON on its
// standard input and output. The lines have only ASCII characters: the
// other characters are in the escapes of JSON. The first line from the
// bridge gives the files to load. The runner then loads `testharness.js` in
// its shell mode, the WebIDL layer, the helper scripts of the test, and the
// test file. It sends one line for each result, and one line at the end.
//
// A line from the bridge can come at each time:
//
//   * the answer to a request of the runner;
//   * `invoke`: the library calls a JavaScript function, for example the
//     `pull` of a source;
//   * `settle`: a promise of the library is settled.
//
// While the runner waits for an answer, it does the other lines at once.
// While it waits for nothing, a handler of the standard input does them.
import * as std from "std";
import * as os from "os";

function send(message) {
  const text = JSON.stringify(message, (_key, value) =>
    typeof value === "string" ? value.toWellFormed() : value);
  std.out.puts(text.replace(/[\u007f-￿]/g,
    (c) => "\\u" + c.charCodeAt(0).toString(16).padStart(4, "0")) + "\n");
  std.out.flush();
}

// ---------------------------------------------------------------------------
// The lines from the bridge
// ---------------------------------------------------------------------------

const buffer = new Uint8Array(65536);
let pending = "";

// The bridge closes the standard input at the end of the run: the runner
// then stops. An exception would not stop it, as the handler of the input
// would run again.
function readMore() {
  const count = os.read(0, buffer.buffer, 0, buffer.length);
  if (count <= 0) std.exit(0);
  // A call has at most 65535 arguments in QuickJS.
  for (let start = 0; start < count; start += 8192) {
    pending += String.fromCharCode.apply(null, buffer.subarray(start, Math.min(count, start + 8192)));
  }
}

function nextLine() {
  let end = pending.indexOf("\n");
  while (end < 0) {
    readMore();
    end = pending.indexOf("\n");
  }
  const line = pending.slice(0, end);
  pending = pending.slice(end + 1);
  return JSON.parse(line);
}

// The lines that came with an answer, and the lines of the standard input
// while the runner waits for nothing.
function dispatchPending() {
  while (pending.indexOf("\n") >= 0) dispatch(nextLine());
}

os.setReadHandler(0, () => {
  readMore();
  dispatchPending();
});

let dispatcher = null;

// The number of lines from the bridge and of timers that fired: see
// `watchdog`.
let activity = 0;

function dispatch(message) {
  if (dispatcher === null) throw new Error("A line came before the layer: " + JSON.stringify(message));
  activity++;
  dispatcher(message);
}

let nextId = 1;

// A request to the bridge. The other lines that come before the answer are
// done at once: the library can call a JavaScript function while it does
// the request.
//
// A request can start while the runner does a line of the bridge, for
// example in a getter that a test puts on `Object.prototype`. The answer of
// an earlier request can then come first: the runner keeps it until its
// request asks for it.
const earlyAnswers = new Map();

function request(message) {
  const id = nextId++;
  send(Object.assign({ id }, message));
  for (;;) {
    if (earlyAnswers.has(id)) {
      const answer = earlyAnswers.get(id);
      earlyAnswers.delete(id);
      return answer;
    }
    const reply = nextLine();
    if (reply.id !== undefined && reply.id !== id) {
      earlyAnswers.set(reply.id, reply);
      continue;
    }
    if (reply.id === id) {
      // The lines after the answer go in a new task.
      if (pending.indexOf("\n") >= 0) os.setTimeout(dispatchPending, 0);
      return reply;
    }
    dispatch(reply);
  }
}

const start = nextLine();

// ---------------------------------------------------------------------------
// The host
// ---------------------------------------------------------------------------

globalThis.self = globalThis;
globalThis.queueMicrotask = (callback) => { Promise.resolve().then(callback); };

// A timer of a test fires after the library is idle. A test of WPT uses a
// timer to wait until the work of the platform is complete, for example
// with `flushAsyncEvents()`. The library does its work in other processes:
// the runner asks the bridge to wait until they are idle, and lets the
// promises that settle in that time react first.
let nextTimer = 1;
const timers = new Map();

function quiesce() {
  return request({ t: "quiesce" }).ok;
}

// The answer is false when the bridge sent lines while the library did its
// work: the reactions of their promises run after this task. Thus the timer
// tries again in the next task.
function fire(id) {
  const timer = timers.get(id);
  if (timer === undefined) return;
  if (quiesce()) {
    timers.delete(id);
    activity++;
    timer.callback(...timer.args);
  } else {
    os.setTimeout(() => fire(id), 0);
  }
}

globalThis.setTimeout = (callback, delay = 0, ...args) => {
  const id = nextTimer++;
  timers.set(id, { callback: typeof callback === "function" ? callback : () => {}, args });
  os.setTimeout(() => fire(id), Math.max(0, Number(delay) || 0));
  return id;
};
globalThis.clearTimeout = (id) => { timers.delete(id); };

// The page that WPT makes around an `.any.js` file defines `GLOBAL`, and
// the helper scripts read `location`. The runner is a shell: not a window,
// and not a worker.
globalThis.GLOBAL = {
  isWindow: () => false,
  isWorker: () => false,
  isShadowRealm: () => false,
};
const page = start.page;
globalThis.location = {
  href: page, origin: "http://web-platform.test:8000", protocol: "http:",
  host: "web-platform.test:8000", hostname: "web-platform.test", port: "8000",
  pathname: page.replace("http://web-platform.test:8000", ""), search: "", hash: "",
  toString() { return this.href; },
};

// The helper `common/sab.js` gets the class of a shared buffer from a
// shared `WebAssembly.Memory`. QuickJS has `SharedArrayBuffer`, but no
// WebAssembly.
globalThis.WebAssembly = {
  Memory: class Memory {
    constructor() { this.buffer = new SharedArrayBuffer(0); }
  },
};

// `Array.fromAsync` of ECMAScript 2024: this QuickJS does not have it. The
// helper `compression/resources/decompress.js` uses it. This form takes
// only the first argument.
if (typeof Array.fromAsync !== "function") {
  Array.fromAsync = async function fromAsync(items) {
    const values = [];
    for await (const value of items) values.push(value);
    return values;
  };
}

// The UTF-8 bytes of a string, for the method `bytes` of the response of
// the runner.
function utf8Bytes(text) {
  const binary = unescape(encodeURIComponent(text));
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  return bytes;
}

// A test loads its data files with `fetch`. This `fetch` is part of the
// runner, not of the library: it reads a file of WPT next to the test.
// The path of a file of WPT for a URL of the page, or null for a URL that
// needs a server.
function localPath(input) {
  const text = String(input).split(/[?#]/)[0];
  const host = "http://web-platform.test:8000/";
  let path;
  if (text.startsWith(host)) path = text.slice(host.length);
  else if (/^[a-zA-Z][a-zA-Z0-9+.-]*:/.test(text)) return null;
  else if (text.startsWith("/")) path = text.slice(1);
  else path = start.dir + "/" + text;
  const segments = [];
  for (const segment of path.split("/")) {
    if (segment === "..") segments.pop();
    else if (segment !== "." && segment !== "") segments.push(segment);
  }
  return segments.join("/");
}

// For a test of the Fetch Standard, the response is a `Response` of the
// library. The other tests get a plain object: their data can have text
// that a JSON parser of Elixir refuses, such as a lone surrogate.
globalThis.fetch = (input) => {
  const path = localPath(typeof input === "object" && input !== null && "url" in input ? input.url : input);
  // A file that a server program makes, such as `inspect-headers.py`, and
  // each other host, need the server of WPT, which the runner does not
  // have.
  if (path === null || /\.py$/.test(path)) {
    return Promise.reject(new TypeError("The runner has no server of WPT for " + String(input) + "."));
  }
  const reply = request({ t: "resource", p: path });
  if ("error" in reply) return Promise.reject(new TypeError(reply.error.$err.message));
  // A file that is not UTF-8 comes as its bytes.
  const body = typeof reply.ok === "string" ? reply.ok : new Uint8Array(reply.ok.$b);
  if (start.libraryResponse) return Promise.resolve(new globalThis.Response(body));
  const bytes = typeof body === "string" ? null : body;
  return Promise.resolve({
    ok: true,
    status: 200,
    text: () => Promise.resolve(bytes === null ? body : String.fromCharCode(...bytes)),
    json: () => Promise.resolve(JSON.parse(body)),
    arrayBuffer: () => Promise.resolve(bytes === null ? new ArrayBuffer(0) : bytes.buffer),
    bytes: () => Promise.resolve(bytes === null ? utf8Bytes(body) : bytes),
  });
};

// ---------------------------------------------------------------------------
// The test
// ---------------------------------------------------------------------------

std.loadScript(start.harness);

const statusNames = ["PASS", "FAIL", "TIMEOUT", "NOTRUN", "PRECONDITION_FAILED"];

add_result_callback((test) => {
  send({
    t: "result",
    name: test.name,
    status: statusNames[test.status],
    message: test.message === null ? null : String(test.message),
  });
});

// In a shell, a test has no timeout. A test that waits for a promise that
// nothing can settle stops the tests after it. When the library is idle,
// and the runner has no timer and gets no line, nothing can change: the
// tests that run then time out.
const startedTests = new Set();
let finished = false;

add_test_state_callback((test) => { startedTests.add(test); });

function watchdog() {
  const seen = activity;
  os.setTimeout(() => {
    if (finished) return;
    if (activity === seen && timers.size === 0 && quiesce() && activity === seen) {
      for (const test of startedTests) {
        if (test.phase === test.phases.STARTED) test.force_timeout();
      }
    }
    watchdog();
  }, 250);
}

watchdog();

add_completion_callback((_tests, harness) => {
  finished = true;
  send({
    t: "done",
    status: ["OK", "ERROR", "TIMEOUT", "PRECONDITION_FAILED"][harness.status],
    message: harness.message === null ? null : String(harness.message),
  });
});

std.loadScript(start.idlParser);
std.loadScript(start.layer);
dispatcher = globalThis.__webidl.install(
  { request, send },
  start.idls.map((path) => std.loadFile(path)),
  start.exposed,
);

for (const script of start.scripts) std.loadScript(script);
// An exception at the top level of the file stops the file. In a browser,
// the harness then has the status ERROR, and the tests that the file made
// before the exception run.
try {
  std.loadScript(start.test);
} catch (error) {
  send({ t: "error", message: "The file threw: " + String(error) });
  // The file makes no more tests.
  done();
}
