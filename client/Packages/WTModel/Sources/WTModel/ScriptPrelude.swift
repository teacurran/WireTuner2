import Foundation

// DATA-011: the JavaScript side of the sandbox and of the `wt` API.  Native functions live on the
// hidden `__wt` object (installed from Swift, `ScriptContext` and `ScriptEnvironment`); this
// prelude wraps them in the objects scripts use: `console`, `setTimeout`, `wt.document` with
// proxies whose property sets are document changes, `wt.fetch`, `wt.records` and `wt.ui`.

enum ScriptPrelude {
    /// The sandbox: `console`, `setTimeout`/`clearTimeout`, stubs that fail with the documented
    /// error for what a script may not use, and allocation guards for the memory limit.
    static func sandbox(memoryLimit: Int) -> String {
        """
        (function () {
          "use strict";
          const host = globalThis.__wt;
          const show = function (value) {
            if (typeof value === "string") return value;
            try { const s = JSON.stringify(value); return s === undefined ? String(value) : s; } catch (e) { return String(value); }
          };
          globalThis.console = {
            log: function () { host.log("log", Array.prototype.map.call(arguments, show).join(" ")); },
            warn: function () { host.log("warn", Array.prototype.map.call(arguments, show).join(" ")); },
            error: function () { host.log("error", Array.prototype.map.call(arguments, show).join(" ")); },
            table: function (rows) { host.log("table", show(rows)); }
          };
          globalThis.setTimeout = function (fn, ms) {
            if (typeof fn !== "function") throw new TypeError("setTimeout needs a function");
            const args = Array.prototype.slice.call(arguments, 2);
            return host.setTimeout(function () { fn.apply(null, args); }, Number(ms) || 0);
          };
          globalThis.clearTimeout = function (id) { host.clearTimeout(Number(id) || 0); };
          const denied = function (name) {
            return function () {
              const error = new Error(name + " is not available in WireTuner scripts: scripts have no file system, shell or network; use wt.fetch for web requests and wt.ui.openFile for files");
              error.name = "SandboxError";
              throw error;
            };
          };
          for (const name of ["require", "XMLHttpRequest", "WebSocket", "fetch", "importScripts", "EventSource", "Worker", "setInterval"]) {
            Object.defineProperty(globalThis, name, { value: denied(name), writable: false, configurable: false });
          }
          const limit = \(memoryLimit);
          const tooLarge = function (bytes) {
            if (bytes > limit) {
              const error = new RangeError("ScriptMemoryLimit: an allocation of " + bytes + " bytes is over the script memory limit");
              throw error;
            }
          };
          const NativeArrayBuffer = globalThis.ArrayBuffer;
          const GuardedArrayBuffer = function (length) {
            tooLarge(Number(length) || 0);
            return new NativeArrayBuffer(length);
          };
          GuardedArrayBuffer.prototype = NativeArrayBuffer.prototype;
          GuardedArrayBuffer.isView = NativeArrayBuffer.isView;
          globalThis.ArrayBuffer = GuardedArrayBuffer;
          for (const name of ["Int8Array", "Uint8Array", "Uint8ClampedArray", "Int16Array", "Uint16Array", "Int32Array", "Uint32Array", "Float32Array", "Float64Array", "BigInt64Array", "BigUint64Array"]) {
            const Native = globalThis[name];
            if (!Native) continue;
            const Guarded = function (arg, offset, length) {
              if (typeof arg === "number") tooLarge(arg * Native.BYTES_PER_ELEMENT);
              if (arguments.length === 0) return new Native();
              if (arguments.length === 1) return new Native(arg);
              return new Native(arg, offset, length);
            };
            Guarded.prototype = Native.prototype;
            Guarded.BYTES_PER_ELEMENT = Native.BYTES_PER_ELEMENT;
            Guarded.from = Native.from.bind(Native);
            Guarded.of = Native.of.bind(Native);
            globalThis[name] = Guarded;
          }
          const repeat = String.prototype.repeat;
          String.prototype.repeat = function (count) {
            tooLarge(this.length * 2 * (Number(count) || 0));
            return repeat.call(this, count);
          };
          const NativeArray = globalThis.Array;
          const fill = NativeArray.prototype.fill;
          NativeArray.prototype.fill = function () {
            tooLarge(this.length * 8);
            return fill.apply(this, arguments);
          };
          delete globalThis.SharedArrayBuffer;
        })();
        """
    }

