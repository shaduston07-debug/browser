import UIKit
import WebKit

// MARK: - Patching installed extensions

/// Adds Inkwell's Chrome compatibility layer to an unpacked extension: the script itself, the
/// `nativeMessaging` permission it uses to reach the app, and hooks into the background worker
/// and every HTML page so it loads before the extension's own code. Safe to run repeatedly.
enum ExtensionPatcher {
    static let compatFileName = "__inkwell_compat.js"
    static let workerWrapperName = "__inkwell_sw.js"
    static let pageShimFileName = "__inkwell_page.js"
    static let bridgeFileName = "__inkwell_bridge.js"
    static let keepAlivePageName = "__inkwell_keepalive.html"
    static let backgroundPageName = "__inkwell_background.html"
    static let workerShimName = "__inkwell_worker_shim.js"
    static let redirectPageName = "__inkwell_redirect.html"
    static let redirectScriptName = "__inkwell_redirect.js"
    static let keepAliveScriptName = "__inkwell_keepalive.js"

    static func patch(_ root: URL, storeID: String?) {
        let fm = FileManager.default
        let manifestURL = root.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: manifestURL),
              var manifest = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }

        // 1. The compatibility script (rewritten every time so updates take effect).
        let meta: [String: Any] = ["storeID": storeID ?? "", "version": 2, "apiRefs": scanAPIReferences(in: root)]
        let metaJSON = (try? JSONSerialization.data(withJSONObject: meta)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        let script = "globalThis.__INKWELL__ = \(metaJSON);\n" + compatScript
        try? script.write(to: root.appendingPathComponent(compatFileName), atomically: true, encoding: .utf8)

        // Hidden page that keeps the background worker (and its connections) alive.
        let keepAliveHTML = "<!doctype html><html><head><script src=\"/\(compatFileName)\"></script>"
            + "<script src=\"/\(keepAliveScriptName)\"></script></head><body></body></html>"
        try? keepAliveHTML.write(to: root.appendingPathComponent(keepAlivePageName), atomically: true, encoding: .utf8)
        try? keepAliveScript.write(to: root.appendingPathComponent(keepAliveScriptName), atomically: true, encoding: .utf8)
        try? workerShimScript.write(to: root.appendingPathComponent(workerShimName), atomically: true, encoding: .utf8)
        let redirectHTML = "<!doctype html><html><head><meta charset=\"utf-8\"><title>Signing in…</title>"
            + "<script src=\"/\(compatFileName)\"></script><script src=\"/\(redirectScriptName)\" defer></script>"
            + "<style>body{font:17px -apple-system,sans-serif;color:#888;display:flex;align-items:center;"
            + "justify-content:center;height:90vh;margin:0}@media(prefers-color-scheme:dark){body{background:#1c1c1e}}</style>"
            + "</head><body><p id=\"status\">Finishing sign-in…</p></body></html>"
        try? redirectHTML.write(to: root.appendingPathComponent(redirectPageName), atomically: true, encoding: .utf8)
        try? redirectScript.write(to: root.appendingPathComponent(redirectScriptName), atomically: true, encoding: .utf8)

        var changed = false

        // 2. Permission for runtime.sendNativeMessage.
        var permissions = manifest["permissions"] as? [Any] ?? []
        if !permissions.contains(where: { ($0 as? String) == "nativeMessaging" }) {
            permissions.append("nativeMessaging")
            manifest["permissions"] = permissions
            changed = true
        }
        // WebKit only knows "declarativeNetRequest"; Chrome's host-access variant would leave the API missing.
        if permissions.contains(where: { ($0 as? String) == "declarativeNetRequestWithHostAccess" }),
           !permissions.contains(where: { ($0 as? String) == "declarativeNetRequest" }) {
            permissions.append("declarativeNetRequest")
            manifest["permissions"] = permissions
            changed = true
        }

        // 3. Load the layer before the background code.
        if var background = manifest["background"] as? [String: Any] {
            // iPad apps can't run service workers (WebKit needs an Apple-only entitlement for that),
            // so a Chrome "service_worker" background runs as a background page instead.
            if let worker = background["service_worker"] as? String {
                let isModule = (background["type"] as? String) == "module"
                let scriptType = isModule ? "module" : "text/javascript"
                let page = "<!doctype html><html><head><meta charset=\"utf-8\">"
                    + "<script src=\"/\(compatFileName)\"></script>"
                    + "<script src=\"/\(workerShimName)\"></script>"
                    + "<script type=\"\(scriptType)\" src=\"/\(worker)\"></script>"
                    + "</head><body></body></html>"
                try? page.write(to: root.appendingPathComponent(backgroundPageName), atomically: true, encoding: .utf8)
                background = ["page": backgroundPageName, "persistent": false]
                changed = true
            }
            if var scripts = background["scripts"] as? [String], scripts.first != compatFileName {
                scripts.insert(compatFileName, at: 0)
                background["scripts"] = scripts
                changed = true
            }
            manifest["background"] = background
        }

        // 4. Websites in "externally_connectable" get chrome.runtime.sendMessage(<Chrome ID>) support.
        if let storeID, ChromeWebStore.isExtensionID(storeID),
           let connectable = manifest["externally_connectable"] as? [String: Any],
           let matches = connectable["matches"] as? [String], !matches.isEmpty {
            try? pageShimScript.replacingOccurrences(of: "__STORE_ID__", with: storeID)
                .write(to: root.appendingPathComponent(pageShimFileName), atomically: true, encoding: .utf8)
            try? bridgeScript.replacingOccurrences(of: "__STORE_ID__", with: storeID)
                .write(to: root.appendingPathComponent(bridgeFileName), atomically: true, encoding: .utf8)

            var contentScripts = manifest["content_scripts"] as? [[String: Any]] ?? []
            let alreadyAdded = contentScripts.contains { ($0["js"] as? [String])?.contains(bridgeFileName) == true }
            if !alreadyAdded {
                contentScripts.insert(["matches": matches, "js": [pageShimFileName], "run_at": "document_start", "world": "MAIN"], at: 0)
                contentScripts.insert(["matches": matches, "js": [bridgeFileName], "run_at": "document_start"], at: 1)
                manifest["content_scripts"] = contentScripts

                var resources = manifest["web_accessible_resources"] as? [Any] ?? []
                resources.append(["resources": [pageShimFileName], "matches": matches])
                manifest["web_accessible_resources"] = resources
                changed = true
            }
        }

        if changed, let out = try? JSONSerialization.data(withJSONObject: manifest,
                                                         options: [.prettyPrinted, .withoutEscapingSlashes]) {
            try? out.write(to: manifestURL, options: .atomic)
        }

        // 5. Every extension page (popup, options, side panel, background page…).
        let tag = "<script src=\"/\(compatFileName)\"></script>"
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: nil) else { return }
        for case let file as URL in enumerator where ["html", "htm"].contains(file.pathExtension.lowercased()) {
            guard var html = try? String(contentsOf: file, encoding: .utf8), !html.contains(compatFileName) else { continue }
            if let head = html.range(of: "<head[^>]*>", options: [.regularExpression, .caseInsensitive]) {
                html.insert(contentsOf: tag, at: head.upperBound)
            } else if let htmlTag = html.range(of: "<html[^>]*>", options: [.regularExpression, .caseInsensitive]) {
                html.insert(contentsOf: tag, at: htmlTag.upperBound)
            } else {
                html = tag + html
            }
            try? html.write(to: file, atomically: true, encoding: .utf8)
        }
    }

    /// Every chrome.<api>.<member>[.<sub>] the extension's code mentions, so the compatibility
    /// layer can stand in for the ones WebKit doesn't implement.
    static func scanAPIReferences(in root: URL) -> [String] {
        guard let regex = try? NSRegularExpression(
            pattern: #"(?<![\w$.])(?:chrome|browser)\.([a-zA-Z]+)\.([a-zA-Z_]+)(?:\.([A-Za-z_]+))?"#) else { return [] }
        var refs = Set<String>()
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return [] }
        for case let file as URL in enumerator
        where file.pathExtension == "js" && !file.lastPathComponent.hasPrefix("__inkwell") {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let range = NSRange(text.startIndex..., in: text)
            regex.enumerateMatches(in: text, range: range) { match, _, _ in
                guard let match else { return }
                var parts: [String] = []
                for group in 1...3 {
                    let r = match.range(at: group)
                    if r.location != NSNotFound, let swiftRange = Range(r, in: text) { parts.append(String(text[swiftRange])) }
                }
                refs.insert(parts.joined(separator: "."))
            }
            if refs.count > 3000 { break }
        }
        return refs.sorted()
    }

    static let compatScript = #"""
