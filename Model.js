// Pure helpers for the Jump To overlay: they turn `hyprctl clients -j` into the
// two-level row model the panel paints, name apps the way a human would, and
// score the flat search. Kept out of JumpTo.qml so the QML file stays
// declarative, the way omarchy's own panels split Model.js from Panel.qml.

// Browsers launch web apps under a class of "<browser>-<site>__-<profile>".
var WEBAPP_CLASS = /^(brave|brave-browser|chromium|google-chrome|chrome|msedge|microsoft-edge|firefox|zen)-(.+?)(?:__.*)?$/
var PROFILE_SUFFIX = /__-?.*$/
// omarchy installs a web app as `Exec=omarchy-launch-webapp <url>`, which
// reaches the browser as `--app=<url>`. Both forms name the URL the browser
// then builds the window class from; any other Exec launches something that is
// not a web app and must not be matched against a class.
var WEBAPP_EXEC = /omarchy-launch-webapp|--app=/
// Userinfo and port are left out of the capture: the class carries the host on
// its own.
var WEBAPP_EXEC_HOST = /https?:\/\/(?:[^\/@\s]*@)?([A-Za-z0-9.-]+)/

function titleCase(value) {
  return String(value).replace(/[-_.]+/g, " ").trim()
    .replace(/\b[a-z]/g, function (c) { return c.toUpperCase() })
}

// The site a browser wrote into a web-app window class, or "" for every other
// class including the browser's own windows, whose class carries no site. A dot
// is what tells the two apart. Lowercased so it can be compared against a host
// taken from a launcher's URL, which is stored however the user typed it.
function webappSite(cls) {
  var webapp = String(cls || "").match(WEBAPP_CLASS)
  if (!webapp || webapp[2].indexOf(".") === -1) return ""
  return webapp[2].replace(PROFILE_SUFFIX, "").toLowerCase()
}

// The site a .desktop entry opens as a web app, or "" for an entry that
// launches anything else. This is the only field tying an omarchy web app back
// to its window: the installer writes no StartupWMClass, so the desktop
// database has no class to index the entry under, while the browser derives the
// class from this very URL's host.
function webappLaunchSite(execString) {
  var value = String(execString || "")
  if (!WEBAPP_EXEC.test(value)) return ""
  var url = value.match(WEBAPP_EXEC_HOST)
  return url ? url[1].toLowerCase() : ""
}

// The window class is a launcher detail; a switcher should read like the app's
// name. Only reached when the caller's desktop-entry lookups all came up empty,
// which for a web app means one whose Exec hides the URL behind a handler
// script.
function prettyClass(cls) {
  var value = String(cls || "").trim()
  if (!value) return "Unknown"
  // A web app's class keeps the site in it, and a site reads better as itself
  // than title-cased: "web.whatsapp.com", not "Web Whatsapp Com".
  var site = webappSite(value)
  if (site) return site
  value = value.replace(PROFILE_SUFFIX, "")
  // Reverse-DNS ids (org.omarchy.agent, com.mitchellh.ghostty) name the app in
  // their last segment; anything else is already the name, just punctuated.
  var segments = value.split(".")
  if (segments.length >= 3) value = segments[segments.length - 1]
  return titleCase(value)
}

// The browser a web-app class was launched from, or "" for anything else,
// including the browser's own windows, whose class has no site in it.
function browserOf(cls) {
  var webapp = String(cls || "").match(WEBAPP_CLASS)
  if (!webapp || webapp[2].indexOf(".") === -1) return ""
  return webapp[1]
}

function parseClients(raw) {
  var list = []
  try { list = JSON.parse(String(raw || "[]")) } catch (e) { return [] }
  if (!Array.isArray(list)) return []

  var out = []
  for (var i = 0; i < list.length; i++) {
    var c = list[i]
    if (!c || !c.address) continue
    // An unmapped client has no surface to focus: Hyprland reports it while a
    // window is being torn down, and jumping to it does nothing.
    if (c.mapped === false) continue
    var cls = String(c.class || c.initialClass || "")
    out.push({
      address: String(c.address),
      cls: cls,
      group: (cls || "unknown").toLowerCase(),
      title: String(c.title || ""),
      workspace: (c.workspace && c.workspace.name !== undefined) ? String(c.workspace.name) : "",
      workspaceId: (c.workspace && c.workspace.id !== undefined) ? Number(c.workspace.id) : 0,
      floating: c.floating === true,
      // 0 is the focused window, 1 the one before it, and so on. Absent on old
      // Hyprland builds; sort those last rather than ahead of everything.
      history: (c.focusHistoryID === undefined) ? 99999 : Number(c.focusHistoryID)
    })
  }
  return out
}

