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

    static func patch(_ root: URL, storeID: String?) {
        let fm = FileManager.default
        let manifestURL = root.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: manifestURL),
              var manifest = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }

        // 1. The compatibility script (rewritten every time so updates take effect).
        let meta: [String: Any] = ["storeID": storeID ?? "", "version": 1]
        let metaJSON = (try? JSONSerialization.data(withJSONObject: meta)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        let script = "globalThis.__INKWELL__ = \(metaJSON);\n" + compatScript
        try? script.write(to: root.appendingPathComponent(compatFileName), atomically: true, encoding: .utf8)

        var changed = false

        // 2. Permission for runtime.sendNativeMessage.
        var permissions = manifest["permissions"] as? [Any] ?? []
        if !permissions.contains(where: { ($0 as? String) == "nativeMessaging" }) {
            permissions.append("nativeMessaging")
            manifest["permissions"] = permissions
            changed = true
        }

        // 3. Load the layer before the background code.
        if var background = manifest["background"] as? [String: Any] {
            if let worker = background["service_worker"] as? String, worker != workerWrapperName {
                let isModule = (background["type"] as? String) == "module"
                let wrapper = isModule
                    ? "import \"./\(compatFileName)\";\nimport \"./\(worker)\";\n"
                    : "importScripts(\"\(compatFileName)\", \"\(worker)\");\n"
                try? wrapper.write(to: root.appendingPathComponent(workerWrapperName), atomically: true, encoding: .utf8)
                background["service_worker"] = workerWrapperName
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

  // ---------- chrome.tabGroups (accepted but not shown) ----------

  const groups = new Map();
  let nextGroupId = 1;
  const groupInfo = (id) => groups.get(id) || { id, collapsed: false, color: "grey", title: "", windowId: -1 };
  const tabGroups = {
    TAB_GROUP_ID_NONE: -1,
    Color: { GREY: "grey", BLUE: "blue", RED: "red", YELLOW: "yellow", GREEN: "green", PINK: "pink", PURPLE: "purple", CYAN: "cyan", ORANGE: "orange" },
    query: wrap(async () => Array.from(groups.values())),
    get: wrap(async (id) => groupInfo(id)),
    update: wrap(async (id, props) => { const g2 = Object.assign(groupInfo(id), props || {}); groups.set(id, g2); return g2; }),
    move: wrap(async (id) => groupInfo(id)),
    onCreated: makeEvent(), onUpdated: makeEvent(), onRemoved: makeEvent(), onMoved: makeEvent(),
  };
  const tabsGroup = wrap(async (options) => {
    const id = (options && options.groupId) || nextGroupId++;
    if (!groups.has(id)) groups.set(id, { id, collapsed: false, color: "grey", title: "", windowId: -1 });
    return id;
  });
  const tabsUngroup = wrap(async () => undefined);

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
    try { Object.defineProperty(ns.runtime, "onMessageExternal", { value: externalEvent, configurable: true, writable: true }); }
    catch (e) { try { ns.runtime.onMessageExternal = externalEvent; } catch (e2) { /* read-only */ } }
  }

  try {
    runtime.onMessage.addListener((msg, sender, sendResponse) => {
      if (!msg || msg.__inkwellExternal !== true) return false;
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
    });
  } catch (e) { /* no runtime.onMessage in this context */ }

  // ---------- install ----------

  for (const ns of namespaces) {
    define(ns, "sidePanel", sidePanel);
    define(ns, "debugger", debuggerAPI);
    define(ns, "tabGroups", tabGroups);
    define(ns, "offscreen", offscreen);
    const identity = define(ns, "identity", {});
    if (identity) for (const [name, value] of Object.entries(identityMembers)) define(identity, name, value);
    if (ns.tabs) {
      define(ns.tabs, "group", tabsGroup);
      define(ns.tabs, "ungroup", tabsUngroup);
    }
  }
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

  rt.sendMessage = function (extensionId, message, optionsOrCallback, maybeCallback) {
    if (extensionId !== STORE_ID) {
      if (typeof previousSend === "function") return previousSend.apply(this, arguments);
      return Promise.reject(new Error("Could not establish connection. Receiving end does not exist."));
    }
    const callback = [optionsOrCallback, maybeCallback].find((f) => typeof f === "function");
    const id = STORE_ID + ":" + (++counter) + ":" + Math.random();
    return new Promise((resolve) => {
      pending.set(id, (response) => { resolve(response); if (callback) callback(response); });
      window.postMessage({ __inkwellExternal: true, extensionId: STORE_ID, id, message }, "*");
    });
  };
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

  window.addEventListener("message", (event) => {
    const data = event.data;
    if (event.source !== window || !data || data.__inkwellExternal !== true || data.extensionId !== STORE_ID) return;
    const reply = (response) => window.postMessage({ __inkwellReply: true, extensionId: STORE_ID, id: data.id, response }, "*");
    try {
      const result = api.runtime.sendMessage({ __inkwellExternal: true, origin: location.origin, url: location.href, message: data.message });
      if (result && typeof result.then === "function") result.then(reply, () => reply(undefined));
    } catch (e) {
      reply(undefined);
    }
  });
})();
"""#
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

        switch command {
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
            let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
            // Keep it in a window (invisible) so the page isn't suspended.
            webView.alpha = 0
            webView.isUserInteractionEnabled = false
            webView.frame.origin = CGPoint(x: -2000, y: -2000)
            WindowRegistry.shared.focusedOrAny?.view.addSubview(webView)
            webView.load(URLRequest(url: url))
            offscreenDocuments[key] = webView
            reply(success(nil))

        case "offscreen.close":
            offscreenDocuments.removeValue(forKey: key)?.removeFromSuperview()
            reply(success(nil))

        case "offscreen.has":
            reply(success(offscreenDocuments[key] != nil))

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