// Inkwell Browser — Chrome compatibility layer.
// Added to every installed extension (background + pages). Fills in Chrome-only APIs that
// WebKit's extension engine doesn't provide, emulating them in JS or forwarding to the app.
(() => {
  "use strict";
  const g = globalThis;
  if (g.__inkwellCompatInstalled) return;
  g.__inkwellCompatInstalled = true;

  const chromeAPI = g.chrome || g.browser;
  if (!chromeAPI || !chromeAPI.runtime) return;
  const promiseAPI = g.browser || g.chrome;
  const META = g.__INKWELL__ || {};
  const APP_ID = "com.mangashaduston.inkwellbrowser";
  const namespaces = [g.chrome, g.browser].filter((ns, i, all) => ns && all.indexOf(ns) === i);

  // ---------- helpers ----------

  const define = (obj, name, value) => {
    if (!obj) return undefined;
    try { if (obj[name] === undefined) obj[name] = value; } catch (e) { /* read-only */ }
    try {
      if (obj[name] === undefined) {
        Object.defineProperty(obj, name, { value, configurable: true, enumerable: true, writable: true });
      }
    } catch (e) { /* not extensible */ }
    return obj[name];
  };

  const makeEvent = () => {
    const listeners = new Set();
    return {
      addListener: (f) => { listeners.add(f); },
      removeListener: (f) => { listeners.delete(f); },
      hasListener: (f) => listeners.has(f),
      hasListeners: () => listeners.size > 0,
      _dispatch: (...args) => listeners.forEach((f) => {
        try { f(...args); } catch (e) { console.error(e); }
      }),
    };
  };

  const setLastError = (err) => {
    try {
      Object.defineProperty(chromeAPI.runtime, "lastError", {
        value: err ? { message: String((err && err.message) || err) } : undefined,
        configurable: true,
      });
    } catch (e) { /* ignore */ }
  };

  // Chrome APIs return promises and also accept a trailing callback.
  const wrap = (fn) => function (...args) {
    const callback = typeof args[args.length - 1] === "function" ? args.pop() : null;
    let promise;
    try { promise = Promise.resolve(fn(...args)); } catch (e) { promise = Promise.reject(e); }
    if (!callback) return promise;
    promise.then(
      (value) => { setLastError(null); callback(value); },
      (error) => { setLastError(error); try { callback(); } finally { setLastError(null); } },
    );
    return undefined;
  };

  // Talks to the Inkwell app through runtime.sendNativeMessage.
  const native = (command, args) => new Promise((resolve, reject) => {
    const message = { inkwell: command, args: args || {} };
    const done = (reply) => {
      if (reply && reply.ok) resolve(reply.value === null ? undefined : reply.value);
      else reject(new Error((reply && reply.error) || "Inkwell Browser could not run " + command));
    };
    try {
      if (g.browser && g.browser.runtime && g.browser.runtime.sendNativeMessage) {
        g.browser.runtime.sendNativeMessage(APP_ID, message).then(done, reject);
      } else {
        chromeAPI.runtime.sendNativeMessage(APP_ID, message, (reply) => {
          const err = chromeAPI.runtime.lastError;
          if (err) reject(new Error(err.message)); else done(reply);
        });
      }
    } catch (e) { reject(e); }
  });

  const manifest = (() => { try { return chromeAPI.runtime.getManifest() || {}; } catch (e) { return {}; } })();

  // ---------- diagnostics: forward console output to Inkwell's Extension Console ----------

  const isBackground = (() => {
    try {
      if (typeof document === "undefined") return true; // service worker
      return g.location && g.location.pathname === "/__inkwell_background.html";
    } catch (e) { return false; }
  })();
  const where = (() => { try { return (g.location && g.location.pathname) || "background"; } catch (e) { return "?"; } })();
  let logBudget = 300;
  setInterval(() => { logBudget = 300; }, 60000);
  const describeArg = (a) => {
    try {
      if (typeof a === "string") return a;
      if (a instanceof Error) return a.stack || a.message;
      if (a && typeof a === "object" && "message" in a && "name" in a) return a.name + ": " + a.message;
      return JSON.stringify(a);
    } catch (e) { return String(a); }
  };
  const sendLog = (level, args) => {
    if (logBudget-- <= 0) return;
    const text = Array.from(args).map(describeArg).join(" ").slice(0, 2000);
    native("log", { level, text, where }).catch(() => {});
  };
  for (const level of ["error", "warn", "info", "log"]) {
    const original = console[level];
    if (typeof original !== "function") continue;
    console[level] = function (...args) {
      try { sendLog(level, args); } catch (e) { /* ignore */ }
      return original.apply(this, args);
    };
  }
  try {
    g.addEventListener("error", (e) => sendLog("error", ["Uncaught " + (e.message || "error") + " @ " + (e.filename || "") + ":" + (e.lineno || 0)]));
    g.addEventListener("unhandledrejection", (e) => sendLog("error", ["Unhandled rejection:", e.reason]));
  } catch (e) { /* no event target */ }

  // WebSockets: for store extensions, connect through the app (runtime.connectNative) so the
  // connection carries Chrome's Origin (chrome-extension://<id>); servers reject WebKit's origin.
  const redactURL = (u) => String(u).replace(/([?&](token|key|auth)[^=]*=)[^&]+/gi, "$1…");
  const toBase64 = (bytes) => {
    let binary = "";
    for (let i = 0; i < bytes.length; i += 0x8000) binary += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000));
    return btoa(binary);
  };
  const fromBase64 = (b64) => {
    const binary = atob(b64);
    const bytes = new Uint8Array(binary.length);
    for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
    return bytes;
  };

  const NativeWebSocket = g.WebSocket;
  const canProxy = !!(META.storeID && chromeAPI.runtime && typeof chromeAPI.runtime.connectNative === "function" && typeof g.EventTarget === "function");

  if (typeof NativeWebSocket === "function" && !NativeWebSocket.__inkwell && canProxy) {
    class ProxiedWebSocket extends EventTarget {
      constructor(url, protocols) {
        super();
        this.url = String(url);
        this.readyState = 0;
        this.protocol = "";
        this.extensions = "";
        this.bufferedAmount = 0;
        this.binaryType = "blob";
        this.onopen = null; this.onmessage = null; this.onerror = null; this.onclose = null;
        sendLog("info", ["WebSocket (via app) connecting: " + redactURL(this.url)]);
        try {
          this._port = chromeAPI.runtime.connectNative(APP_ID);
          this._port.onMessage.addListener((m) => this._handle(m));
          this._port.onDisconnect.addListener(() => { if (this.readyState < 3) this._finish(1006, "app connection closed", false); });
          this._port.postMessage({ inkwell: "ws.open", url: this.url, protocols: protocols == null ? [] : [].concat(protocols) });
        } catch (e) {
          sendLog("error", ["connectNative failed: " + (e && e.message)]);
          setTimeout(() => { this._emit("error", new Event("error")); this._finish(1006, "connectNative failed", false); }, 0);
        }
      }
      _emit(type, event) {
        const handler = this["on" + type];
        if (typeof handler === "function") { try { handler.call(this, event); } catch (e) { console.error(e); } }
        this.dispatchEvent(event);
      }
      _finish(code, reason, wasClean) {
        if (this.readyState === 3) return;
        this.readyState = 3;
        let event;
        try { event = new CloseEvent("close", { code, reason, wasClean }); }
        catch (e) { event = new Event("close"); event.code = code; event.reason = reason; event.wasClean = wasClean; }
        this._emit("close", event);
        try { this._port && this._port.disconnect(); } catch (e) { /* already closed */ }
      }
      _handle(m) {
        if (!m || typeof m !== "object") return;
        if (m.type === "open") {
          this.readyState = 1;
          this.protocol = m.protocol || "";
          this._emit("open", new Event("open"));
        } else if (m.type === "message") {
          let data = m.text;
          if (m.base64 != null) {
            const bytes = fromBase64(m.base64);
            data = this.binaryType === "arraybuffer" ? bytes.buffer : new Blob([bytes]);
          }
          this._emit("message", new MessageEvent("message", { data, origin: this.url }));
        } else if (m.type === "error") {
          this._emit("error", new Event("error"));
        } else if (m.type === "close") {
          this._finish(m.code || 1006, m.reason || "", !!m.wasClean);
        }
      }
      send(data) {
        if (this.readyState === 0) throw new DOMException("Still in CONNECTING state.", "InvalidStateError");
        if (this.readyState !== 1) return;
        if (typeof data === "string") { this._port.postMessage({ inkwell: "ws.send", text: data }); return; }
        if (data instanceof Blob) {
          data.arrayBuffer().then((buf) => this._port.postMessage({ inkwell: "ws.send", base64: toBase64(new Uint8Array(buf)) }));
          return;
        }
        const bytes = data instanceof ArrayBuffer ? new Uint8Array(data) : new Uint8Array(data.buffer, data.byteOffset, data.byteLength);
        this._port.postMessage({ inkwell: "ws.send", base64: toBase64(bytes) });
      }
      close(code, reason) {
        if (this.readyState >= 2) return;
        this.readyState = 2;
        try { this._port.postMessage({ inkwell: "ws.close", code: code || 1000, reason: reason || "" }); }
        catch (e) { this._finish(code || 1000, reason || "", true); }
      }
    }
    for (const [k, v] of [["CONNECTING", 0], ["OPEN", 1], ["CLOSING", 2], ["CLOSED", 3]]) {
      ProxiedWebSocket[k] = v;
      ProxiedWebSocket.prototype[k] = v;
    }
    ProxiedWebSocket.__inkwell = true;
    g.WebSocket = ProxiedWebSocket;
  } else if (typeof NativeWebSocket === "function" && !NativeWebSocket.__inkwell) {
    // Not proxied: just log the lifecycle so connection problems are visible.
    const Wrapped = function (url, protocols) {
      const ws = protocols === undefined ? new NativeWebSocket(url) : new NativeWebSocket(url, protocols);
      const label = redactURL(url);
      sendLog("info", ["WebSocket connecting: " + label]);
      ws.addEventListener("open", () => sendLog("info", ["WebSocket open: " + label]));
      ws.addEventListener("close", (e) => sendLog("warn", ["WebSocket closed: " + label + " (code " + e.code + (e.reason ? ", " + e.reason : "") + ")"]));
      ws.addEventListener("error", () => sendLog("error", ["WebSocket error: " + label]));
      return ws;
    };
    Wrapped.prototype = NativeWebSocket.prototype;
    for (const k of ["CONNECTING", "OPEN", "CLOSING", "CLOSED"]) Wrapped[k] = NativeWebSocket[k];
    Wrapped.__inkwell = true;
    g.WebSocket = Wrapped;
  }

  sendLog("info", ["Inkwell compatibility layer loaded"]);

  // ---------- chrome.sidePanel ----------

  const sidePanelPath = () => (manifest.side_panel && manifest.side_panel.default_path) || "";
  const sidePanel = {
    open: wrap(async (options) => {
      try {
        return await native("sidePanel.open", options || {});
      } catch (e) {
        // Fallback: show the panel page in a tab.
        const path = sidePanelPath();
        if (!path) throw e;
        await promiseAPI.tabs.create({ url: chromeAPI.runtime.getURL(path) });
        return undefined;
      }
    }),
    close: wrap((options) => native("sidePanel.close", options || {})),
    setOptions: wrap((options) => native("sidePanel.setOptions", options || {})),
    getOptions: wrap((options) => native("sidePanel.getOptions", options || {})),
    setPanelBehavior: wrap((behavior) => native("sidePanel.setPanelBehavior", behavior || {})),
    getPanelBehavior: wrap(() => native("sidePanel.getPanelBehavior", {})),
    onOpened: makeEvent(),
    onClosed: makeEvent(),
  };

  // ---------- chrome.debugger (Chrome DevTools Protocol emulation) ----------

  const runInTab = async (tabId, func, args) => {
    const options = { target: { tabId }, func, args: args || [] };
    let results;
    try {
      results = await promiseAPI.scripting.executeScript(Object.assign({ world: "MAIN" }, options));
    } catch (e) {
      results = await promiseAPI.scripting.executeScript(options);
    }
    const first = results && results[0];
    if (first && first.error) throw new Error(String(first.error));
    return first ? first.result : undefined;
  };

  // The page* functions below are serialized and run inside the web page.
  function pageEvaluate(expression, awaitPromise) {
    const describe = (v) => {
      if (v === null) return { type: "object", subtype: "null", value: null };
      const type = typeof v;
      if (type === "undefined") return { type };
      if (type === "function") return { type, description: String(v).slice(0, 200) };
      if (v instanceof Element) return { type: "object", subtype: "node", description: v.tagName.toLowerCase() };
      try { return { type, value: JSON.parse(JSON.stringify(v)) }; } catch (e) { return { type, description: String(v) }; }
    };
    const failure = (e) => ({
      result: { type: "object", subtype: "error", description: String((e && e.stack) || e) },
      exceptionDetails: { text: String((e && e.message) || e), exception: { description: String(e) } },
    });
    try {
      const value = (0, eval)(expression);
      if (awaitPromise && value && typeof value.then === "function") {
        return value.then((v) => ({ result: describe(v) }), failure);
      }
      return { result: describe(value) };
    } catch (e) {
      return failure(e);
    }
  }

  function pageMouse(p) {
    const x = p.x || 0;
    const y = p.y || 0;
    const el = document.elementFromPoint(x, y) || document.body;
    const buttonIndex = { left: 0, middle: 1, right: 2 }[p.button] ?? 0;
    const mods = p.modifiers || 0;
    const init = {
      bubbles: true, cancelable: true, composed: true, view: window,
      clientX: x, clientY: y, screenX: x, screenY: y,
      button: buttonIndex, buttons: p.type === "mousePressed" ? (1 << buttonIndex) : 0,
      detail: p.clickCount || 1,
      altKey: !!(mods & 1), ctrlKey: !!(mods & 2), metaKey: !!(mods & 4), shiftKey: !!(mods & 8),
      pointerId: 1, pointerType: "mouse", isPrimary: true,
      deltaX: p.deltaX || 0, deltaY: p.deltaY || 0,
    };
    const PointerCtor = window.PointerEvent || MouseEvent;
    const fire = (type, Ctor) => el.dispatchEvent(new Ctor(type, init));
    switch (p.type) {
      case "mouseMoved":
        fire("pointermove", PointerCtor);
        fire("mousemove", MouseEvent);
        fire("mouseover", MouseEvent);
        break;
      case "mousePressed":
        fire("pointerdown", PointerCtor);
        if (fire("mousedown", MouseEvent) && typeof el.focus === "function") el.focus();
        break;
      case "mouseReleased":
        fire("pointerup", PointerCtor);
        fire("mouseup", MouseEvent);
        if (buttonIndex === 2) {
          fire("contextmenu", MouseEvent);
        } else {
          fire("click", MouseEvent);
          if ((p.clickCount || 1) >= 2) fire("dblclick", MouseEvent);
        }
        break;
      case "mouseWheel": {
        let target = el;
        while (target && target !== document.body && target !== document.documentElement) {
          const style = getComputedStyle(target);
          const scrollable = /(auto|scroll)/.test(style.overflowY + style.overflowX);
          if (scrollable && (target.scrollHeight > target.clientHeight || target.scrollWidth > target.clientWidth)) break;
          target = target.parentElement;
        }
        fire("wheel", window.WheelEvent || MouseEvent);
        if (target && target !== document.body && target !== document.documentElement) {
          target.scrollBy(init.deltaX, init.deltaY);
        } else {
          window.scrollBy(init.deltaX, init.deltaY);
        }
        break;
      }
      default:
        break;
    }
    return {};
  }

  function pageKey(p) {
    const el = document.activeElement || document.body;
    const mods = p.modifiers || 0;
    const init = {
      key: p.key || "", code: p.code || "", bubbles: true, cancelable: true, composed: true,
      altKey: !!(mods & 1), ctrlKey: !!(mods & 2), metaKey: !!(mods & 4), shiftKey: !!(mods & 8),
      keyCode: p.windowsVirtualKeyCode || 0, which: p.windowsVirtualKeyCode || 0,
    };
    const editable = !!el && (el.isContentEditable || /^(INPUT|TEXTAREA)$/.test(el.tagName));
    if (p.type === "keyUp") {
      el.dispatchEvent(new KeyboardEvent("keyup", init));
      return {};
    }
    if (p.type !== "char" && !el.dispatchEvent(new KeyboardEvent("keydown", init))) return {};

    const text = p.text || (p.type === "char" ? p.key : "") || "";
    if (p.key === "Enter") {
      if (editable && (el.tagName === "TEXTAREA" || el.isContentEditable)) {
        document.execCommand("insertLineBreak");
      } else if (el.form) {
        if (typeof el.form.requestSubmit === "function") el.form.requestSubmit(); else el.form.submit();
      } else if (typeof el.click === "function" && el !== document.body) {
        el.click();
      }
    } else if (editable && p.key === "Backspace") {
      document.execCommand("delete");
    } else if (editable && p.key === "Delete") {
      document.execCommand("forwardDelete");
    } else if (editable && text && !(mods & 6)) {
      document.execCommand("insertText", false, text);
    } else if (!editable) {
      const scroll = { PageDown: innerHeight * 0.9, PageUp: -innerHeight * 0.9, ArrowDown: 40, ArrowUp: -40, " ": innerHeight * 0.9 };
      if (p.key in scroll) window.scrollBy(0, scroll[p.key]);
      if (p.key === "Home") window.scrollTo(0, 0);
      if (p.key === "End") window.scrollTo(0, document.documentElement.scrollHeight);
    }
    return {};
  }

  function pageInsertText(text) {
    const el = document.activeElement;
    if (!el || !(el.isContentEditable || /^(INPUT|TEXTAREA)$/.test(el.tagName))) return {};
    if (!document.execCommand("insertText", false, text) && "value" in el) {
      const start = el.selectionStart ?? el.value.length;
      const end = el.selectionEnd ?? start;
      el.value = el.value.slice(0, start) + text + el.value.slice(end);
      el.dispatchEvent(new Event("input", { bubbles: true }));
    }
    return {};
  }

  function pageMetrics() {
    const d = document.documentElement;
    const vv = window.visualViewport;
    const layout = { pageX: scrollX, pageY: scrollY, clientWidth: d.clientWidth, clientHeight: d.clientHeight };
    const visual = {
      offsetX: 0, offsetY: 0, pageX: scrollX, pageY: scrollY,
      clientWidth: vv ? vv.width : innerWidth, clientHeight: vv ? vv.height : innerHeight,
      scale: vv ? vv.scale : 1, zoom: 1,
    };
    const content = { x: 0, y: 0, width: d.scrollWidth, height: d.scrollHeight };
    return {
      layoutViewport: layout, visualViewport: visual, contentSize: content,
      cssLayoutViewport: layout, cssVisualViewport: visual, cssContentSize: content,
    };
  }

  const NO_OP_METHODS = new Set([
    "Runtime.enable", "Runtime.disable", "Runtime.runIfWaitingForDebugger",
    "Page.enable", "Page.disable", "Page.setLifecycleEventsEnabled", "Page.bringToFront",
    "DOM.enable", "DOM.disable", "CSS.enable", "CSS.disable", "Overlay.enable", "Overlay.disable",
    "Network.enable", "Network.disable", "Network.setCacheDisabled",
    "Log.enable", "Log.disable", "Debugger.enable", "Debugger.disable",
    "Accessibility.enable", "Accessibility.disable",
    "Emulation.setDeviceMetricsOverride", "Emulation.clearDeviceMetricsOverride",
    "Emulation.setFocusEmulationEnabled", "Emulation.setTouchEmulationEnabled",
    "Target.setAutoAttach", "Target.setDiscoverTargets",
  ]);

  const cdp = async (tabId, method, params) => {
    if (NO_OP_METHODS.has(method)) return {};
    switch (method) {
      case "Runtime.evaluate":
        return runInTab(tabId, pageEvaluate, [String(params.expression || ""), !!params.awaitPromise]);
      case "Runtime.callFunctionOn": {
        const args = JSON.stringify((params.arguments || []).map((a) => a.value));
        const expression = "(" + params.functionDeclaration + ").apply(document, " + args + ")";
        return runInTab(tabId, pageEvaluate, [expression, !!params.awaitPromise]);
      }
      case "Page.captureScreenshot": {
        const tab = await promiseAPI.tabs.get(tabId);
        const format = params.format === "jpeg" ? "jpeg" : "png";
        const dataURL = await promiseAPI.tabs.captureVisibleTab(tab.windowId, { format, quality: params.quality || 90 });
        return { data: String(dataURL).replace(/^data:[^,]*,/, "") };
      }
      case "Page.navigate":
        await promiseAPI.tabs.update(tabId, { url: params.url });
        return { frameId: String(tabId), loaderId: String(Date.now()) };
      case "Page.reload":
        await promiseAPI.tabs.reload(tabId, { bypassCache: !!params.ignoreCache });
        return {};
      case "Page.getLayoutMetrics":
        return runInTab(tabId, pageMetrics, []);
      case "Page.getFrameTree": {
        const tab = await promiseAPI.tabs.get(tabId);
        return { frameTree: { frame: { id: String(tabId), loaderId: "", url: tab.url || "", securityOrigin: "", mimeType: "text/html" }, childFrames: [] } };
      }
      case "Input.dispatchMouseEvent":
        return runInTab(tabId, pageMouse, [params]);
      case "Input.dispatchKeyEvent":
        return runInTab(tabId, pageKey, [params]);
      case "Input.insertText":
        return runInTab(tabId, pageInsertText, [String(params.text || "")]);
      default:
        throw new Error("Inkwell Browser can't emulate the Chrome DevTools command " + method);
    }
  };

  const attachedTabs = new Set();
  const debuggerAPI = {
    attach: wrap(async (target) => {
      if (!target || target.tabId == null) throw new Error("Inkwell Browser only supports tab debug targets");
      attachedTabs.add(target.tabId);
    }),
    detach: wrap(async (target) => { if (target) attachedTabs.delete(target.tabId); }),
    sendCommand: wrap(async (target, method, params) => {
      if (!target || target.tabId == null) throw new Error("Inkwell Browser only supports tab debug targets");
      return cdp(target.tabId, method, params || {});
    }),
    getTargets: wrap(async () => (await promiseAPI.tabs.query({})).map((t) => ({
      type: "page", id: String(t.id), tabId: t.id, title: t.title || "", url: t.url || "",
      attached: attachedTabs.has(t.id),
    }))),
    onEvent: makeEvent(),
    onDetach: makeEvent(),
  };

  // ---------- chrome.tabGroups: emulated, shared by all extension pages via storage.local ----------

  const GROUPS_KEY = "__inkwellTabGroups";
  let groupState = { next: 1, groups: {} };
  const localStore = promiseAPI.storage && promiseAPI.storage.local;
  const groupsReady = (async () => {
    try {
      const stored = await localStore.get(GROUPS_KEY);
      if (stored && stored[GROUPS_KEY] && stored[GROUPS_KEY].groups) groupState = stored[GROUPS_KEY];
    } catch (e) { /* no storage */ }
  })();
  try {
    promiseAPI.storage.onChanged.addListener((changes, area) => {
      if (area === "local" && changes[GROUPS_KEY] && changes[GROUPS_KEY].newValue) groupState = changes[GROUPS_KEY].newValue;
    });
  } catch (e) { /* no storage events */ }
  const saveGroups = () => { try { const p = localStore.set({ [GROUPS_KEY]: groupState }); if (p && p.catch) p.catch(() => {}); } catch (e) { /* ignore */ } };
  const groupOfTab = (tabId) => {
    for (const grp of Object.values(groupState.groups)) if (grp.tabIds.includes(tabId)) return grp.id;
    return -1;
  };
  const groupInfo = (grp) => ({ id: grp.id, title: grp.title || "", color: grp.color || "grey", collapsed: !!grp.collapsed, windowId: grp.windowId == null ? -1 : grp.windowId });
  const withGroup = (tab) => (tab && typeof tab === "object" && typeof tab.id === "number") ? Object.assign({}, tab, { groupId: groupOfTab(tab.id) }) : tab;
  const removeTabsFromGroups = (ids) => {
    let changed = false;
    for (const grp of Object.values(groupState.groups)) {
      const before = grp.tabIds.length;
      grp.tabIds = grp.tabIds.filter((t) => !ids.includes(t));
      if (grp.tabIds.length !== before) changed = true;
    }
    for (const [key, grp] of Object.entries(groupState.groups)) {
      if (!grp.tabIds.length) { delete groupState.groups[key]; tabGroups.onRemoved._dispatch(groupInfo(grp)); changed = true; }
    }
    return changed;
  };

  const tabGroups = {
    TAB_GROUP_ID_NONE: -1,
    Color: { GREY: "grey", BLUE: "blue", RED: "red", YELLOW: "yellow", GREEN: "green", PINK: "pink", PURPLE: "purple", CYAN: "cyan", ORANGE: "orange" },
    get: wrap(async (id) => {
      await groupsReady;
      const grp = groupState.groups[id];
      if (!grp) throw new Error("No group with id: " + id + ".");
      return groupInfo(grp);
    }),
    query: wrap(async (q) => {
      await groupsReady;
      const f = q || {};
      return Object.values(groupState.groups).map(groupInfo).filter((grp) =>
        (f.title === undefined || grp.title === f.title) && (f.color === undefined || grp.color === f.color) &&
        (f.collapsed === undefined || grp.collapsed === f.collapsed) && (f.windowId === undefined || f.windowId === -2 || grp.windowId === f.windowId));
    }),
    update: wrap(async (id, props) => {
      await groupsReady;
      const grp = groupState.groups[id];
      if (!grp) throw new Error("No group with id: " + id + ".");
      for (const k of ["title", "color", "collapsed"]) if (props && props[k] !== undefined) grp[k] = props[k];
      saveGroups();
      tabGroups.onUpdated._dispatch(groupInfo(grp));
      return groupInfo(grp);
    }),
    move: wrap(async (id, props) => {
      await groupsReady;
      const grp = groupState.groups[id];
      if (!grp) throw new Error("No group with id: " + id + ".");
      if (props && props.windowId != null) grp.windowId = props.windowId;
      saveGroups();
      tabGroups.onMoved._dispatch(groupInfo(grp));
      return groupInfo(grp);
    }),
    onCreated: makeEvent(), onUpdated: makeEvent(), onRemoved: makeEvent(), onMoved: makeEvent(),
  };

  const tabsGroup = wrap(async (options) => {
    await groupsReady;
    const o = options || {};
    const ids = [].concat(o.tabIds == null ? [] : o.tabIds);
    if (!ids.length) throw new Error("No tabs specified.");
    let grp = o.groupId != null ? groupState.groups[o.groupId] : null;
    if (o.groupId != null && !grp) throw new Error("No group with id: " + o.groupId + ".");
    let created = false;
    if (!grp) {
      let windowId = o.createProperties && o.createProperties.windowId;
      if (windowId == null) { try { windowId = (await promiseAPI.tabs.get(ids[0])).windowId; } catch (e) { windowId = -1; } }
      const id = groupState.next++;
      grp = groupState.groups[id] = { id, title: "", color: "grey", collapsed: false, windowId, tabIds: [] };
      created = true;
    }
    removeTabsFromGroups(ids);
    groupState.groups[grp.id] = grp;
    for (const t of ids) if (!grp.tabIds.includes(t)) grp.tabIds.push(t);
    saveGroups();
    if (created) tabGroups.onCreated._dispatch(groupInfo(grp));
    return grp.id;
  });
  const tabsUngroup = wrap(async (tabIds) => {
    await groupsReady;
    if (removeTabsFromGroups([].concat(tabIds == null ? [] : tabIds))) saveGroups();
  });

  // Chrome-only pages: chrome://newtab opens an ordinary new tab.
  const cleanTabURL = (props) => {
    if (props && typeof props.url === "string" && /^chrome:\/\/(newtab|new-tab-page)\/?$/i.test(props.url)) {
      const copy = Object.assign({}, props);
      delete copy.url;
      return copy;
    }
    return props;
  };

  const patchTabsAPI = (tabs) => {
    if (!tabs || tabs.__inkwellGroups) return;
    const replace = (name, fn) => {
      try { Object.defineProperty(tabs, name, { value: fn, configurable: true, writable: true }); }
      catch (e) { try { tabs[name] = fn; } catch (e2) { sendLog("warn", ["Couldn't patch tabs." + name]); } }
    };
    const original = {};
    for (const name of ["query", "get", "create", "update", "duplicate"]) {
      if (typeof tabs[name] === "function") original[name] = tabs[name].bind(tabs);
    }
    if (original.query) replace("query", wrap(async (queryInfo) => {
      await groupsReady;
      const q = Object.assign({}, queryInfo || {});
      const wanted = q.groupId;
      delete q.groupId;
      const result = (await original.query(q)).map(withGroup);
      return wanted === undefined ? result : result.filter((t) => t.groupId === wanted);
    }));
    if (original.get) replace("get", wrap(async (id) => withGroup(await original.get(id))));
    if (original.create) replace("create", wrap(async (props) => withGroup(await original.create(cleanTabURL(props) || {}))));
    if (original.update) replace("update", wrap(async (a, b) => {
      const result = typeof a === "number" ? await original.update(a, cleanTabURL(b) || {}) : await original.update(cleanTabURL(a) || {});
      return withGroup(result);
    }));
    if (original.duplicate) replace("duplicate", wrap(async (id) => withGroup(await original.duplicate(id))));
    replace("group", tabsGroup);
    replace("ungroup", tabsUngroup);
    try { Object.defineProperty(tabs, "TAB_ID_NONE", { value: tabs.TAB_ID_NONE == null ? -1 : tabs.TAB_ID_NONE, configurable: true }); } catch (e) { /* ignore */ }
    try { tabs.__inkwellGroups = true; } catch (e) { /* frozen */ }
    if (isBackground) {
      try { tabs.onRemoved.addListener((tabId) => { groupsReady.then(() => { if (removeTabsFromGroups([tabId])) saveGroups(); }); }); } catch (e) { /* no event */ }
    }
  };

  // ---------- chrome.offscreen ----------

  const reasons = ["TESTING", "AUDIO_PLAYBACK", "IFRAME_SCRIPTING", "DOM_SCRAPING", "BLOBS", "DOM_PARSER", "USER_MEDIA",
    "DISPLAY_MEDIA", "WEB_RTC", "CLIPBOARD", "LOCAL_STORAGE", "WORKERS", "BATTERY_STATUS", "MATCH_MEDIA", "GEOLOCATION"];
  const offscreen = {
    Reason: Object.fromEntries(reasons.map((r) => [r, r])),
    createDocument: wrap((options) => native("offscreen.create", { url: chromeAPI.runtime.getURL((options && options.url) || "") })),
    closeDocument: wrap(() => native("offscreen.close", {})),
    hasDocument: wrap(() => native("offscreen.has", {})),
  };

  // ---------- chrome.identity ----------

  const storeID = META.storeID || chromeAPI.runtime.id || "inkwell";
  const redirectBase = "https://" + storeID + ".chromiumapp.org";
  const identityMembers = {
    getRedirectURL: (path) => redirectBase + "/" + (path || ""),
    launchWebAuthFlow: wrap((details) => native("identity.launchWebAuthFlow", {
      url: details && details.url, interactive: !details || details.interactive !== false, redirectPrefix: redirectBase,
    })),
    getAuthToken: wrap(async () => {
      throw new Error("chrome.identity.getAuthToken needs a Google Chrome profile, which Inkwell Browser doesn't have.");
    }),
    removeCachedAuthToken: wrap(async () => undefined),
    clearAllCachedAuthTokens: wrap(async () => undefined),
    getProfileUserInfo: wrap(async () => ({ email: "", id: "" })),
    onSignInChanged: makeEvent(),
  };

  // ---------- runtime.onMessageExternal bridge ----------
  // Websites listed in "externally_connectable" talk to Chrome extensions with
  // chrome.runtime.sendMessage(<Chrome extension ID>, …). Inkwell's page shim forwards those
  // messages here through a content script; we hand them to the extension's
  // onMessageExternal listeners with the website as the sender, like Chrome does.

  const externalListeners = new Set();
  const runtime = chromeAPI.runtime;
  const nativeExternal = runtime.onMessageExternal;
  const externalEvent = {
    addListener: (f) => {
      externalListeners.add(f);
      try { if (nativeExternal && nativeExternal !== externalEvent) nativeExternal.addListener(f); } catch (e) { /* unsupported */ }
    },
    removeListener: (f) => {
      externalListeners.delete(f);
      try { if (nativeExternal && nativeExternal !== externalEvent) nativeExternal.removeListener(f); } catch (e) { /* unsupported */ }
    },
    hasListener: (f) => externalListeners.has(f),
    hasListeners: () => externalListeners.size > 0,
  };
  for (const ns of namespaces) {
    if (!ns.runtime) continue;
    const nativeEvent = ns.runtime.onMessageExternal;
    try { Object.defineProperty(ns.runtime, "onMessageExternal", { value: externalEvent, configurable: true, writable: true }); }
    catch (e) { try { ns.runtime.onMessageExternal = externalEvent; } catch (e2) { /* read-only */ } }
    if (ns.runtime.onMessageExternal === externalEvent || !nativeEvent) continue;

    // WebKit wouldn't let us replace the event, so record listeners as they're added to it instead:
    // first on the event object itself, then (if that's locked too) on its shared prototype.
    const record = (original) => function (listener) {
      if (this === nativeEvent && typeof listener === "function") externalListeners.add(listener);
      return original.apply(this, arguments);
    };
    const unrecord = (original) => function (listener) {
      if (this === nativeEvent) externalListeners.delete(listener);
      return original.apply(this, arguments);
    };
    let hooked = false;
    try {
      const add = nativeEvent.addListener;
      const remove = nativeEvent.removeListener;
      Object.defineProperty(nativeEvent, "addListener", { value: record(add), configurable: true, writable: true });
      if (remove) Object.defineProperty(nativeEvent, "removeListener", { value: unrecord(remove), configurable: true, writable: true });
      hooked = nativeEvent.addListener !== add;
    } catch (e) { /* locked */ }
    if (!hooked) {
      try {
        const proto = Object.getPrototypeOf(nativeEvent);
        const add = proto.addListener;
        const remove = proto.removeListener;
        Object.defineProperty(proto, "addListener", { value: record(add), configurable: true, writable: true });
        if (remove) Object.defineProperty(proto, "removeListener", { value: unrecord(remove), configurable: true, writable: true });
        hooked = proto.addListener !== add;
      } catch (e) { /* locked */ }
    }
    sendLog(hooked ? "info" : "error", [hooked
      ? "onMessageExternal: recording listeners on WebKit's event"
      : "onMessageExternal: couldn't intercept WebKit's event; website messages won't reach this extension"]);
  }

  if (isBackground) try {
    runtime.onMessage.addListener((msg, sender, sendResponse) => {
      if (msg && msg.__inkwellKeepAlive === true) { sendResponse(true); return false; }
      if (msg && msg.__inkwellLog === true) { sendLog(msg.level || "info", ["[" + (msg.source || "content") + "] " + msg.text]); return false; }
      if (!msg || msg.__inkwellExternal !== true) return false;
      if (externalListeners.size === 0) {
        // The extension's background may still be starting; wait for it to register a listener.
        const started = Date.now();
        const retry = () => {
          if (externalListeners.size > 0) { deliverExternal(msg, sender, sendResponse); return; }
          if (Date.now() - started > 8000) {
            sendLog("warn", ["Website message (" + (msg.message && msg.message.type) + ") timed out: the extension never registered onMessageExternal"]);
            try { sendResponse(undefined); } catch (e) { /* closed */ }
            return;
          }
          setTimeout(retry, 100);
        };
        retry();
        return true;
      }
      return deliverExternal(msg, sender, sendResponse);
    });
  } catch (e) { /* no runtime.onMessage in this context */ }

  function deliverExternal(msg, sender, sendResponse) {
      const externalSender = { origin: msg.origin, url: msg.url, tab: sender && sender.tab, frameId: sender && sender.frameId };
      let responded = false;
      let async = false;
      const respond = (response) => {
        if (responded) return;
        responded = true;
        try { sendResponse(response); } catch (e) { /* channel closed */ }
      };
      for (const listener of externalListeners) {
        try {
          const result = listener(msg.message, externalSender, respond);
          if (result === true) async = true;
          else if (result && typeof result.then === "function") { async = true; result.then(respond, () => respond(undefined)); }
        } catch (e) { console.error(e); }
      }
      if (!async) respond(undefined);
      return async;
  }

  // ---------- APIs WebKit doesn't have: notifications, downloads, declarativeNetRequest enums ----------

  let nextNotificationId = 1;
  const notifications = {
    TemplateType: { BASIC: "basic", IMAGE: "image", LIST: "list", PROGRESS: "progress" },
    PermissionLevel: { GRANTED: "granted", DENIED: "denied" },
    create: wrap(async (idOrOptions, maybeOptions) => {
      const id = typeof idOrOptions === "string" ? idOrOptions : "inkwell-" + nextNotificationId++;
      const options = (typeof idOrOptions === "string" ? maybeOptions : idOrOptions) || {};
      native("notifications.create", { id, title: options.title || "", message: options.message || "" }).catch(() => {});
      return id;
    }),
    update: wrap(async () => true),
    clear: wrap(async () => true),
    getAll: wrap(async () => ({})),
    getPermissionLevel: wrap(async () => "granted"),
    onClicked: makeEvent(), onClosed: makeEvent(), onButtonClicked: makeEvent(), onShowSettings: makeEvent(),
    onPermissionLevelChanged: makeEvent(),
  };

  let nextDownloadId = 1;
  const downloads = {
    download: wrap(async (options) => {
      const id = nextDownloadId++;
      await native("downloads.download", { url: options && options.url, filename: (options && options.filename) || "" });
      return id;
    }),
    search: wrap(async () => []),
    pause: wrap(async () => undefined), resume: wrap(async () => undefined), cancel: wrap(async () => undefined),
    erase: wrap(async () => []), open: wrap(async () => undefined), show: () => true, showDefaultFolder: () => undefined,
    onCreated: makeEvent(), onChanged: makeEvent(), onErased: makeEvent(), onDeterminingFilename: makeEvent(),
  };

  const dnrEnums = {
    RuleActionType: { BLOCK: "block", REDIRECT: "redirect", ALLOW: "allow", UPGRADE_SCHEME: "upgradeScheme",
      MODIFY_HEADERS: "modifyHeaders", ALLOW_ALL_REQUESTS: "allowAllRequests" },
    HeaderOperation: { APPEND: "append", SET: "set", REMOVE: "remove" },
    ResourceType: { MAIN_FRAME: "main_frame", SUB_FRAME: "sub_frame", STYLESHEET: "stylesheet", SCRIPT: "script",
      IMAGE: "image", FONT: "font", OBJECT: "object", XMLHTTPREQUEST: "xmlhttprequest", PING: "ping",
      CSP_REPORT: "csp_report", MEDIA: "media", WEBSOCKET: "websocket", WEBTRANSPORT: "webtransport",
      WEBBUNDLE: "webbundle", OTHER: "other" },
    DomainType: { FIRST_PARTY: "firstParty", THIRD_PARTY: "thirdParty" },
    RequestMethod: { CONNECT: "connect", DELETE: "delete", GET: "get", HEAD: "head", OPTIONS: "options",
      PATCH: "patch", POST: "post", PUT: "put", OTHER: "other" },
  };
  const dnrStub = Object.assign({
    updateSessionRules: wrap(async () => undefined), updateDynamicRules: wrap(async () => undefined),
    getSessionRules: wrap(async () => []), getDynamicRules: wrap(async () => []),
    updateEnabledRulesets: wrap(async () => undefined), getEnabledRulesets: wrap(async () => []),
    isRegexSupported: wrap(async () => ({ isSupported: true })),
    MAX_NUMBER_OF_SESSION_RULES: 5000, MAX_NUMBER_OF_DYNAMIC_RULES: 5000,
  }, dnrEnums);

  // Generic safety net: Inkwell scans the extension for chrome.<api>.<member> references when it
  // installs it (META.apiRefs). Anything WebKit doesn't provide gets a harmless stand-in so a
  // single missing API doesn't crash the whole background script.
  // What a do-nothing stand-in returns: lists for queries, empty objects for lookups.
  const defaultResult = (name) => {
    if (/^(getAll|query|search|getContexts|list)/.test(name)) return [];
    if (/^get/.test(name)) return {};
    if (/^(has|contains|is)/.test(name)) return false;
    return undefined;
  };

  const fillMissingAPIs = () => {
    const refs = Array.isArray(META.apiRefs) ? META.apiRefs : [];
    const skip = new Set(["runtime.lastError", "extension.lastError", "extension.inIncognitoContext"]);
    const filled = new Set();
    for (const ref of refs) {
      if (skip.has(ref.split(".").slice(0, 2).join("."))) continue;
      const [nsName, member, sub] = ref.split(".");
      for (const ns of namespaces) {
        let target = ns[nsName];
        if (target === undefined || target === null) {
          target = define(ns, nsName, {});
          if (!target) continue;
          filled.add(nsName);
        }
        if (!member) continue;
        if (target[member] === undefined) {
          let value;
          if (/^on[A-Z]/.test(member)) value = makeEvent();
          else if (/^[A-Z]/.test(member) || (sub && /^[a-z]/.test(sub))) value = {};
          else value = wrap(async () => defaultResult(member));
          if (define(target, member, value) !== undefined) filled.add(nsName + "." + member);
        }
        const holder = target[member];
        if (sub && holder && typeof holder === "object" && holder[sub] === undefined) {
          let subValue;
          if (/^[A-Z][A-Z0-9_]*$/.test(sub)) subValue = sub.toLowerCase().replace(/_([a-z0-9])/g, (m, c) => c.toUpperCase());
          else if (/^on[A-Z]/.test(sub)) subValue = makeEvent();
          else if (/^[a-z]/.test(sub) && !(sub === "addListener" || sub === "removeListener" || sub === "hasListener")) subValue = wrap(async () => defaultResult(sub));
          if (subValue !== undefined && define(holder, sub, subValue) !== undefined) filled.add(ref);
        }
      }
    }
    if (filled.size) sendLog("warn", ["Filled in Chrome APIs that WebKit lacks (they do nothing): " + Array.from(filled).join(", ")]);
  };

  // ---------- declarativeNetRequest header rules WebKit rejects ----------
  // WebKit only lets extensions modify a few standard headers. For modifyHeaders rules it rejects,
  // apply the request headers ourselves on this extension's own fetch()/XHR calls.

  const jsHeaderRules = new Map(); // rule id -> { test(url), headers: [[name, value]] }
  const filterToRegex = (filter) => {
    let f = String(filter || "*");
    let prefix = "^";
    if (f.startsWith("||")) { f = f.slice(2); prefix = "^[a-z]+://([^/]*\\.)?"; }
    else if (f.startsWith("|")) { f = f.slice(1); }
    else { prefix = ""; }
    let suffix = "";
    if (f.endsWith("|")) { f = f.slice(0, -1); suffix = "$"; }
    const body = f.split("").map((c) => {
      if (c === "*") return ".*";
      if (c === "^") return "([^a-zA-Z0-9_.%-]|$)";
      return c.replace(/[.+?${}()|[\]\\\/]/g, "\\$&");
    }).join("");
    return new RegExp(prefix + body + suffix);
  };
  const ruleMatcher = (condition) => {
    const c = condition || {};
    const regex = c.regexFilter ? new RegExp(c.regexFilter) : filterToRegex(c.urlFilter);
    const domains = c.requestDomains || c.domains || null;
    return (url) => {
      try {
        if (domains) {
          const host = new URL(url).hostname;
          if (!domains.some((d) => host === d || host.endsWith("." + d))) return false;
        }
        return regex.test(url);
      } catch (e) { return false; }
    };
  };
  const takeOverHeaderRules = (options) => {
    const opts = Object.assign({}, options || {});
    for (const id of opts.removeRuleIds || []) jsHeaderRules.delete(id);
    const keep = [];
    for (const rule of opts.addRules || []) {
      const action = rule && rule.action;
      if (action && action.type === "modifyHeaders" && Array.isArray(action.requestHeaders)) {
        const headers = action.requestHeaders.filter((h) => h.operation === "set" && h.value != null).map((h) => [h.header, h.value]);
        if (headers.length) jsHeaderRules.set(rule.id, { test: ruleMatcher(rule.condition), headers });
        if (!action.responseHeaders) continue;
        keep.push(Object.assign({}, rule, { action: { type: "modifyHeaders", responseHeaders: action.responseHeaders } }));
      } else {
        keep.push(rule);
      }
    }
    opts.addRules = keep;
    return opts;
  };
  const headersFor = (url) => {
    const out = [];
    for (const rule of jsHeaderRules.values()) if (rule.test(url)) out.push(...rule.headers);
    return out;
  };

  if (typeof g.fetch === "function" && !g.fetch.__inkwell) {
    const nativeFetch = g.fetch.bind(g);
    const patchedFetch = (input, init) => {
      try {
        const url = typeof input === "string" ? input : (input && input.url) || String(input);
        const extra = headersFor(url);
        if (extra.length) {
          const headers = new Headers((init && init.headers) || (input instanceof Request ? input.headers : undefined));
          for (const [k, v] of extra) { try { headers.set(k, v); } catch (e) { /* forbidden header */ } }
          init = Object.assign({}, init || {}, { headers });
        }
      } catch (e) { /* fall through */ }
      return nativeFetch(input, init);
    };
    patchedFetch.__inkwell = true;
    g.fetch = patchedFetch;
  }
  if (typeof g.XMLHttpRequest === "function" && !g.XMLHttpRequest.prototype.__inkwell) {
    const proto = g.XMLHttpRequest.prototype;
    const open = proto.open;
    const send = proto.send;
    proto.open = function (method, url, ...rest) { this.__inkwellURL = String(url); return open.call(this, method, url, ...rest); };
    proto.send = function (...args) {
      for (const [k, v] of headersFor(this.__inkwellURL || "")) { try { this.setRequestHeader(k, v); } catch (e) { /* forbidden */ } }
      return send.apply(this, args);
    };
    proto.__inkwell = true;
  }

  const wrapRuleUpdate = (dnr, name) => {
    const original = dnr[name];
    if (typeof original !== "function" || original.__inkwell) return;
    const replacement = wrap(async (options) => {
      const remaining = takeOverHeaderRules(options);
      if (!(remaining.addRules || []).length && !(remaining.removeRuleIds || []).length) return undefined;
      try {
        return await original.call(dnr, remaining);
      } catch (e) {
        sendLog("warn", ["declarativeNetRequest." + name + " rejected by WebKit: " + (e && e.message)]);
        return undefined;
      }
    });
    replacement.__inkwell = true;
    try { dnr[name] = replacement; } catch (e) {
      try { Object.defineProperty(dnr, name, { value: replacement, configurable: true, writable: true }); } catch (e2) { /* frozen */ }
    }
  };

  // ---------- chrome.windows on iPad: popups become tabs ----------
  const popupTabs = new Map(); // fake window id -> tab id
  let nextPopupWindowId = 1000;
  const windowsExtras = {
    create: wrap(async (data) => {
      const d = data || {};
      const urls = Array.isArray(d.url) ? d.url : (d.url ? [d.url] : [undefined]);
      const tabs = [];
      for (const url of urls) tabs.push(await promiseAPI.tabs.create({ url, active: d.focused !== false }));
      const id = nextPopupWindowId++;
      popupTabs.set(id, tabs.map((t) => t.id));
      const first = tabs[0] || {};
      return { id, focused: d.focused !== false, incognito: false, alwaysOnTop: false, state: "normal",
        type: d.type || "normal", tabs, left: 0, top: 0, width: d.width || 0, height: d.height || 0, windowIdOfTabs: first.windowId };
    }),
    update: wrap(async (windowId, info) => {
      const owned = popupTabs.get(windowId);
      if (owned && owned.length && info && info.focused) { try { await promiseAPI.tabs.update(owned[0], { active: true }); } catch (e) { /* closed */ } }
      try { return await promiseAPI.windows.get(windowId); } catch (e) { return { id: windowId, focused: true, state: "normal", type: "normal" }; }
    }),
    remove: wrap(async (windowId) => {
      const owned = popupTabs.get(windowId);
      if (owned) { popupTabs.delete(windowId); try { await promiseAPI.tabs.remove(owned); } catch (e) { /* closed */ } }
    }),
  };
  // Is this page the extension's side panel (Inkwell shows it in its own panel, not in a tab)?
  const isSidePanelPage = (() => {
    try {
      const path = (manifest.side_panel && manifest.side_panel.default_path) || "";
      return !!path && !!g.location && g.location.pathname === "/" + path.replace(/^\//, "").split("?")[0];
    } catch (e) { return false; }
  })();

  const getContexts = wrap(async (filter) => {
    const types = (filter && filter.contextTypes) || null;
    const urls = (filter && filter.documentUrls) || null;
    const out = [];
    if (isSidePanelPage && (!types || types.includes("SIDE_PANEL")) && (!urls || urls.includes(g.location.href))) {
      out.push({ contextType: "SIDE_PANEL", contextId: "side-panel", documentUrl: g.location.href,
        documentOrigin: g.location.origin, frameId: 0, incognito: false, tabId: -1, windowId: -1 });
    }
    if (!types || types.includes("OFFSCREEN_DOCUMENT")) {
      try { if (await native("offscreen.has", {})) out.push({ contextType: "OFFSCREEN_DOCUMENT", contextId: "offscreen", documentUrl: "", frameId: -1, incognito: false, tabId: -1, windowId: -1 }); } catch (e) { /* none */ }
    }
    return out;
  });

  // ---------- install ----------

  for (const ns of namespaces) {
    define(ns, "sidePanel", sidePanel);
    define(ns, "debugger", debuggerAPI);
    define(ns, "tabGroups", tabGroups);
    define(ns, "offscreen", offscreen);
    define(ns, "notifications", notifications);
    if (ns.windows) for (const [k, v] of Object.entries(windowsExtras)) define(ns.windows, k, v);
    if (ns.runtime) {
      define(ns.runtime, "getContexts", getContexts);
      define(ns.runtime, "ContextType", { TAB: "TAB", POPUP: "POPUP", BACKGROUND: "BACKGROUND", OFFSCREEN_DOCUMENT: "OFFSCREEN_DOCUMENT", SIDE_PANEL: "SIDE_PANEL", DEVELOPER_TOOLS: "DEVELOPER_TOOLS" });
      define(ns.runtime, "OnInstalledReason", { INSTALL: "install", UPDATE: "update", CHROME_UPDATE: "chrome_update", SHARED_MODULE_UPDATE: "shared_module_update" });
    }
    // Like Chrome: a side panel isn't a tab, so tabs.getCurrent() resolves to undefined there.
    if (isSidePanelPage && ns.tabs) {
      const sidePanelGetCurrent = wrap(async () => undefined);
      try { Object.defineProperty(ns.tabs, "getCurrent", { value: sidePanelGetCurrent, configurable: true, writable: true }); }
      catch (e) { try { ns.tabs.getCurrent = sidePanelGetCurrent; } catch (e2) { sendLog("warn", ["Couldn't override tabs.getCurrent in the side panel"]); } }
    }
    if (ns.storage) define(ns.storage, "managed", { get: wrap(async () => ({})), getBytesInUse: wrap(async () => 0), onChanged: makeEvent() });
    define(ns, "downloads", downloads);
    const dnr = define(ns, "declarativeNetRequest", dnrStub);
    if (dnr) { wrapRuleUpdate(dnr, "updateSessionRules"); wrapRuleUpdate(dnr, "updateDynamicRules"); }
    if (dnr && dnr !== dnrStub) {
      // WebKit's own API: fill in any missing enum objects/values Chrome code expects.
      for (const [name, values] of Object.entries(dnrEnums)) {
        const target = define(dnr, name, Object.assign({}, values));
        if (target && target !== values) {
          for (const [k, v] of Object.entries(values)) { try { if (target[k] === undefined) target[k] = v; } catch (e) { /* frozen */ } }
        }
      }
    }
    const identity = define(ns, "identity", {});
    if (identity) for (const [name, value] of Object.entries(identityMembers)) define(identity, name, value);
    patchTabsAPI(ns.tabs);
  }
  fillMissingAPIs();
})();
"""#

    static let workerShimScript = #"""
