// The runner of one file of web-platform-tests in QuickJS.
//
// The runner talks with `Web.Test.QuickJS.Bridge` in lines of JSON on its
// standard input and output. The first line from the bridge gives the
// files to load. The runner then loads `testharness.js` in its shell mode,
// the WebIDL layer, the helper scripts of the test, and the test file. It
// sends one line for each result, and one line at the end.
import * as std from "std";
import * as os from "os";

// The lines have only ASCII characters: a string goes in the escapes of
// JSON. A string with a lone surrogate gets U+FFFD, as the library has
// strings of UTF-8.
function send(message) {
  const text = JSON.stringify(message, (_key, value) =>
    typeof value === "string" ? value.toWellFormed() : value);
  std.out.puts(text.replace(/[\u007f-￿]/g,
    (c) => "\\u" + c.charCodeAt(0).toString(16).padStart(4, "0")) + "\n");
  std.out.flush();
}

let nextId = 1;

// A request to the bridge. The bridge answers each request before the
// next one: the answer is the next line.
function request(message) {
  const id = nextId++;
  send(Object.assign({ id }, message));
  const line = std.in.getline();
  if (line === null) throw new Error("The bridge closed the connection.");
  const reply = JSON.parse(line);
  if (reply.id !== id) throw new Error("The bridge answered a different request.");
  if ("error" in reply) throw globalThis.__webidl.makeError(reply.error);
  return reply.ok;
}

const start = JSON.parse(std.in.getline());

// The host functions that testharness.js needs in its shell mode.
globalThis.self = globalThis;
globalThis.setTimeout = os.setTimeout;
globalThis.clearTimeout = os.clearTimeout;
globalThis.queueMicrotask = (callback) => { Promise.resolve().then(callback); };

// The page that WPT makes around an `.any.js` file defines `GLOBAL`, and
// the helper scripts read `location`. The runner is a shell: not a window,
// and not a worker.
globalThis.GLOBAL = {
  isWindow: () => false,
  isWorker: () => false,
  isShadowRealm: () => false,
};
const page = "http://web-platform.test:8000/" + start.test.split("/tree/")[1].replace(/^[^/]+\//, "").replace(/\.js$/, ".html");
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

// A test loads its data files with `fetch`. This `fetch` is part of the
// runner, not of the library: it reads a file of WPT next to the test.
globalThis.fetch = (url) => {
  const path = start.dir + "/" + String(url);
  // A file that a server program makes, such as `inspect-headers.py`,
  // needs the server of WPT, which the runner does not have.
  if (/\.py(\?|$)/.test(path)) {
    return Promise.reject(new TypeError("The runner has no server of WPT for " + path + "."));
  }
  let text;
  try {
    text = request({ t: "resource", p: path });
  } catch (error) {
    return Promise.reject(error);
  }
  return Promise.resolve({
    ok: true,
    status: 200,
    text: () => Promise.resolve(text),
    json: () => Promise.resolve(JSON.parse(text)),
  });
};

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

add_completion_callback((_tests, harness) => {
  send({
    t: "done",
    status: ["OK", "ERROR", "TIMEOUT", "PRECONDITION_FAILED"][harness.status],
    message: harness.message === null ? null : String(harness.message),
  });
});

std.loadScript(start.idlParser);
std.loadScript(start.layer);
globalThis.__webidl.install(request, start.idls.map((path) => std.loadFile(path)), start.exposed);

for (const script of start.scripts) std.loadScript(script);
std.loadScript(start.test);
