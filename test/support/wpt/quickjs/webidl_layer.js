// The WebIDL layer of the QuickJS runner.
//
// The layer reads the WebIDL files of WPT with the parser of WPT, and makes
// a JavaScript class for each interface that the test runs. Each method,
// attribute, and iterator of a class sends a call to the Elixir library
// through the bridge. Before a value goes to the library, the layer
// converts it as WebIDL specifies: a `ByteString`, a union, a record, a
// dictionary. After the call, it converts the result by the return type.
//
// The layer has no logic of the Standards. The library does the work, thus
// a test examines the library.
(function () {
  "use strict";

  // The handle and the interface of each object of the library. A WeakMap
  // makes no operation on the object, thus a Proxy sees no extra trap.
  const platform = new WeakMap();
  const definitions = new Map();
  const classes = new Map();
  let io = null;

  // The JavaScript values that go to the library by reference. The same
  // object comes back as the same object: the library keeps a chunk, a
  // reason, or an error with no copy.
  const references = [];
  const referenceIds = new Map();

  // The JavaScript functions that the library can call, with the `this`
  // value of each call.
  const callbacks = [];

  // The calls of the library to JavaScript functions that run now. A
  // request in such a function gives them to the bridge: see `call`.
  const running = [];

  // The kinds of the requests that run now, the newest last.
  const requests = [];

  // The promises of the library that are not settled yet, and the ones
  // with the type `Promise<undefined>`.
  const promises = new Map();
  const undefinedPromises = new Set();

  // One wrapper for each handle of an object of the library.
  const wrappers = new Map();

  // ---------------------------------------------------------------------
  // The definitions
  // ---------------------------------------------------------------------

  // Partial interfaces, partial dictionaries, and the members of a mixin
  // go into one definition.
  function add(definition) {
    if (definition.type === "includes") {
      const target = definitions.get(definition.target);
      const mixin = definitions.get(definition.includes);
      if (target && mixin) target.members.push(...mixin.members);
      return;
    }

    const known = definitions.get(definition.name);

    if (known && definition.partial) {
      known.members.push(...definition.members);
    } else if (known && known.partial) {
      definition.members.push(...known.members);
      definitions.set(definition.name, definition);
    } else if (!known) {
      definitions.set(definition.name, definition);
    }
  }

  function install(ioFunctions, idlTexts, exposed) {
    io = ioFunctions;
    const parsed = idlTexts.map((text) => WebIDL2.parse(text));
    // The mixins are complete before an `includes` adds their members.
    for (const list of parsed) for (const d of list) if (d.type !== "includes") add(d);
    for (const list of parsed) for (const d of list) if (d.type === "includes") add(d);
    for (const name of exposed) classes.set(name, makeInterface(name));
    // The parent of an interface can come after it in the list.
    for (const [name, cls] of classes) {
      const parent = definitions.get(name).inheritance;
      if (parent && classes.has(parent)) {
        Object.setPrototypeOf(cls.prototype, classes.get(parent).prototype);
        Object.setPrototypeOf(cls, classes.get(parent));
      }
    }
    for (const [name, cls] of classes) {
      Object.defineProperty(globalThis, name, {
        value: cls, writable: true, configurable: true, enumerable: false,
      });
    }
    return dispatch;
  }

  // ---------------------------------------------------------------------
  // Errors
  // ---------------------------------------------------------------------

  const domExceptionCodes = {
    IndexSizeError: 1, HierarchyRequestError: 3, WrongDocumentError: 4,
    InvalidCharacterError: 5, NoModificationAllowedError: 7, NotFoundError: 8,
    NotSupportedError: 9, InvalidStateError: 11, SyntaxError: 12,
    InvalidModificationError: 13, NamespaceError: 14, InvalidAccessError: 15,
    TypeMismatchError: 17, SecurityError: 18, NetworkError: 19, AbortError: 20,
    URLMismatchError: 21, QuotaExceededError: 22, TimeoutError: 23,
    InvalidNodeTypeError: 24, DataCloneError: 25,
  };

  // A DOMException as WebIDL specifies it: its attributes are getters on
  // its prototype, and a getter refuses an object that is not a
  // DOMException.
  const domExceptions = new WeakMap();

  function domException(object) {
    if (!domExceptions.has(object)) throw new TypeError("Illegal invocation: the object is not a DOMException.");
    return domExceptions.get(object);
  }

  class DOMException extends Error {
    constructor(message = undefined, name = undefined) {
      super();
      domExceptions.set(this, {
        message: message === undefined ? "" : toString(message),
        name: name === undefined ? "Error" : toString(name),
      });
    }
  }

  for (const [attribute, read] of [
    ["name", (state) => state.name],
    ["message", (state) => state.message],
    ["code", (state) => domExceptionCodes[state.name] || 0],
  ]) {
    Object.defineProperty(DOMException.prototype, attribute, {
      get() { return read(domException(this)); },
      enumerable: true,
      configurable: true,
    });
  }

  // The constants of DOMException in WebIDL, in their sequence.
  const domExceptionConstants = [
    "INDEX_SIZE_ERR", "DOMSTRING_SIZE_ERR", "HIERARCHY_REQUEST_ERR",
    "WRONG_DOCUMENT_ERR", "INVALID_CHARACTER_ERR", "NO_DATA_ALLOWED_ERR",
    "NO_MODIFICATION_ALLOWED_ERR", "NOT_FOUND_ERR", "NOT_SUPPORTED_ERR",
    "INUSE_ATTRIBUTE_ERR", "INVALID_STATE_ERR", "SYNTAX_ERR",
    "INVALID_MODIFICATION_ERR", "NAMESPACE_ERR", "INVALID_ACCESS_ERR",
    "VALIDATION_ERR", "TYPE_MISMATCH_ERR", "SECURITY_ERR", "NETWORK_ERR",
    "ABORT_ERR", "URL_MISMATCH_ERR", "QUOTA_EXCEEDED_ERR", "TIMEOUT_ERR",
    "INVALID_NODE_TYPE_ERR", "DATA_CLONE_ERR",
  ];

  domExceptionConstants.forEach((constant, index) => {
    Object.defineProperty(DOMException, constant, { value: index + 1, enumerable: true });
    Object.defineProperty(DOMException.prototype, constant, { value: index + 1, enumerable: true });
  });

  if (typeof globalThis.DOMException === "undefined") {
    Object.defineProperty(globalThis, "DOMException", {
      value: DOMException, writable: true, configurable: true,
    });
  }

  // An error of the library becomes the error of JavaScript with the same
  // name.
  function makeError(error) {
    const constructors = { TypeError, RangeError, SyntaxError, Error };
    if (error.name === "DOMException") return new globalThis.DOMException(error.message, error.domName);
    return new (constructors[error.name] || Error)(error.message);
  }

  // ---------------------------------------------------------------------
  // Values to the library
  // ---------------------------------------------------------------------

  function isObject(value) {
    return (typeof value === "object" && value !== null) || typeof value === "function";
  }

  function encodeNumber(number) {
    if (Number.isNaN(number)) return { $n: "NaN" };
    if (number === Infinity) return { $n: "Infinity" };
    if (number === -Infinity) return { $n: "-Infinity" };
    if (Object.is(number, -0)) return { $n: "-0" };
    return number;
  }

  // A buffer that a test detached has no bytes, as WebIDL specifies.
  function bytesOf(value) {
    const buffer = ArrayBuffer.isView(value) ? value.buffer : value;
    if (buffer.detached) return [];
    if (!ArrayBuffer.isView(value)) return Array.from(new Uint8Array(value));
    return Array.from(new Uint8Array(value.buffer, value.byteOffset, value.byteLength));
  }

  // WebIDL keeps a reference to a buffer, and the operation reads the bytes
  // after the conversion of all its arguments. Thus the layer reads them at
  // the end: a later argument can detach the buffer.
  function readBuffers(value) {
    if (value === null || typeof value !== "object") return value;
    if (Array.isArray(value)) return value.map(readBuffers);
    if ("$lazy" in value) return { $b: bytesOf(value.$lazy) };
    const result = {};
    for (const key of Object.keys(value)) result[key] = readBuffers(value[key]);
    return result;
  }

  const arrayBufferLength = Object.getOwnPropertyDescriptor(ArrayBuffer.prototype, "byteLength").get;
  const sharedBufferLength = typeof SharedArrayBuffer === "function"
    ? Object.getOwnPropertyDescriptor(SharedArrayBuffer.prototype, "byteLength").get
    : null;

  // The check uses the internal slots of a buffer, as WebIDL does: it makes
  // no operation on a Proxy.
  function isBuffer(getter, value) {
    try { getter.call(value); return true; } catch (_error) { return false; }
  }

  function isBufferSource(value) {
    return ArrayBuffer.isView(value) || isBuffer(arrayBufferLength, value) ||
      (sharedBufferLength !== null && isBuffer(sharedBufferLength, value));
  }

  const dataViewLength = Object.getOwnPropertyDescriptor(DataView.prototype, "byteLength").get;
  const typedArrayTag = Object.getOwnPropertyDescriptor(Object.getPrototypeOf(Uint8Array.prototype), Symbol.toStringTag).get;

  function isShared(value) {
    if (sharedBufferLength === null) return false;
    return isBuffer(sharedBufferLength, ArrayBuffer.isView(value) ? value.buffer : value);
  }

  // The checks of WebIDL for a buffer type. A buffer that is shared needs
  // the extended attribute [AllowShared], or a type that allows it.
  function bufferMatches(name, value, extAttrs) {
    const allowShared = extAttrs.some((a) => a.name === "AllowShared") ||
      name === "AllowSharedBufferSource" || name === "SharedArrayBuffer";
    if (!isBufferSource(value) || (!allowShared && isShared(value))) return false;
    switch (name) {
      case "ArrayBuffer": return isBuffer(arrayBufferLength, value);
      case "SharedArrayBuffer": return isShared(value) && !ArrayBuffer.isView(value);
      case "ArrayBufferView": return ArrayBuffer.isView(value);
      case "DataView": return isBuffer(dataViewLength, value);
      case "BufferSource":
      case "AllowSharedBufferSource": return true;
      default: return typedArrayTag.call(value) === name;
    }
  }

  // A value of the type `any`.
  // `undefined` is `nil` in the library, and `null` is the atom `:null`: a
  // stream can have both as chunks. A buffer goes as its bytes. Each other
  // object goes by reference.
  function encodeAny(value) {
    if (value === undefined) return { $u: 1 };
    if (value === null) return { $null: 1 };
    switch (typeof value) {
      case "boolean": return value;
      case "number": return encodeNumber(value);
      case "string": return value;
      case "bigint": return Number(value);
    }
    if (typeof value === "object" && platform.has(value)) return { $h: platform.get(value).handle };
    if (typeof value === "object" && isBufferSource(value)) return { $lazy: value };
    return { $js: reference(value) };
  }

  function reference(value) {
    if (!referenceIds.has(value)) {
      referenceIds.set(value, references.length);
      references.push(value);
    }
    return referenceIds.get(value);
  }

  // A JavaScript function that the library can call. The same function, with
  // the same `this`, gives the same function to the library: for example,
  // `removeEventListener` finds the listener that `addEventListener` added.
  const callbackIds = new Map();

  function callback(fn, thisArg, arity) {
    const start = callbackMember === "start";
    const known = callbackIds.get(fn) || [];
    const found = known.find((e) => e.thisArg === thisArg && e.start === start && e.arity === arity);
    if (found) return { $f: found.id, n: arity };
    callbacks.push({ fn, thisArg, start });
    known.push({ thisArg, start, arity, id: callbacks.length - 1 });
    callbackIds.set(fn, known);
    return { $f: callbacks.length - 1, n: arity };
  }

  // A callback interface, such as `EventListener`: a function, or an object
  // with the operation. WebIDL gets the operation from the object when the
  // library calls it.
  const userObjects = new WeakMap();

  function callbackInterface(d, value) {
    if (!isObject(value)) throw new TypeError("The value is not a " + d.name + ".");
    const operation = d.members.find((m) => m.type === "operation");
    const arity = operation.arguments.length;
    if (typeof value === "function") return callback(value, undefined, arity);
    if (!userObjects.has(value)) {
      userObjects.set(value, function (...args) {
        const method = value[operation.name];
        if (typeof method !== "function") throw new TypeError("The object has no function " + operation.name + ".");
        return method.apply(value, args);
      });
    }
    return callback(userObjects.get(value), undefined, arity);
  }

  // The `this` value of the callbacks of a dictionary, for example the
  // underlying source of a stream, and the name of the member.
  let callbackThis = undefined;
  let callbackMember = undefined;

  function toString(value) {
    if (typeof value === "symbol") throw new TypeError("Cannot convert a Symbol value to a string.");
    return String(value);
  }

  function byteString(value) {
    const text = toString(value);
    const bytes = [];
    for (let i = 0; i < text.length; i++) {
      const unit = text.charCodeAt(i);
      if (unit > 255) throw new TypeError("The value is not a ByteString: a character is above U+00FF.");
      bytes.push(unit);
    }
    // A ByteString is a binary of Elixir: `$bs`. A buffer source is a
    // `Web.Uint8Array`: `$b`.
    return { $bs: bytes };
  }

  const integerTypes = {
    byte: [-128, 127], octet: [0, 255], short: [-32768, 32767],
    "unsigned short": [0, 65535], long: [-2147483648, 2147483647],
    "unsigned long": [0, 4294967295],
    "long long": [Number.MIN_SAFE_INTEGER, Number.MAX_SAFE_INTEGER],
    "unsigned long long": [0, Number.MAX_SAFE_INTEGER],
  };

  // The conversion of WebIDL for an integer type with no extended
  // attribute: the value wraps modulo the size of the type.
  function integer(name, value, extAttrs) {
    let number = Number(value);
    const [min, max] = integerTypes[name];
    const enforce = extAttrs.some((a) => a.name === "EnforceRange");
    const clamp = extAttrs.some((a) => a.name === "Clamp");

    if (enforce) {
      if (!Number.isFinite(number)) throw new TypeError("The value is not a finite number.");
      number = Math.trunc(number);
      if (number < min || number > max) throw new TypeError("The value is out of the range.");
      return number;
    }

    if (Number.isNaN(number) || !Number.isFinite(number)) return clamp && Number.isFinite(number) ? number : 0;
    if (clamp) return Math.min(Math.max(Math.round(number), min), max);

    number = Math.trunc(number);
    const size = max - min + 1;
    number = ((number % size) + size) % size;
    if (min < 0 && number > max) number -= size;
    return number === 0 ? 0 : number;
  }

  function resolve(idlType) {
    if (typeof idlType.idlType === "string" && !idlType.generic && !idlType.union) {
      const d = definitions.get(idlType.idlType);
      if (d && d.type === "typedef") {
        // The types of the parser have getters on their prototype: a child
        // object keeps them.
        const resolved = resolve(d.idlType);
        return Object.create(resolved, { nullable: { value: idlType.nullable || resolved.nullable } });
      }
    }
    return idlType;
  }

  const bufferTypes = new Set([
    "ArrayBuffer", "SharedArrayBuffer", "ArrayBufferView", "BufferSource",
    "AllowSharedBufferSource", "DataView", "Int8Array", "Uint8Array",
    "Uint8ClampedArray", "Int16Array", "Uint16Array", "Int32Array",
    "Uint32Array", "Float32Array", "Float64Array", "BigInt64Array", "BigUint64Array",
  ]);
  const stringTypes = new Set(["DOMString", "USVString", "ByteString"]);
  const numberTypes = new Set([
    "byte", "octet", "short", "unsigned short", "long", "unsigned long",
    "long long", "unsigned long long", "float", "unrestricted float",
    "double", "unrestricted double",
  ]);

  function convert(idlType, value, extAttrs = []) {
    const t = resolve(idlType);
    const attributes = extAttrs.concat(t.extAttrs || []);

    if (t.nullable && (value === null || value === undefined)) return null;
    if (t.union) return convertUnion(t, value, attributes);
    if (t.generic === "sequence" || t.generic === "FrozenArray") return convertSequence(t.idlType[0], value);
    if (t.generic === "record") return convertRecord(t.idlType[0], t.idlType[1], value);
    if (t.generic) throw new TypeError("The type " + t.generic + " is not in the layer yet.");
    return convertNamed(t.idlType, value, attributes);
  }

  function convertNamed(name, value, extAttrs) {
    switch (name) {
      case "any": return encodeAny(value);
      case "undefined": return { $u: 1 };
      case "boolean": return Boolean(value);
      case "object":
        if (!isObject(value)) throw new TypeError("The value is not an object.");
        return encodeAny(value);
      case "DOMString":
        if (value === null && extAttrs.some((a) => a.name === "LegacyNullToEmptyString")) return "";
        return toString(value);
      case "USVString":
        // A lone surrogate becomes U+FFFD, as WebIDL specifies.
        return toString(value).toWellFormed();
      case "ByteString": return byteString(value);
      case "double":
      case "float": {
        const number = Number(value);
        if (!Number.isFinite(number)) throw new TypeError("The value is not a finite number.");
        return encodeNumber(number);
      }
      case "unrestricted double":
      case "unrestricted float": return encodeNumber(Number(value));
    }

    if (integerTypes[name]) return integer(name, value, extAttrs);

    if (bufferTypes.has(name)) {
      if (!bufferMatches(name, value, extAttrs)) throw new TypeError("The value is not a " + name + ".");
      return { $lazy: value };
    }

    const d = definitions.get(name);
    if (d && d.type === "callback") {
      if (typeof value !== "function") throw new TypeError("The value is not a function: " + name + ".");
      return callback(value, callbackThis, d.arguments.length);
    }
    if (d && d.type === "callback interface") return callbackInterface(d, value);
    if (name === "Function") {
      if (typeof value !== "function") throw new TypeError("The value is not a function.");
      return callback(value, undefined, value.length);
    }
    if (d && d.type === "enum") {
      const text = toString(value);
      if (!d.values.some((v) => v.value === text)) throw new TypeError("The value '" + text + "' is not in the enumeration " + name + ".");
      return text;
    }
    if (d && d.type === "dictionary") return convertDictionary(d, value);
    if (d && (d.type === "interface" || d.type === "interface mixin")) {
      if (!isObject(value) || !platform.has(value) || !inherits(platform.get(value).cls, name)) {
        throw new TypeError("The value is not a " + name + ".");
      }
      return { $h: platform.get(value).handle };
    }
    throw new TypeError("The type " + name + " is not in the layer yet.");
  }

  function inherits(className, name) {
    for (let c = className; c; c = (definitions.get(c) || {}).inheritance) if (c === name) return true;
    return false;
  }

  function iteratorMethod(value) {
    const method = value[Symbol.iterator];
    if (method === undefined || method === null) return undefined;
    if (typeof method !== "function") throw new TypeError("The value is not iterable.");
    return method;
  }

  // A sequence of sequences goes as pairs: the bridge makes a tuple of each
  // inner list of two items.
  function convertSequence(elementType, value) {
    if (!isObject(value)) throw new TypeError("The value is not a sequence.");
    const method = iteratorMethod(value);
    if (method === undefined) throw new TypeError("The value is not iterable.");
    const items = [];
    for (const item of { [Symbol.iterator]: () => method.call(value) }) items.push(convert(elementType, item));
    const inner = resolve(elementType);
    return inner.generic === "sequence" ? { $p: items } : items;
  }

  // A record keeps the sequence of its keys: the bridge gives a list of
  // tuples.
  // A key that comes two times after its conversion, for example two lone
  // surrogates that both become U+FFFD, keeps its first place and its last
  // value, as WebIDL specifies.
  function convertRecord(keyType, valueType, value) {
    if (!isObject(value)) throw new TypeError("The value is not a record.");
    const pairs = [];
    const places = new Map();
    // The keys include the symbols, as WebIDL specifies: the conversion of
    // an enumerable symbol key to a string fails.
    for (const key of Reflect.ownKeys(value)) {
      const descriptor = Reflect.getOwnPropertyDescriptor(value, key);
      if (descriptor !== undefined && descriptor.enumerable) {
        const typedKey = convert(keyType, key);
        const typedValue = convert(valueType, value[key]);
        const identity = JSON.stringify(typedKey);
        if (places.has(identity)) pairs[places.get(identity)][1] = typedValue;
        else { places.set(identity, pairs.length); pairs.push([typedKey, typedValue]); }
      }
    }
    return { $r: pairs };
  }

  function dictionaryMembers(d) {
    const members = [];
    for (let current = d; current; current = definitions.get(current.inheritance)) {
      members.push(...current.members.filter((m) => m.type === "field"));
    }
    return members.sort((a, b) => (a.name < b.name ? -1 : a.name > b.name ? 1 : 0));
  }

  // The default `{}` of a dictionary is the conversion of `undefined`: the
  // dictionary gets the defaults of its members.
  function defaultValue(member) {
    const v = member.default;
    switch (v.type) {
      case "boolean": return v.value;
      case "number": return encodeNumber(Number(v.value));
      case "string": return v.value;
      case "null": return null;
      case "sequence": return [];
      case "dictionary": return convert(member.idlType, undefined);
      default: return { $u: 1 };
    }
  }

  function convertDictionary(d, value) {
    if (value !== undefined && value !== null && !isObject(value)) {
      throw new TypeError("The value is not a dictionary " + d.name + ".");
    }
    const result = {};
    const previousThis = callbackThis;
    callbackThis = value;
    try {
      for (const member of dictionaryMembers(d)) {
        convertMember(d, member, value, result);
      }
    } finally {
      callbackThis = previousThis;
    }
    return { $d: result };
  }

  function convertMember(d, member, value, result) {
    {
      const memberValue = value === undefined || value === null ? undefined : value[member.name];
      if (memberValue !== undefined) {
        callbackMember = member.name;
        try {
          result[member.name] = convert(member.idlType, memberValue, member.extAttrs || []);
        } finally {
          callbackMember = undefined;
        }
      } else if (member.default) {
        result[member.name] = defaultValue(member);
      } else if (member.required) {
        throw new TypeError("The dictionary " + d.name + " needs the member " + member.name + ".");
      }
    }
  }

  function flatten(t) {
    const members = [];
    for (const m of t.idlType) {
      const r = resolve(m);
      if (r.union) members.push(...flatten(r));
      else members.push(r);
    }
    return members;
  }

  // The union steps of WebIDL, for the kinds of members of these
  // interfaces.
  function convertUnion(t, value, extAttrs) {
    const members = flatten(t);
    const named = (m) => (typeof m.idlType === "string" && !m.generic ? m.idlType : null);
    const find = (test) => members.find(test);

    if (value === null || value === undefined) {
      const dictionary = find((m) => definitions.get(named(m))?.type === "dictionary");
      if (dictionary) return convert(dictionary, value);
    }

    if (isObject(value)) {
      if (platform.has(value)) {
        const iface = find((m) => named(m) && inherits(platform.get(value).cls, named(m)));
        if (iface) return { $h: platform.get(value).handle };
      }
      if (isBufferSource(value)) {
        const buffer = find((m) => bufferTypes.has(named(m)));
        if (buffer) return { $lazy: value };
      }
      const sequence = find((m) => m.generic === "sequence" || m.generic === "FrozenArray");
      if (sequence) {
        const method = iteratorMethod(value);
        if (method !== undefined) return convert(sequence, value);
      }
      const record = find((m) => m.generic === "record" || definitions.get(named(m))?.type === "dictionary");
      if (record) return convert(record, value);
      const object = find((m) => named(m) === "object");
      if (object) return encodeAny(value);
    }

    if (typeof value === "boolean") {
      const boolean = find((m) => named(m) === "boolean");
      if (boolean) return value;
    }
    if (typeof value === "number") {
      const number = find((m) => numberTypes.has(named(m)));
      if (number) return convert(number, value, extAttrs);
    }
    const string = find((m) => stringTypes.has(named(m)) || definitions.get(named(m))?.type === "enum");
    if (string) return convert(string, value, extAttrs);
    const number = find((m) => numberTypes.has(named(m)));
    if (number) return convert(number, value, extAttrs);
    const boolean = find((m) => named(m) === "boolean");
    if (boolean) return Boolean(value);
    throw new TypeError("The value is not in the union.");
  }

  // ---------------------------------------------------------------------
  // Values from the library
  // ---------------------------------------------------------------------

  function utf8Bytes(text) {
    const bytes = [];
    for (const character of text) {
      const c = character.codePointAt(0);
      if (c < 0x80) bytes.push(c);
      else if (c < 0x800) bytes.push(0xc0 | (c >> 6), 0x80 | (c & 63));
      else if (c < 0x10000) bytes.push(0xe0 | (c >> 12), 0x80 | ((c >> 6) & 63), 0x80 | (c & 63));
      else bytes.push(0xf0 | (c >> 18), 0x80 | ((c >> 12) & 63), 0x80 | ((c >> 6) & 63), 0x80 | (c & 63));
    }
    return bytes;
  }

  function latin1(bytes) {
    let text = "";
    for (const b of bytes) text += String.fromCharCode(b);
    return text;
  }

  // The bytes of a string that is not UTF-8 decode with U+FFFD for each
  // error.
  function utf8Text(bytes) {
    let text = "";
    let i = 0;
    while (i < bytes.length) {
      const b = bytes[i];
      const size = b < 0x80 ? 1 : b >= 0xc2 && b < 0xe0 ? 2 : b >= 0xe0 && b < 0xf0 ? 3 : b >= 0xf0 && b < 0xf5 ? 4 : 0;
      let code = size === 1 ? b : size === 2 ? b & 31 : size === 3 ? b & 15 : b & 7;
      let valid = size > 0 && i + size <= bytes.length;
      for (let j = 1; valid && j < size; j++) {
        if ((bytes[i + j] & 0xc0) !== 0x80) valid = false;
        else code = (code << 6) | (bytes[i + j] & 63);
      }
      if (valid && ((size === 3 && (code < 0x800 || (code >= 0xd800 && code < 0xe000))) || (size === 4 && (code < 0x10000 || code > 0x10ffff)))) valid = false;
      if (valid) { text += String.fromCodePoint(code); i += size; } else { text += "�"; i += 1; }
    }
    return text;
  }

  // The bridge gives the same handle again only for a struct that refers to
  // a process (`interned`): the layer keeps only those objects.
  function wrap(handle, className, interned) {
    if (wrappers.has(handle)) return wrappers.get(handle);
    const cls = classes.get(className);
    const object = Object.create(cls ? cls.prototype : Object.prototype);
    platform.set(object, { handle, cls: className });
    if (interned) wrappers.set(handle, object);
    return object;
  }

  // A promise of the library: the bridge settles it later.
  function libraryPromise(id) {
    if (!promises.has(id)) {
      let resolve, reject;
      const promise = new Promise((res, rej) => { resolve = res; reject = rej; });
      promises.set(id, { promise, resolve, reject });
    }
    return promises.get(id).promise;
  }

  // ---------------------------------------------------------------------
  // The lines of the bridge
  // ---------------------------------------------------------------------

  // The constructor of a stream calls `start` at once. The Streams Standard
  // calls the other functions of the source, such as `pull`, after the
  // promise of `start` is fulfilled: in a microtask, after the constructor
  // returns. The library calls them when `start` returns. Thus such a call
  // during a constructor runs in a microtask, and the bridge does not wait
  // for it.
  function deferred(message) {
    return requests[requests.length - 1] === "constructor" && !callbacks[message.f].start;
  }

  function dispatch(message) {
    if (message.t === "invoke" && deferred(message)) {
      io.send({ t: "deferred", ref: message.ref });
      queueMicrotask(() => invoke(message));
    } else if (message.t === "settle") {
      const entry = promises.get(message.p) || (libraryPromise(message.p), promises.get(message.p));
      if ("ok" in message) entry.resolve(undefinedPromises.has(message.p) ? undefined : decodeAny(message.ok));
      else entry.reject(decodeAny(message.error));
    } else if (message.t === "invoke") {
      invoke(message);
    } else {
      throw new Error("The layer does not know the line " + JSON.stringify(message));
    }
  }

  // The library calls a JavaScript function. A promise that the function
  // gives settles a promise of the library later.
  // A promise that the function returns settles a promise of the library.
  // The library reacts before the next reaction of JavaScript, as a
  // promise of JavaScript would do: the line `jsSettled` is a request.
  function invoke(message) {
    const entry = callbacks[message.f];
    let result;
    running.push(message.ref);
    try {
      result = entry.fn.apply(entry.thisArg, message.a.map(decodeAny));
    } catch (error) {
      running.pop();
      io.send({ t: "return", ref: message.ref, throw: readBuffers(encodeAny(error)) });
      return;
    }
    running.pop();
    if (result !== null && (typeof result === "object" || typeof result === "function") && typeof result.then === "function") {
      const id = reference(result);
      io.send({ t: "return", ref: message.ref, jp: id });
      Promise.resolve(result).then(
        (value) => io.request({ t: "jsSettled", p: id, w: running.slice(), ok: readBuffers(encodeAny(value)) }),
        (error) => io.request({ t: "jsSettled", p: id, w: running.slice(), error: readBuffers(encodeAny(error)) }),
      );
    } else {
      io.send({ t: "return", ref: message.ref, ok: readBuffers(encodeAny(result)) });
    }
  }

  function decodeAny(value) {
    if (value === null) return undefined;
    if (typeof value !== "object") return value;
    if (Array.isArray(value)) return value.map(decodeAny);
    if ("$u" in value) return undefined;
    if ("$null" in value) return null;
    if ("$js" in value) return references[value.$js];
    if ("$f" in value) return callbacks[value.$f].fn;
    if ("$pr" in value) return libraryPromise(value.$pr);
    if ("$pv" in value) {
      return "ok" in value.$pv ? Promise.resolve(decodeAny(value.$pv.ok)) : Promise.reject(decodeAny(value.$pv.error));
    }
    if ("$err" in value) return makeError(value.$err);
    if ("$n" in value) return Number(value.$n);
    if ("$b" in value) return new Uint8Array(value.$b);
    if ("$ab" in value) return new Uint8Array(value.$ab).buffer;
    if ("$h" in value) return wrap(value.$h, value.$c, value.$i === 1);
    if ("$o" in value) {
      const object = {};
      for (const key of Object.keys(value.$o)) object[key] = decodeAny(value.$o[key]);
      return object;
    }
    throw new Error("The bridge gave a value that the layer does not know.");
  }

  function fromLibrary(idlType, value) {
    const t = resolve(idlType);
    // The value of a `Promise<undefined>` is `undefined`: the library can
    // give `:ok`, the Elixir value for "nothing".
    if (t.generic === "Promise" && resolve(t.idlType[0]).idlType === "undefined" && value !== null && typeof value === "object") {
      if ("$pv" in value) return "ok" in value.$pv ? Promise.resolve(undefined) : Promise.reject(decodeAny(value.$pv.error));
      if ("$pr" in value) {
        undefinedPromises.add(value.$pr);
        return libraryPromise(value.$pr);
      }
    }
    if (t.generic === "Promise") return decodeAny(value);
    if (value === null && t.nullable) return null;
    if (t.idlType === "any") return decodeAny(value);
    if (t.generic === "sequence" || t.generic === "FrozenArray") return value.map((item) => fromLibrary(t.idlType[0], item));
    if (t.generic === "record") {
      // A list of pairs, or a map of the library.
      const pairs = value !== null && typeof value === "object" && "$o" in value ? Object.entries(value.$o) : value;
      const object = {};
      for (const [k, v] of pairs) object[fromLibrary(t.idlType[0], k)] = fromLibrary(t.idlType[1], v);
      return object;
    }
    switch (t.idlType) {
      case "ByteString": return latin1(typeof value === "string" ? utf8Bytes(value) : value.$b);
      case "DOMString":
      case "USVString": return typeof value === "string" ? value : utf8Text(value.$b);
      case "undefined": return undefined;
      case "boolean": return Boolean(value);
    }
    if (numberTypes.has(t.idlType)) return decodeAny(value);
    const d = definitions.get(t.idlType);
    if (d && d.type === "dictionary") return decodeDictionary(d, value);
    return decodeAny(value);
  }

  // The keys of a map of the library are in snake_case: `base_url` is the
  // member `baseURL`.
  function snakeCase(name) {
    return name.replace(/([a-z0-9])([A-Z])/g, "$1_$2").replace(/([A-Z])([A-Z][a-z])/g, "$1_$2").toLowerCase();
  }

  function decodeDictionary(d, value) {
    const object = decodeAny(value);
    if (object === null || typeof object !== "object" || !("$o" in value)) return object;
    for (const member of dictionaryMembers(d)) {
      const key = member.name in value.$o ? member.name : snakeCase(member.name);
      if (key in value.$o) {
        if (key !== member.name) delete object[key];
        object[member.name] = fromLibrary(member.idlType, value.$o[key]);
      }
    }
    return object;
  }

  // ---------------------------------------------------------------------
  // The classes
  // ---------------------------------------------------------------------

  function handleOf(object, name, member) {
    if (!isObject(object) || !platform.has(object) || !inherits(platform.get(object).cls, name)) {
      throw new TypeError("Illegal invocation: '" + member + "' needs a " + name + ".");
    }
    return platform.get(object).handle;
  }

  // The constructors of the streams take an `object`, and convert it to a
  // dictionary at their first step: "Let underlyingSourceDict be
  // underlyingSource, converted to an IDL value of type UnderlyingSource."
  // The callbacks of the dictionary get the object as their `this`.
  const objectDictionaries = {
    "ReadableStream.constructor.0": "UnderlyingSource",
    "WritableStream.constructor.0": "UnderlyingSink",
    "TransformStream.constructor.0": "Transformer",
  };

  function argumentType(name, member, index, a) {
    const dictionary = objectDictionaries[name + "." + member + "." + index];
    return dictionary ? { idlType: dictionary, nullable: false, union: false, generic: "", extAttrs: [] } : a.idlType;
  }

  // An argument that is not given, after the last given argument, does not
  // go to the library: the library has its own default. The call also
  // gives the number of arguments in WebIDL: see `declared`.
  function convertArguments(name, member, argumentDefinitions, values) {
    const required = argumentDefinitions.filter((a) => !a.optional && !a.variadic).length;
    if (values.length < required) {
      throw new TypeError("Failed to execute '" + member + "' on '" + name + "': " + required + " argument(s) required, but only " + values.length + " present.");
    }
    const result = [];
    const later = [];
    argumentDefinitions.forEach((a, index) => {
      if (a.variadic) {
        for (const v of values.slice(index)) result.push(convert(a.idlType, v, a.extAttrs || []));
      } else if (objectDictionaries[name + "." + member + "." + index]) {
        // The argument is an `object`, as the WebIDL file specifies. The
        // steps of the constructor convert it to a dictionary later, after
        // the other arguments.
        if (values[index] !== undefined && !isObject(values[index])) throw new TypeError("The value is not an object.");
        later.push([result.length, a, index]);
        result.push(null);
      } else if (index < values.length && (values[index] !== undefined || !a.optional)) {
        // An argument that is not optional is converted also when it is
        // undefined: a string gets "undefined", as WebIDL specifies.
        result.push(convert(a.idlType, values[index], a.extAttrs || []));
      } else if (a.default && a.default.type === "null") {
        // The library has its own default for a `null` default.
        result.push({ $u: 1 });
      } else if (a.default) {
        result.push(defaultValue(a));
      } else if (a.optional && resolve(a.idlType).idlType !== undefined && definitions.get(resolve(a.idlType).idlType)?.type === "dictionary") {
        result.push(convert(a.idlType, undefined));
      } else {
        result.push({ $u: 1 });
      }
    });
    for (const [place, a, index] of later) {
      result[place] = convert(argumentType(name, member, index, a), values[index] === undefined ? null : values[index]);
    }
    while (result.length > 0 && result[result.length - 1] && result[result.length - 1].$u === 1) result.pop();
    return result;
  }

  function declared(argumentDefinitions) {
    return argumentDefinitions.filter((a) => !a.variadic).length;
  }

  function longest(overloads) {
    return overloads.reduce((a, b) => (b.arguments.length > a.arguments.length ? b : a));
  }

  // The overload resolution of WebIDL, for the kinds of types of these
  // interfaces: the overloads that accept the number of arguments, then the
  // first one whose type accepts the value at the first index where the
  // types are different.
  function select(overloads, values) {
    if (overloads.length === 1) return overloads[0];
    const n = Math.min(values.length, Math.max(...overloads.map((o) => o.arguments.length)));
    const fits = (o) => {
      const required = o.arguments.filter((a) => !a.optional && !a.variadic).length;
      return required <= n && (n <= o.arguments.length || o.arguments.some((a) => a.variadic));
    };
    const candidates = overloads.filter(fits);
    if (candidates.length === 0) return longest(overloads);
    for (let i = 0; i < n && candidates.length > 1; i++) {
      const types = candidates.map((o) => JSON.stringify(o.arguments[i] ? o.arguments[i].idlType : null));
      if (types.every((t) => t === types[0])) continue;
      const match = candidates.find((o) => o.arguments[i] && accepts(resolve(o.arguments[i].idlType), values[i]));
      if (match) return match;
    }
    return candidates[0];
  }

  function accepts(t, value) {
    if (t.nullable && (value === null || value === undefined)) return true;
    if (t.union) return flatten(t).some((m) => accepts(m, value));
    if (t.generic === "sequence" || t.generic === "FrozenArray") return isObject(value) && iteratorMethod(value) !== undefined;
    if (t.generic === "record") return isObject(value);
    const name = t.idlType;
    if (name === "any") return true;
    if (stringTypes.has(name)) return typeof value === "string";
    if (numberTypes.has(name)) return typeof value === "number";
    if (name === "boolean") return typeof value === "boolean";
    if (name === "object") return isObject(value);
    if (bufferTypes.has(name)) return isBufferSource(value);
    const d = definitions.get(name);
    if (!d) return false;
    if (d.type === "enum") return typeof value === "string";
    if (d.type === "dictionary") return value === undefined || value === null || (isObject(value) && !platform.has(value));
    if (d.type === "callback") return typeof value === "function";
    if (d.type === "callback interface") return isObject(value);
    if (d.type === "interface") return isObject(value) && platform.has(value) && inherits(platform.get(value).cls, name);
    return false;
  }

  // The library has immutable buffers: an operation that writes into a
  // buffer argument, such as `encodeInto`, gives the new bytes, and the
  // layer copies them into the JavaScript buffer.
  function call(message, originals = []) {
    if (message.a) message.a = readBuffers(message.a);
    message.w = running.slice();
    requests.push(message.k);
    let reply;
    try {
      reply = io.request(Object.assign({ t: "call" }, message));
    } finally {
      requests.pop();
    }
    if ("error" in reply) throw decodeAny(reply.error);
    for (const out of reply.out || []) {
      const target = originals[out.i];
      const view = ArrayBuffer.isView(target)
        ? new Uint8Array(target.buffer, target.byteOffset, target.byteLength)
        : new Uint8Array(target);
      view.set(out.b.slice(0, view.length));
    }
    return reply.ok;
  }

  function makeIterator(object, name, keyType, valueType, kind) {
    const prototype = iteratorPrototype(name);
    let index = 0;
    const iterator = Object.create(prototype);
    Object.defineProperty(iterator, "__next", {
      value: () => {
        // The pairs come again at each step, as WebIDL specifies: a change
        // during the iteration is visible.
        const pairs = call({ i: name, k: "iterate", self: { $h: platform.get(object).handle } });
        if (index >= pairs.length) return { value: undefined, done: true };
        const [key, value] = pairs[index++];
        const k = fromLibrary(keyType, key);
        const v = fromLibrary(valueType, value);
        return { value: kind === "keys" ? k : kind === "values" ? v : [k, v], done: false };
      },
    });
    return iterator;
  }

  const iteratorPrototypes = new Map();
  const IteratorPrototype = Object.getPrototypeOf(Object.getPrototypeOf([][Symbol.iterator]()));

  function iteratorPrototype(name) {
    if (!iteratorPrototypes.has(name)) {
      const prototype = Object.create(IteratorPrototype);
      Object.defineProperty(prototype, "next", {
        value: function next() {
          if (!isObject(this) || typeof this.__next !== "function") throw new TypeError("Illegal invocation.");
          return this.__next();
        },
        writable: true, enumerable: true, configurable: true,
      });
      Object.defineProperty(prototype, Symbol.toStringTag, { value: name + " Iterator", configurable: true });
      iteratorPrototypes.set(name, prototype);
    }
    return iteratorPrototypes.get(name);
  }

  // An operation or an attribute with a promise type gives a rejected
  // promise in place of an exception, as WebIDL specifies. This includes the
  // check of `this` and the conversion of the arguments.
  function promiseSteps(idlType, fn) {
    if (resolve(idlType).generic !== "Promise") return fn;
    return function (...values) {
      try {
        return fn.apply(this, values);
      } catch (error) {
        return Promise.reject(error);
      }
    };
  }

  function defineMethod(target, key, length, fn) {
    Object.defineProperty(fn, "name", { value: typeof key === "symbol" ? "[" + key.description + "]" : key });
    Object.defineProperty(fn, "length", { value: length });
    Object.defineProperty(target, key, { value: fn, writable: true, enumerable: typeof key === "string", configurable: true });
  }

  function makeInterface(name) {
    const d = definitions.get(name);
    if (!d) throw new Error("The WebIDL files have no interface " + name + ".");
    const members = d.members;
    const constructors = members.filter((m) => m.type === "constructor");

    const cls = function (...values) {
      if (new.target === undefined) throw new TypeError("Failed to construct '" + name + "': please use the 'new' operator.");
      if (constructors.length === 0) throw new TypeError("Illegal constructor.");
      const definition = select(constructors, values);
      const result = call({
        i: name, k: "constructor", n: declared(definition.arguments),
        a: convertArguments(name, "constructor", definition.arguments, values),
      });
      const object = Object.create(new.target.prototype);
      platform.set(object, { handle: result.$h, cls: name });
      if (result.$i === 1) wrappers.set(result.$h, object);
      return object;
    };
    Object.defineProperty(cls, "name", { value: name });
    Object.defineProperty(cls, "length", {
      value: constructors.length ? longest(constructors).arguments.filter((a) => !a.optional).length : 0,
    });

    const operations = new Map();
    for (const m of members) {
      if (m.type === "operation" && m.name) {
        const key = (m.special === "static" ? "static " : "") + m.name;
        if (!operations.has(key)) operations.set(key, []);
        operations.get(key).push(m);
      }
    }

    for (const [key, overloads] of operations) {
      const first = longest(overloads);
      const isStatic = first.special === "static";
      const opName = first.name;
      const required = Math.min(...overloads.map((o) => o.arguments.filter((a) => !a.optional && !a.variadic).length));
      const target = isStatic ? cls : cls.prototype;

      defineMethod(target, opName, required, promiseSteps(first.idlType, function (...values) {
        const definition = select(overloads, values);
        const returnType = definition.idlType;
        const self = isStatic ? null : { $h: handleOf(this, name, opName) };
        const args = convertArguments(name, opName, definition.arguments, values);
        // `p`: the result is a promise. A library function can give
        // `{:ok, value}` or `{:error, reason}` in place of a promise.
        const result = call({
          i: name, k: isStatic ? "static" : "operation", m: opName, self, a: args,
          n: declared(definition.arguments), mut: resolve(returnType).idlType === "undefined",
          p: resolve(returnType).generic === "Promise",
        }, values);
        return fromLibrary(returnType, result);
      }));
    }

    for (const m of members) {
      if (m.type === "attribute" && resolve(m.idlType).idlType === "Function") {
        // One function for the interface, as the Standard of the queuing
        // strategies specifies: it calls the function of the library with
        // the same name.
        const fn = function (...values) {
          return decodeAny(call({ i: name, k: "static", m: m.name, a: values.map(encodeAny) }));
        };
        Object.defineProperty(fn, "name", { value: m.name });
        Object.defineProperty(fn, "length", { value: 1 });
        Object.defineProperty(cls.prototype, m.name, {
          get: function () { handleOf(this, name, m.name); return fn; },
          enumerable: true,
          configurable: true,
        });
        continue;
      }
      if (m.type === "attribute") {
        const descriptor = {
          get: promiseSteps(m.idlType, function () {
            const self = m.special === "static" ? null : { $h: handleOf(this, name, m.name) };
            return fromLibrary(m.idlType, call({ i: name, k: "getter", m: m.name, self }));
          }),
          enumerable: true,
          configurable: true,
        };
        if (!m.readonly) {
          descriptor.set = function (value) {
            const self = { $h: handleOf(this, name, m.name) };
            call({ i: name, k: "setter", m: m.name, self, a: [convert(m.idlType, value, m.extAttrs || [])] });
          };
        }
        Object.defineProperty(m.special === "static" ? cls : cls.prototype, m.name, descriptor);
      }

      if (m.special === "stringifier" || (m.type === "attribute" && m.special === "stringifier")) {
        defineMethod(cls.prototype, "toString", 0, function () {
          return fromLibrary({ idlType: "DOMString" }, call({ i: name, k: "stringify", self: { $h: handleOf(this, name, "toString") } }));
        });
      }

      if (m.type === "iterable" && m.idlType.length === 2) {
        const [keyType, valueType] = m.idlType;
        for (const kind of ["entries", "keys", "values"]) {
          defineMethod(cls.prototype, kind, 0, function () {
            handleOf(this, name, kind);
            return makeIterator(this, name, keyType, valueType, kind);
          });
        }
        defineMethod(cls.prototype, "forEach", 1, function (callback, thisArg = undefined) {
          handleOf(this, name, "forEach");
          if (typeof callback !== "function") throw new TypeError("The callback of forEach is not a function.");
          const iterator = makeIterator(this, name, keyType, valueType, "entries");
          for (let step = iterator.next(); !step.done; step = iterator.next()) {
            callback.call(thisArg, step.value[1], step.value[0], this);
          }
        });
        Object.defineProperty(cls.prototype, Symbol.iterator, {
          value: cls.prototype.entries, writable: true, configurable: true,
        });
      }
    }

    // An async iterable: `values()` and `[Symbol.asyncIterator]()` call
    // the function `values` of the library. The steps of the iterator are
    // steps of the Standard of the interface, thus of the library.
    for (const m of members) {
      if (m.type === "async_iterable") {
        defineMethod(cls.prototype, "values", 0, function (...values) {
          const self = { $h: handleOf(this, name, "values") };
          const args = convertArguments(name, "values", m.arguments || [], values);
          return decodeAny(call({ i: name, k: "operation", m: "values", self, a: args, n: (m.arguments || []).length }));
        });
        Object.defineProperty(cls.prototype, Symbol.asyncIterator, {
          value: cls.prototype.values, writable: true, configurable: true,
        });
      }
    }

    Object.defineProperty(cls.prototype, Symbol.toStringTag, { value: name, configurable: true });
    return cls;
  }

  globalThis.__webidl = { install, makeError };
})();