// `resolve(cls)` is the caller's desktop-database lookup: it returns
// { name, icon } for a class it recognises, or null. Groups and the windows
// inside them come back in most-recently-used order.
function buildGroups(windows, resolve) {
  var byKey = ({})
  var order = []
  for (var i = 0; i < windows.length; i++) {
    var w = windows[i]
    if (!byKey[w.group]) {
      byKey[w.group] = { key: w.group, cls: w.cls, windows: [] }
      order.push(w.group)
    }
    byKey[w.group].windows.push(w)
  }

  var groups = []
  for (var j = 0; j < order.length; j++) {
    var g = byKey[order[j]]
    g.windows.sort(function (a, b) { return a.history - b.history })
    var meta = resolve ? resolve(g.cls) : null
    g.label = (meta && meta.name) ? String(meta.name) : prettyClass(g.cls)
    g.icon = (meta && meta.icon) ? String(meta.icon) : g.cls
    g.history = g.windows[0].history
    groups.push(g)
  }
  groups.sort(function (a, b) { return a.history - b.history })
  return groups
}

// The window you are already in is the one you never want to jump to, so it
// goes to the back of the list and the cursor starts on the previous one.
function demoteFocused(list) {
  if (list.length < 2) return list
  if (list[0].history !== 0) return list
  return list.slice(1).concat([list[0]])
}

function score(haystack, needle) {
  var h = String(haystack || "").toLowerCase()
  var n = String(needle || "").toLowerCase()
  if (!n) return 1
  var at = h.indexOf(n)
  if (at === 0) return 1000
  if (at > 0) {
    var before = h.charAt(at - 1)
    var atWordStart = before === " " || before === "." || before === "-" || before === "_" || before === "/"
    return (atWordStart ? 800 : 600) - Math.min(at, 200)
  }
  // Subsequence match, so "wapp" still finds "web.whatsapp.com".
  var i = 0
  for (var j = 0; j < h.length && i < n.length; j++) if (h.charAt(j) === n.charAt(i)) i++
  return i === n.length ? 100 : -1
}

function windowDetail(group, w, withApp) {
  var parts = []
  if (withApp) parts.push(group.label)
  if (w.workspace) parts.push(w.workspaceId < 0 ? w.workspace : "Workspace " + w.workspace)
  if (w.floating) parts.push("floating")
  return parts.join(" · ")
}

// Top level: one row per app. A single-window app jumps straight there; an app
// with several gets a chevron into its own list.
function topRows(groups) {
  var rows = []
  for (var i = 0; i < groups.length; i++) {
    var g = groups[i]
    var single = g.windows.length === 1
    rows.push({
      kind: single ? "window" : "group",
      key: g.key,
      address: single ? g.windows[0].address : "",
      label: g.label,
      detail: single ? windowDetail(g, g.windows[0], false) || g.windows[0].title
                     : g.windows.length + " windows",
      appIcon: g.icon,
      chevron: !single
    })
  }
  return rows
}

function groupWindowRows(group) {
  var rows = []
  var windows = demoteFocused(group.windows)
  for (var i = 0; i < windows.length; i++) {
    var w = windows[i]
    rows.push({
      kind: "window",
      key: w.address,
      address: w.address,
      label: w.title || group.label,
      detail: windowDetail(group, w, false),
      appIcon: group.icon,
      chevron: false
    })
  }
  return rows
}

// Searching flattens both levels: every window is a candidate, matched on its
// title, its app name, its class and its workspace, so a query never has to
// know which level the thing it wants lives on.
function searchRows(groups, query) {
  var scored = []
  for (var i = 0; i < groups.length; i++) {
    var g = groups[i]
    for (var j = 0; j < g.windows.length; j++) {
      var w = g.windows[j]
      var best = Math.max(
        score(g.label, query),
        score(w.title, query),
        score(g.cls, query),
        score(w.workspace ? "workspace " + w.workspace : "", query)
      )
      if (best < 0) continue
      scored.push({
        rank: best,
        history: w.history,
        row: {
          kind: "window",
          key: w.address,
          address: w.address,
          label: w.title || g.label,
          detail: windowDetail(g, w, true),
          appIcon: g.icon,
          chevron: false
        }
      })
    }
  }
  scored.sort(function (a, b) {
    if (b.rank !== a.rank) return b.rank - a.rank
    return a.history - b.history
  })
  var rows = []
  for (var k = 0; k < scored.length; k++) rows.push(scored[k].row)
  return rows
}