// Inkwell Browser — runs a Chrome "service worker" background inside a background page.
// Third-party iPad apps can't use service workers, so this fills in the worker-only globals.
(() => {
  const g = globalThis;
  const api = g.browser || g.chrome;
  if (!("ServiceWorkerGlobalScope" in g)) {
    g.ServiceWorkerGlobalScope = function ServiceWorkerGlobalScope() {};
  }
  if (typeof g.importScripts !== "function") {
    g.importScripts = (...urls) => {
      for (const u of urls) document.write('<script src="' + new URL(u, location.href).href + '"><\/script>');
    };
  }
  if (!g.registration) {
    g.registration = {
      scope: location.origin + "/",
      active: null, installing: null, waiting: null,
      update: async () => undefined,
      unregister: async () => true,
      showNotification: async (title, options) => {
        try { await api.notifications.create({ type: "basic", title, message: (options && options.body) || "", iconUrl: (options && options.icon) || "" }); } catch (e) { /* ignore */ }
      },
      getNotifications: async () => [],
    };
  }
  if (!g.clients) {
    g.clients = {
      claim: async () => undefined,
      matchAll: async () => [],
      get: async () => undefined,
      openWindow: async (url) => { await api.tabs.create({ url }); return null; },
    };
  }
  if (typeof g.skipWaiting !== "function") g.skipWaiting = async () => undefined;

  // Fire the worker lifecycle events once the background code (modules run deferred) has loaded.
  g.addEventListener("load", () => {
    for (const type of ["install", "activate"]) {
      try {
        const event = new Event(type);
        event.waitUntil = () => undefined;
        g.dispatchEvent(event);
      } catch (e) { /* ignore */ }
    }
  });
})();
"""#

    static let redirectScript = #"""