    /// `wt`: the document API over the natives `ScriptEnvironment` installs.
    static let api = """
    (function () {
      "use strict";
      const host = globalThis.__wt;
      const cache = new Map();
      const methods = {
        duplicate: function (id) { return function () { return wrap(host.call(id, "duplicate", null)); }; },
        remove: function (id) { return function () { host.call(id, "remove", null); }; },
        moveTo: function (id) { return function (layer) { host.call(id, "moveTo", layer && layer.id !== undefined ? layer.id : String(layer)); }; },
        bringToFront: function (id) { return function () { host.call(id, "bringToFront", null); }; },
        sendToBack: function (id) { return function () { host.call(id, "sendToBack", null); }; }
      };
      const wrap = function (id) {
        if (id === null || id === undefined) return null;
        if (cache.has(id)) return cache.get(id);
        const proxy = new Proxy({ id: id }, {
          get: function (target, property) {
            if (property === "id") return id;
            if (property === "toString") return function () { return "[WireTuner " + host.get(id, "kind") + " " + id + "]"; };
            if (property === "toJSON") return function () { return { id: id, kind: host.get(id, "kind"), name: host.get(id, "name") }; };
            if (typeof property !== "string") return undefined;
            if (Object.prototype.hasOwnProperty.call(methods, property)) return methods[property](id);
            const value = host.get(id, property);
            if (property === "layer" || property === "page") return wrap(value);
            return value;
          },
          set: function (target, property, value) {
            if (value && typeof value === "object" && value.id !== undefined && (property === "layer" || property === "page")) value = value.id;
            host.set(id, String(property), value === undefined ? null : value);
            return true;
          }
        });
        cache.set(id, proxy);
        return proxy;
      };
      const list = function (name) { return host.list(name).map(wrap); };
      const matches = function (object, filter) {
        for (const key of Object.keys(filter || {})) {
          let wanted = filter[key];
          let actual = object[key];
          if (wanted && typeof wanted === "object" && wanted.id !== undefined) wanted = wanted.id;
          if (actual && typeof actual === "object" && actual.id !== undefined) {
            if (typeof wanted === "string" && wanted !== actual.id && wanted !== actual.name) return false;
            continue;
          }
          if (actual !== wanted) return false;
        }
        return true;
      };
      const collection = function (items) {
        items.where = function (filter) { return collection(items.filter(function (o) { return matches(o, filter); })); };
        return items;
      };
      const document = {
        get name() { return host.docName(); },
        get pages() { return collection(list("pages")); },
        get masterPages() { return collection(list("masterPages")); },
        get layers() { return collection(list("layers")); },
        get objects() { return collection(list("objects")); },
        get swatches() { return collection(list("swatches")); },
        get styles() { return collection(list("styles")); },
        get scripts() { return collection(list("scripts")); },
        get fields() { return host.fields(); },
        get dataSources() { return host.sources(); },
        get selection() { return list("selection"); },
        set selection(objects) { host.setSelection((objects || []).map(function (o) { return o && o.id !== undefined ? o.id : String(o); })); },
        addField: function (name, type) { return host.addField(String(name), String(type || "text")); },
        transaction: function (label, fn) {
          if (typeof fn !== "function") throw new TypeError("transaction needs a label and a function");
          host.begin(String(label));
          try { return fn(); } finally { host.end(); }
        },
        createRectangle: function (options) { return wrap(host.create("rectangle", options || {})); },
        createEllipse: function (options) { return wrap(host.create("ellipse", options || {})); },
        createLine: function (options) { return wrap(host.create("line", options || {})); },
        createText: function (options) { return wrap(host.create("text", options || {})); },
        createBarcode: function (options) { return wrap(host.create("barcode", options || {})); },
        placeImage: function () { return wrap(host.create("image", {})); },
        export: function (options) { return host.exportDocument(options || {}); },
        print: function (preset) { return host.printDocument(preset === undefined ? null : String(preset)); }
      };
      const Response = function (raw) {
        this.status = raw.status;
        this.ok = raw.status >= 200 && raw.status < 300;
        this.headers = raw.headers;
        const body = raw.body;
        this.text = function () { return Promise.resolve(body); };
        this.json = function () { return Promise.resolve(JSON.parse(body)); };
      };
      const fetch = function (url, options) {
        try {
          return Promise.resolve(new Response(host.fetch(String(url), options || {})));
        } catch (error) {
          return Promise.reject(error);
        }
      };
      const progress = function (title) {
        host.ui("progress", [String(title || "")]);
        return {
          update: function (fraction, text) { host.progress(Number(fraction) || 0, text === undefined ? "" : String(text)); },
          done: function () { host.ui("progressDone", []); }
        };
      };
      const ui = {
        alert: function (message) { return host.ui("alert", [String(message)]); },
        confirm: function (message) { return host.ui("confirm", [String(message)]) === true; },
        prompt: function (message, text) { return host.ui("prompt", [String(message), text === undefined ? "" : String(text)]); },
        choose: function (message, choices) { return host.ui("choose", [String(message), (choices || []).map(String)]); },
        openFile: function (options) { return host.ui("openFile", [options || {}]); },
        saveFile: function (options) {
          const token = host.ui("saveFile", [options || {}]);
          if (token === null || token === undefined) return null;
          return { write: function (text) { host.ui("write", [token, String(text)]); } };
        },
        progress: progress
      };
      const records = {
        all: function () { return host.records("all"); },
        current: function () { const record = host.records("current"); return record === undefined ? null : record; },
        get fields() { return host.fields(); },
        merge: function (options) { return host.ui("merge", [options || {}]); }
      };
      Object.defineProperty(globalThis, "wt", { value: Object.freeze({ document: document, fetch: fetch, ui: ui, records: records, documents: [document] }), writable: false });
    })();
    """
}
