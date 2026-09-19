import Quickshell
import QtQuick
import Quickshell.Io

// The data half of the plugin: runs the collector on a timer and publishes
// its record to the Agents usage directory.
//
// This exists because nothing else will do it. omarchy-agent-usage-update
// only globs $OMARCHY_PATH/bin/omarchy-agent-usage-*, so a third-party
// collector is never scheduled by the shell — and, by the same token, never
// has its record deleted. Publishing is therefore a plugin responsibility.
//
// One record feeds two surfaces: the built-in Agents panel adopts it because
// the filename is the agent id, and this plugin's own Panel.qml reads the
// identical file. There is exactly one data path.
Item {
  id: root
  visible: false

  // Injected by the shell for service-kind plugins.
  property var shell: null
  property var manifest: null

  readonly property string pluginId: "lasswellt.copilot"
  readonly property string updateScript: Qt.resolvedUrl("bin/copilot-usage-update").toString().replace(/^file:\/\//, "")

  // The interval is a bar-widget setting, because that is where the settings
  // UI puts it — but the collector runs from here whether or not the widget
  // is in the bar. Walk the bar layout for our own entry; fall back to the
  // manifest default, then to a sane one, so a plugin installed without its
  // widget still refreshes.
  //
  // shell.barConfig is a deep copy handed over when the plugin's shell API is
  // built (shell.qml, createScopedPluginShell → publicBarConfig()), assigned
  // once rather than bound. A changed interval therefore takes effect at the
  // next shell reload, not the moment it is saved. Acceptable for a number
  // measured in minutes; worth knowing before someone files it as a bug.
  readonly property int refreshIntervalSec: {
    var configured = barEntrySetting("refreshIntervalSec")
    if (configured === undefined) configured = manifestDefault("refreshIntervalSec")
    var seconds = Number(configured)
    if (!isFinite(seconds) || seconds <= 0) seconds = 900
    // Below a minute is pointless: the collector spawns a runtime and walks
    // the database, and the quota it reports moves on the scale of requests.
    return Math.max(60, Math.round(seconds))
  }

  function barEntrySetting(name) {
    var config = shell && shell.barConfig ? shell.barConfig : null
    var layout = config && config.layout ? config.layout : null
    if (!layout) return undefined
    var sections = ["left", "center", "right"]
    for (var s = 0; s < sections.length; s++) {
      var entries = layout[sections[s]]
      if (!Array.isArray(entries)) continue
      for (var i = 0; i < entries.length; i++) {
        var entry = entries[i]
        if (entry && String(entry.id) === root.pluginId && entry[name] !== undefined && entry[name] !== null)
          return entry[name]
      }
    }
    return undefined
  }

  function manifestDefault(name) {
    var widget = manifest && manifest.barWidget ? manifest.barWidget : null
    var defaults = widget && widget.defaults ? widget.defaults : null
    return defaults ? defaults[name] : undefined
  }

  // ------------------------------------------------------------ publishing

  Process {
    id: updateProcess
    running: false
    command: [root.updateScript]

    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (text.trim() !== "") console.warn("copilot", text.trim())
    }
  }

  function publish() {
    // A run already in flight is the run we wanted; a second one would only
    // queue behind the same database and the same runtime.
    if (!updateProcess.running) updateProcess.running = true
  }

  Timer {
    interval: root.refreshIntervalSec * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.publish()
  }

  // A collector that could not reach GitHub at all — typically the seconds
  // after login, before the network is up — says so in the record it still
  // writes. Honor that with one sooner try instead of waiting out the whole
  // interval. A run that reaches the endpoint clears the flag, which stops
  // this timer on the next file change.
  Timer {
    id: retryTimer
    interval: 30000
    repeat: false
    onTriggered: root.publish()
  }

  FileView {
    path: root.recordPath
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      var advised = false
      try {
        var record = JSON.parse(String(text() || ""))
        advised = !!(record && record.retryAdvised === true)
      } catch (e) {
        advised = false
      }
      if (advised) retryTimer.restart()
      else retryTimer.stop()
    }
  }

  readonly property string recordPath: {
    var state = Quickshell.env("XDG_STATE_HOME")
    if (!state || state === "") state = Quickshell.env("HOME") + "/.local/state"
    return state + "/omarchy/agents/usage/copilot.json"
  }

  // `omarchy-shell lasswellt.copilot.data refresh` — a manual kick that does
  // not need the panel open, and the hook a future `omarchy` subcommand or a
  // post-session hook would use.
  IpcHandler {
    target: "lasswellt.copilot.data"

    function refresh(): void { root.publish() }
  }
}