// Inkwell Browser — finishes a sign-in that redirected to chrome-extension://<id>/…, which only
// Chrome can open. Hands the redirect to the extension the way Chrome-based sites do.
(async () => {
  const api = globalThis.browser || globalThis.chrome;
  const params = new URLSearchParams(location.search);
  const target = params.get("u") || "";
  const origin = params.get("origin") || "";
  const status = document.getElementById("status");
  const show = (text) => { if (status) status.textContent = text; };
  console.info("Inkwell: delivering redirect to extension", target.split("?")[0], "from", origin);
  try {
    const response = await api.runtime.sendMessage({
      __inkwellExternal: true,
      origin,
      url: params.get("from") || origin,
      message: { type: "oauth_redirect", redirect_uri: target },
    });
    console.info("Inkwell: extension replied", JSON.stringify(response));
    if (response && response.success === false) {
      show("Sign-in didn't finish: " + (response.error || "unknown error"));
      return;
    }
    show("Signed in. You can close this tab.");
    setTimeout(async () => {
      try {
        const tab = await api.tabs.getCurrent();
        if (tab && tab.id != null) await api.tabs.remove(tab.id);
      } catch (e) { window.close(); }
    }, 1200);
  } catch (e) {
    console.error("Inkwell: redirect delivery failed", e);
    show("Sign-in didn't finish: " + (e && e.message ? e.message : e));
  }
})();
"""#

    static let keepAliveScript = #"""
// Inkwell Browser — pings the background worker so iPadOS doesn't suspend it while the app is open.
(() => {
  const api = globalThis.browser || globalThis.chrome;
  const ping = () => {
    try {
      const result = api.runtime.sendMessage({ __inkwellKeepAlive: true });
      if (result && typeof result.catch === "function") result.catch(() => {});
    } catch (e) { /* background is restarting */ }
  };
  ping();
  setInterval(ping, 15000);
})();
"""#

    static let pageShimScript = #"""
// Inkwell Browser — lets this website call chrome.runtime.sendMessage("__STORE_ID__", …) like in Chrome.
(() => {
  const STORE_ID = "__STORE_ID__";
  const flag = "__inkwellShim_" + STORE_ID;
  if (window[flag]) return;
  window[flag] = true;
  window.chrome = window.chrome || {};
  const rt = window.chrome.runtime = window.chrome.runtime || {};
  const previousSend = rt.sendMessage;
  const pending = new Map();
  let counter = 0;

  window.addEventListener("message", (event) => {
    const data = event.data;
    if (event.source !== window || !data || data.__inkwellReply !== true || data.extensionId !== STORE_ID) return;
    const resolve = pending.get(data.id);
    if (resolve) { pending.delete(data.id); resolve(data.response); }
  });

  const pageLog = (text) => window.postMessage({ __inkwellPageLog: true, extensionId: STORE_ID, text: String(text).slice(0, 1500) }, "*");
  pageLog("page shim active on " + location.origin + location.pathname);

  // Diagnostics: page errors, and which chrome.runtime features the site touches.
  window.addEventListener("error", (e) => pageLog("page error: " + (e.message || "") + " @ " + (e.filename || "") + ":" + (e.lineno || 0)));
  window.addEventListener("unhandledrejection", (e) => {
    const r = e.reason;
    pageLog("page unhandled rejection: " + (r && (r.stack || r.message) || String(r)));
  });
  for (const level of ["error", "warn"]) {
    const original = console[level];
    console[level] = function (...args) {
      try {
        pageLog("page console." + level + ": " + args.map((a) => {
          try { return typeof a === "string" ? a : (a instanceof Error ? (a.stack || a.message) : JSON.stringify(a)); } catch (e) { return String(a); }
        }).join(" "));
      } catch (e) { /* ignore */ }
      return original.apply(this, args);
    };
  }
  // Network diagnostics: log failed requests, and every sign-in related request (path + status only).
  const interesting = (u) => /oauth|authorize|consent|login|auth/i.test(u);
  const pathOf = (u) => { try { const x = new URL(u, location.href); return x.host + x.pathname; } catch (e) { return String(u).split("?")[0]; } };
  const originalFetch = window.fetch;
  if (typeof originalFetch === "function") {
    window.fetch = function (input, init) {
      const url = typeof input === "string" ? input : (input && input.url) || String(input);
      const method = (init && init.method) || (input && input.method) || "GET";
      const started = Date.now();
      const p = originalFetch.apply(this, arguments);
      p.then((r) => {
        if (!r.ok || interesting(url)) pageLog("fetch " + method + " " + pathOf(url) + " → " + r.status + " (" + (Date.now() - started) + "ms)");
      }, (e) => pageLog("fetch " + method + " " + pathOf(url) + " FAILED: " + (e && e.message)));
      return p;
    };
  }
  const xhrOpen = XMLHttpRequest.prototype.open;
  const xhrSend = XMLHttpRequest.prototype.send;
  XMLHttpRequest.prototype.open = function (method, url) { this.__ink = [method, String(url)]; return xhrOpen.apply(this, arguments); };
  XMLHttpRequest.prototype.send = function () {
    const info = this.__ink || ["?", "?"];
    this.addEventListener("loadend", () => {
      if (this.status >= 400 || this.status === 0 || interesting(info[1])) pageLog("xhr " + info[0] + " " + pathOf(info[1]) + " → " + this.status);
    });
    return xhrSend.apply(this, arguments);
  };

  const originalOpen = window.open;
  window.open = function (url, ...rest) {
    pageLog("page called window.open(" + String(url).split("?")[0] + ")");
    return originalOpen.call(this, url, ...rest);
  };
  window.addEventListener("pagehide", () => pageLog("page leaving " + location.pathname));

  // A message is for this extension if it's addressed to its Chrome ID, or if its contents mention that
  // ID (e.g. an OAuth redirect_uri of chrome-extension://<id>/…) — sites sometimes address a sibling ID.
  const mentionsUs = (m) => { try { return JSON.stringify(m).includes(STORE_ID); } catch (e) { return false; } };
  const describe = (m) => (m && typeof m === "object" ? m.type : typeof m);

  rt.sendMessage = function (extensionId, message, optionsOrCallback, maybeCallback) {
    if (extensionId !== STORE_ID) {
      if (!mentionsUs(message)) {
        pageLog("page messaged another extension id " + String(extensionId) + " (type=" + describe(message) + ")");
        if (typeof previousSend === "function") return previousSend.apply(this, arguments);
        return Promise.reject(new Error("Could not establish connection. Receiving end does not exist."));
      }
      pageLog("page addressed extension id " + String(extensionId) + " but the message is for " + STORE_ID + "; delivering it");
    }
    const callback = [optionsOrCallback, maybeCallback].find((f) => typeof f === "function");
    const type = message && typeof message === "object" ? message.type : typeof message;
    window.postMessage({ __inkwellPageLog: true, extensionId: STORE_ID, text: "page called chrome.runtime.sendMessage, type=" + type }, "*");
    const id = STORE_ID + ":" + (++counter) + ":" + Math.random();
    return new Promise((resolve) => {
      pending.set(id, (response) => { resolve(response); if (callback) callback(response); });
      window.postMessage({ __inkwellExternal: true, extensionId: STORE_ID, id, message }, "*");
    });
  };

  const seen = new Set();
  try {
    window.chrome.runtime = new Proxy(rt, {
      get(target, prop) {
        if (typeof prop === "string" && !seen.has(prop)) { seen.add(prop); pageLog("page read chrome.runtime." + prop); }
        return target[prop];
      },
    });
  } catch (e) { /* ignore */ }
})();
"""#

    static let bridgeScript = #"""
// Inkwell Browser — relays chrome.runtime.sendMessage calls from this website to the extension.
(() => {
  const STORE_ID = "__STORE_ID__";
  const api = globalThis.browser || globalThis.chrome;
  if (!api || !api.runtime) return;

  // Load the page-world shim (in case the browser ignores "world": "MAIN").
  try {
    const script = document.createElement("script");
    script.src = api.runtime.getURL("__inkwell_page.js");
    script.onload = () => script.remove();
    (document.head || document.documentElement).appendChild(script);
  } catch (e) { /* ignore */ }

  const log = (text, level) => {
    try {
      const r = api.runtime.sendMessage({ __inkwellLog: true, source: "bridge " + location.host, level: level || "info", text });
      if (r && typeof r.catch === "function") r.catch(() => {});
    } catch (e) { /* ignore */ }
  };
  log("bridge loaded on " + location.href.split("?")[0]);

  window.addEventListener("message", (event) => {
    const data = event.data;
    if (event.source === window && data && data.__inkwellPageLog === true && data.extensionId === STORE_ID) {
      log(String(data.text));
      return;
    }
    if (event.source !== window || !data || data.__inkwellExternal !== true || data.extensionId !== STORE_ID) return;
    log("relaying message type=" + (data.message && data.message.type));
    const reply = (response) => {
      log("extension replied: " + String(JSON.stringify(response)).slice(0, 300));
      window.postMessage({ __inkwellReply: true, extensionId: STORE_ID, id: data.id, response }, "*");
    };
    try {
      const result = api.runtime.sendMessage({ __inkwellExternal: true, origin: location.origin, url: location.href, message: data.message });
      if (result && typeof result.then === "function") {
        result.then(reply, (e) => { log("relay failed: " + (e && e.message), "error"); reply(undefined); });
      }
    } catch (e) {
      reply(undefined);
    }
  });
})();
"""#
}

extension ExtensionPatcher {
    /// Page-world scripts that let websites in an extension's "externally_connectable" call
    /// chrome.runtime.sendMessage(<Chrome ID>). Injected by the app itself so site CSP can't block them.
    @MainActor
    static func pageWorldUserScripts() -> [WKUserScript] {
        ExtensionManager.shared.activeContexts.compactMap { record, context in
            guard let storeID = record.storeID, ChromeWebStore.isExtensionID(storeID),
                  let connectable = context.webExtension.manifest["externally_connectable"] as? [String: Any],
                  let matches = connectable["matches"] as? [String], !matches.isEmpty,
                  let matchesJSON = (try? JSONSerialization.data(withJSONObject: matches)).flatMap({ String(data: $0, encoding: .utf8) })
            else { return nil }
            let guardJS = """
            (() => {
              const patterns = \(matchesJSON);
              const toRegex = (p) => new RegExp("^" + p.split("*").map((s) => s.replace(/[.+?^${}()|[\\]\\\\\\/]/g, "\\\\$&")).join(".*") + "$");
              if (!patterns.some((p) => { try { return toRegex(p).test(location.href); } catch (e) { return false; } })) return;

            """
            let source = guardJS + pageShimScript.replacingOccurrences(of: "__STORE_ID__", with: storeID) + "\n})();\n"
            return WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        }
    }
}

// MARK: - Native side of the compatibility layer

/// Handles messages the compatibility script sends with runtime.sendNativeMessage.
@MainActor
final class ChromeCompat {
    static let shared = ChromeCompat()

    private struct PanelState {
        var path: String?
        var enabled = true
        var openOnActionClick = false
    }

    private var panels: [ObjectIdentifier: PanelState] = [:]
    private var offscreenDocuments: [ObjectIdentifier: WKWebView] = [:]
    private var keepAliveViews: [ObjectIdentifier: WKWebView] = [:]

    /// Adds a web view to a window invisibly (1×1, nearly transparent, behind everything) so
    /// WebKit treats it as visible and doesn't throttle its timers.
    private func hostHidden(_ webView: WKWebView) {
        webView.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
        webView.alpha = 0.02
        webView.isUserInteractionEnabled = false
        webView.accessibilityElementsHidden = true
        if let host = WindowRegistry.shared.focusedOrAny?.view {
            host.insertSubview(webView, at: 0)
        }
    }

    /// Re-hosts hidden pages when a window appears (e.g. extensions loaded before the first window).
    func adoptHiddenViews(into window: BrowserWindow) {
        for webView in Array(keepAliveViews.values) + Array(offscreenDocuments.values) where webView.window == nil {
            window.view.insertSubview(webView, at: 0)
        }
    }

    func startKeepAlive(for context: WKWebExtensionContext) {
        let key = ObjectIdentifier(context)
        guard keepAliveViews[key] == nil, let configuration = context.webViewConfiguration else { return }
        let webView = WKWebView(frame: .zero, configuration: configuration)
        hostHidden(webView)
        webView.load(URLRequest(url: context.baseURL.appendingPathComponent(ExtensionPatcher.keepAlivePageName)))
        keepAliveViews[key] = webView
    }

    // Side panel queries used by the browser window.

    func panelURL(for context: WKWebExtensionContext) -> URL? {
        let state = panels[ObjectIdentifier(context)]
        guard state?.enabled ?? true else { return nil }
        let manifestPanel = context.webExtension.manifest["side_panel"] as? [String: Any]
        guard let path = state?.path ?? manifestPanel?["default_path"] as? String, !path.isEmpty else { return nil }
        return URL(string: path, relativeTo: context.baseURL)?.absoluteURL
    }

    func opensPanelOnActionClick(_ context: WKWebExtensionContext) -> Bool {
        panels[ObjectIdentifier(context)]?.openOnActionClick ?? false
    }

    func handle(_ message: Any, from context: WKWebExtensionContext, reply: @escaping (Any) -> Void) {
        guard let body = message as? [String: Any], let command = body["inkwell"] as? String else {
            reply(failure("Inkwell Browser doesn't have a native helper for this message."))
            return
        }
        let args = body["args"] as? [String: Any] ?? [:]
        let key = ObjectIdentifier(context)

        if command != "log" {
            ExtensionLogStore.shared.add(extension: "Inkwell", level: "info", where: "app",
                                         text: "\(context.webExtension.displayName ?? "Extension") asked the app for \(command)")
        }
        switch command {
        case "log":
            ExtensionLogStore.shared.add(extension: context.webExtension.displayName ?? "Extension",
                                         level: args["level"] as? String ?? "log",
                                         where: args["where"] as? String ?? "",
                                         text: args["text"] as? String ?? "")
            reply(success(nil))

        case "sidePanel.open":
            guard let url = panelURL(for: context), let window = WindowRegistry.shared.focusedOrAny else {
                reply(failure("This extension has no side panel."))
                return
            }
            window.showSidePanel(for: context, url: url)
            reply(success(nil))

        case "sidePanel.close":
            WindowRegistry.shared.windows.forEach { $0.hideSidePanel(onlyFor: context) }
            reply(success(nil))

        case "sidePanel.setOptions":
            var state = panels[key] ?? PanelState()
            if let path = args["path"] as? String { state.path = path }
            if let enabled = args["enabled"] as? Bool { state.enabled = enabled }
            panels[key] = state
            if !state.enabled {
                WindowRegistry.shared.windows.forEach { $0.hideSidePanel(onlyFor: context) }
            }
            reply(success(nil))

        case "sidePanel.getOptions":
            let state = panels[key] ?? PanelState()
            let manifestPanel = context.webExtension.manifest["side_panel"] as? [String: Any]
            let path = state.path ?? manifestPanel?["default_path"] as? String ?? ""
            reply(success(["path": path, "enabled": state.enabled]))

        case "sidePanel.setPanelBehavior":
            var state = panels[key] ?? PanelState()
            if let open = args["openPanelOnActionClick"] as? Bool { state.openOnActionClick = open }
            panels[key] = state
            reply(success(nil))

        case "sidePanel.getPanelBehavior":
            reply(success(["openPanelOnActionClick": opensPanelOnActionClick(context)]))

        case "offscreen.create":
            guard offscreenDocuments[key] == nil else {
                reply(failure("Only a single offscreen document may be created."))
                return
            }
            guard let urlString = args["url"] as? String, let url = URL(string: urlString),
                  let configuration = context.webViewConfiguration else {
                reply(failure("Couldn't create the offscreen document."))
                return
            }
            let webView = WKWebView(frame: .zero, configuration: configuration)
            hostHidden(webView)
            webView.load(URLRequest(url: url))
            offscreenDocuments[key] = webView
            reply(success(nil))

        case "offscreen.close":
            offscreenDocuments.removeValue(forKey: key)?.removeFromSuperview()
            reply(success(nil))

        case "offscreen.has":
            reply(success(offscreenDocuments[key] != nil))

        case "notifications.create":
            let title = args["title"] as? String ?? ""
            let text = args["message"] as? String ?? ""
            ExtensionLogStore.shared.add(extension: context.webExtension.displayName ?? "Extension", level: "info",
                                         where: "notification", text: "\(title): \(text)")
            WindowRegistry.shared.focusedOrAny?.showToast(title.isEmpty ? text : "\(title) — \(text)")
            reply(success(nil))

        case "downloads.download":
            guard let urlString = args["url"] as? String, let url = URL(string: urlString) else {
                reply(failure("Invalid download URL."))
                return
            }
            if url.scheme == "data" || url.scheme == "blob" {
                // Can't hand these to a tab reliably; save data: URLs directly.
                if let data = try? Data(contentsOf: url) {
                    let name = (args["filename"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "download"
                    let file = FileManager.default.temporaryDirectory.appendingPathComponent((name as NSString).lastPathComponent)
                    try? data.write(to: file)
                    if let presenter = UIApplication.topViewController() {
                        presenter.present(UIDocumentPickerViewController(forExporting: [file], asCopy: true), animated: true)
                    }
                }
            } else {
                WindowRegistry.shared.focusedOrAny?.openTab(url: url, select: false, insertAfterActive: true)
            }
            reply(success(nil))

        case "identity.launchWebAuthFlow":
            guard let urlString = args["url"] as? String, let url = URL(string: urlString),
                  let prefix = args["redirectPrefix"] as? String else {
                reply(failure("Invalid auth URL."))
                return
            }
            AuthFlowViewController.present(url: url, redirectPrefix: prefix) { [weak self] result in
                guard let self else { return }
                if let result {
                    reply(self.success(result.absoluteString))
                } else {
                    reply(self.failure("The user did not approve access."))
                }
            }

        default:
            reply(failure("Inkwell Browser doesn't support \(command) yet."))
        }
    }

    func contextWillUnload(_ context: WKWebExtensionContext) {
        let key = ObjectIdentifier(context)
        offscreenDocuments.removeValue(forKey: key)?.removeFromSuperview()
        keepAliveViews.removeValue(forKey: key)?.removeFromSuperview()
        panels[key] = nil
        WindowRegistry.shared.windows.forEach { $0.hideSidePanel(onlyFor: context) }
    }

    private func success(_ value: Any?) -> [String: Any] {
        ["ok": true, "value": value ?? NSNull()]
    }

    private func failure(_ message: String) -> [String: Any] {
        ["ok": false, "error": message]
    }
}

// MARK: - chrome.identity.launchWebAuthFlow

/// Shows a sign-in page in a sheet and finishes when it redirects to the extension's
/// https://<id>.chromiumapp.org/ callback, like Chrome does.
final class AuthFlowViewController: UIViewController, WKNavigationDelegate, UIAdaptivePresentationControllerDelegate {
    private let startURL: URL
    private let redirectPrefix: String
    private var completion: ((URL?) -> Void)?
    private let webView: WKWebView

    static func present(url: URL, redirectPrefix: String, completion: @escaping (URL?) -> Void) {
        guard let presenter = UIApplication.topViewController() else { completion(nil); return }
        let auth = AuthFlowViewController(url: url, redirectPrefix: redirectPrefix, completion: completion)
        let nav = UINavigationController(rootViewController: auth)
        nav.modalPresentationStyle = .formSheet
        nav.presentationController?.delegate = auth
        presenter.present(nav, animated: true)
    }

    private init(url: URL, redirectPrefix: String, completion: @escaping (URL?) -> Void) {
        startURL = url
        self.redirectPrefix = redirectPrefix
        self.completion = completion
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        view = webView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = startURL.host ?? "Sign In"
        webView.navigationDelegate = self
        webView.customUserAgent = AppSettings.userAgent.string
        navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .cancel, primaryAction: UIAction { [weak self] _ in
            self?.finish(nil)
        })
        webView.load(URLRequest(url: startURL))
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if let url = navigationAction.request.url, url.absoluteString.hasPrefix(redirectPrefix) {
            decisionHandler(.cancel)
            finish(url)
            return
        }
        decisionHandler(.allow)
    }

    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        completion?(nil)
        completion = nil
    }

    private func finish(_ url: URL?) {
        let done = completion
        completion = nil
        dismiss(animated: true) { done?(url) }
    }
}

// MARK: - Extension Console

struct ExtensionLogEntry: Identifiable {
    let id = UUID()
    let date: Date
    let extensionName: String
    let level: String
    let location: String
    let text: String
}

/// Recent console output from extensions, shown in Extensions → Extension Console.
@MainActor
final class ExtensionLogStore: ObservableObject {
    static let shared = ExtensionLogStore()
    @Published private(set) var entries: [ExtensionLogEntry] = []

    func add(extension name: String, level: String, where location: String, text: String) {
        entries.append(ExtensionLogEntry(date: Date(), extensionName: name, level: level, location: location, text: text))
        if entries.count > 1000 { entries.removeFirst(entries.count - 1000) }
    }

    func clear() { entries.removeAll() }

    var exportText: String {
        entries.map { entry in
            "[\(entry.date.formatted(date: .omitted, time: .standard))] \(entry.extensionName) \(entry.level.uppercased()) \(entry.location): \(entry.text)"
        }.joined(separator: "\n")
    }
}
