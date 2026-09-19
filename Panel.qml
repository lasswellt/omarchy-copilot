import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// The display half of the plugin: a bar icon and a popup over the same usage
// record Service.qml publishes. It reads the published file rather than
// running the collector itself, so this panel and the built-in Agents panel
// always agree — there is one data path, and this is a second view of it.
Panel {
  id: root

  moduleName: "lasswellt.copilot"
  ipcTarget: "lasswellt.copilot"
  manageIpc: false

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property color track: Style.selectedFillFor(foreground, Color.accent)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // Countdowns and "updated" read this instead of Date.now(), so an open
  // panel keeps telling the truth rather than freezing at the moment it
  // opened.
  property double nowMs: Date.now()

  // ------------------------------------------------------------- the record

  property var record: null

  readonly property string recordPath: {
    var state = Quickshell.env("XDG_STATE_HOME")
    if (!state || state === "") state = Quickshell.env("HOME") + "/.local/state"
    return state + "/omarchy/agents/usage/copilot.json"
  }

  FileView {
    path: root.recordPath
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      try {
        var parsed = JSON.parse(String(text() || ""))
        root.record = parsed && typeof parsed === "object" ? parsed : null
      } catch (e) {
        console.warn("copilot", "ignoring bad usage record", root.recordPath, e)
        root.record = null
      }
    }
    onLoadFailed: root.record = null
  }

  function value(name, fallback) {
    if (!record || record[name] === undefined || record[name] === null) return fallback
    return record[name]
  }

  function numberValue(raw) {
    var parsed = Number(raw)
    return isFinite(parsed) && parsed > 0 ? parsed : 0
  }

  function clamp(value, low, high) { return Math.max(low, Math.min(high, value)) }
  function alpha(color, amount) { return Qt.rgba(color.r, color.g, color.b, amount) }

  readonly property var limits: {
    var raw = value("limits", [])
    return Array.isArray(raw) ? raw : []
  }
  readonly property var days: {
    var raw = value("recentDays", [])
    return Array.isArray(raw) ? raw : []
  }

  // The fullest window drives the bar icon's alarm state, the same way the
  // Agents panel picks a headline: whichever allowance is closest to spent
  // is the one worth walking over to look at.
  readonly property var headline: {
    var best = null
    for (var i = 0; i < limits.length; i++) {
      var entry = limits[i]
      if (!entry) continue
      if (!best || Number(entry.percent) > Number(best.percent)) best = entry
    }
    return best
  }
  readonly property bool alarming: !!headline && Number(headline.percent) >= 0.9

  readonly property string statusText: String(value("usageStatusText", ""))
  readonly property string authHelpText: String(value("authHelpText", ""))

  // Tokens per model, heaviest first, so the chart's scale-to-peak has a
  // stable top row.
  readonly property var models: {
    var usage = value("modelUsage", {})
    var rows = []
    for (var name in usage) {
      var bucket = usage[name] || {}
      var input = numberValue(bucket.inputTokens)
      var output = numberValue(bucket.outputTokens)
      var cacheRead = numberValue(bucket.cacheReadInputTokens)
      var cacheWrite = numberValue(bucket.cacheCreationInputTokens)
      var total = input + output + cacheRead + cacheWrite
      if (total <= 0) continue
      rows.push({ name: name, total: total, input: input, output: output,
                  cacheRead: cacheRead, cacheWrite: cacheWrite })
    }
    rows.sort(function(a, b) { return b.total - a.total })
    return rows
  }

  readonly property real weekPeak: {
    var peak = 0
    for (var i = 0; i < days.length; i++)
      peak = Math.max(peak, numberValue(days[i] ? days[i].messageCount : 0))
    return peak
  }

  // Copilot rates every call in nano-AI-units and calls the result "AI
  // credits" in its own UI. No other agent on this machine reports a cost
  // figure, which is the whole reason this panel exists alongside the
  // built-in one. Absent from an older record, hence the guard.
  readonly property var credits: {
    var raw = value("aiCredits", null)
    return raw && typeof raw === "object" ? raw : null
  }

  // Nothing to report, nothing in the bar. Bar.qml collapses a slot whose
  // item is invisible, so a machine that has never run Copilot draws nothing
  // and the icon arrives on its own after the first scan finds usage.
  readonly property bool hasData: numberValue(value("totalPrompts", 0)) > 0
    || numberValue(value("totalSessions", 0)) > 0
    || numberValue(value("activeDays", 0)) > 0
    || limits.length > 0

  visible: hasData
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  // ------------------------------------------------------------- formatting

  function formatTokenCount(value) {
    var count = Number(value)
    if (!isFinite(count) || count <= 0) return "0"
    if (count >= 1000000) return (count / 1000000).toFixed(count >= 10000000 ? 0 : 1) + "M"
    if (count >= 1000) return (count / 1000).toFixed(count >= 10000 ? 0 : 1) + "k"
    return String(Math.round(count))
  }

  function formatCredits(value) {
    var amount = Number(value)
    if (!isFinite(amount) || amount <= 0) return "0"
    if (amount >= 100) return String(Math.round(amount))
    if (amount >= 10) return amount.toFixed(1)
    return amount.toFixed(2)
  }

  function formatDuration(ms) {
    var minutes = Math.floor(ms / 60000)
    if (minutes < 60) return Math.max(1, minutes) + "m"
    var hours = Math.floor(minutes / 60)
    if (hours < 48) return hours + "h " + (minutes % 60) + "m"
    return Math.floor(hours / 24) + "d " + (hours % 24) + "h"
  }

  function resetMsFor(limit) {
    if (!limit || !limit.resetsAt) return 0
    var at = Date.parse(String(limit.resetsAt))
    if (!isFinite(at)) return 0
    return Math.max(0, at - root.nowMs)
  }

  function todayDate() {
    var now = new Date()
    return now.getFullYear() + "-"
      + ("0" + (now.getMonth() + 1)).slice(-2) + "-"
      + ("0" + now.getDate()).slice(-2)
  }

  function dayLabel(date, isToday) {
    if (isToday) return "Today"
    var parsed = Date.fromLocaleDateString(Qt.locale(), String(date || ""), "yyyy-MM-dd")
    if (isNaN(parsed.getTime())) return String(date || "")
    return parsed.toLocaleDateString(Qt.locale(), "ddd")
  }

  function heroMeta() {
    if (statusText !== "") return statusText
    var tier = String(value("tierLabel", ""))
    return tier !== "" ? tier : "GitHub Copilot"
  }

  function heroDetail() {
    var prompts = numberValue(value("todayPrompts", 0))
    var sessions = numberValue(value("todaySessions", 0))
    if (prompts <= 0 && sessions <= 0) return "Nothing yet today"
    var parts = []
    if (prompts > 0) parts.push(prompts + (prompts === 1 ? " prompt" : " prompts"))
    if (sessions > 0) parts.push(sessions + (sessions === 1 ? " session" : " sessions"))
    return parts.join(" · ") + " today"
  }

  function dayTooltip(day, isToday) {
    if (!day) return ""
    var tokens = formatTokenCount(numberValue(day.messageCount))
    if (!isToday) return tokens + " tokens"
    var prompts = numberValue(value("todayPrompts", 0))
    var sessions = numberValue(value("todaySessions", 0))
    return tokens + " tokens · " + prompts + " prompts · " + sessions + " sessions"
  }

  function modelTooltip(row) {
    if (!row) return ""
    return "In " + formatTokenCount(row.input)
      + " · out " + formatTokenCount(row.output)
      + " · cache read " + formatTokenCount(row.cacheRead)
      + " · cache write " + formatTokenCount(row.cacheWrite)
  }

  function updatedText() {
    var at = Date.parse(String(value("updatedAt", "")))
    if (!isFinite(at)) return ""
    var ageMs = Math.max(0, root.nowMs - at)
    if (ageMs < 90000) return "Updated just now"
    return "Updated " + formatDuration(ageMs) + " ago"
  }

  // -------------------------------------------------------------- behavior

  // The panel refreshes by running the same publisher the service runs on
  // its timer. Both write the same file, and the FileView above picks the
  // result up — so a manual refresh and a scheduled one are the same event.
  readonly property string updateScript: Qt.resolvedUrl("bin/copilot-usage-update").toString().replace(/^file:\/\//, "")

  Process {
    id: refreshProcess
    running: false

    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (text.trim() !== "") console.warn("copilot", text.trim())
    }
  }

  // Opening the panel wants the number that goes stale on the wire — the
  // quota — not another walk over every session on disk, so it asks for
  // --limits-only and the collector reuses a recent scan. Pressing `r` means
  // "I do not believe you", and gets the full rescan.
  function refreshNow(force) {
    if (refreshProcess.running) return
    refreshProcess.command = [root.updateScript, force === true ? "--force" : "--limits-only"]
    refreshProcess.running = true
  }

  function launchCopilot() {
    if (root.bar) root.bar.run("omarchy-launch-or-focus-tui copilot")
    root.close()
  }

  onOpenedChanged: if (opened) {
    nowMs = Date.now()
    if (panelFlick) panelFlick.contentY = 0
    refreshNow(false)
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  // Only while the panel is open: it re-evaluates a handful of text
  // bindings, and a countdown frozen at the moment you opened the panel is
  // worse than a timer.
  Timer {
    interval: 30000
    running: root.opened
    repeat: true
    onTriggered: root.nowMs = Date.now()
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { root.refreshNow(true); return "ok" }

    // The headline numbers, for scripting — a status bar of your own, a
    // prompt segment, a notification when the allowance runs low. Reads the
    // record already in memory, so it costs nothing and never blocks.
    function status(): string {
      return JSON.stringify({
        tier: String(root.value("tierLabel", "")),
        limit: root.headline ? String(root.headline.label) : "",
        percentUsed: root.headline ? Math.round(Number(root.headline.percent) * 100) : -1,
        resetsAt: root.headline ? String(root.headline.resetsAt || "") : "",
        todayPrompts: root.numberValue(root.value("todayPrompts", 0)),
        todayTokens: root.numberValue(root.value("todayTotalTokens", 0)),
        creditsToday: root.credits ? Number(root.credits.today) : 0,
        status: root.statusText,
        updatedAt: String(root.value("updatedAt", ""))
      })
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    // The GitHub mark: the oldest and most widely present Copilot-adjacent
    // glyph in Nerd Fonts, so it renders on whatever the bar font is.
    text: ""
    active: root.alarming
    tooltipText: {
      var tier = String(root.value("tierLabel", ""))
      var head = "Copilot" + (tier !== "" ? " · " + tier : "")
      if (root.statusText !== "") return head + " · " + root.statusText
      if (root.headline)
        return head + " · " + Math.round(Number(root.headline.percent) * 100) + "% of "
          + String(root.headline.label).toLowerCase() + " used"
      return head
    }
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) root.launchCopilot()
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(360))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(600))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent

      onMoveRequested: function(dx, dy) {
        if (dy !== 0)
          panelFlick.contentY = root.clamp(panelFlick.contentY + dy * Style.space(56), 0,
                                           Math.max(0, panelFlick.contentHeight - panelFlick.height))
      }
      onActivateRequested: root.refreshNow(true)
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "r" || t === "R") root.refreshNow(true)
        else if (t === "o" || t === "O") root.launchCopilot()
      }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: panelFlick.width
          spacing: Style.space(12)

          // ---------- Hero ----------
          PanelHero {
            width: parent.width
            title: "Copilot"
            meta: root.heroMeta()
            detail: root.heroDetail()
            foreground: root.foreground
            fontFamily: root.fontFamily

            iconComponent: Component {
              Text {
                textFormat: Text.PlainText
                text: ""
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.display
              }
            }
          }

          // ---------- Auth / error card ----------
          //
          // Sits between the hero and the numbers: the local stats below are
          // still real when the runtime is unreachable, and this says why the
          // meters are missing rather than leaving a blank where they were.
          Rectangle {
            id: statusCard
            visible: root.authHelpText !== "" && root.statusText !== ""
            width: parent.width
            implicitHeight: statusMessage.implicitHeight + Style.spacing.md * 2
            radius: Style.cornerRadius
            color: root.alpha(root.foreground, 0.05)

            Text {
              id: statusMessage
              textFormat: Text.PlainText
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              anchors.leftMargin: Style.space(10)
              anchors.rightMargin: Style.space(10)
              text: root.authHelpText
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }
          }

          // ---------- Limits ----------
          PanelSeparator {
            visible: limitsSection.visible
            foreground: root.foreground
          }

          Column {
            id: limitsSection
            visible: root.limits.length > 0
            width: parent.width
            spacing: Style.spacing.md

            PanelSectionHeader {
              width: parent.width
              text: "LIMITS"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Repeater {
              model: root.limits

              LimitRow {
                required property var modelData
                width: limitsSection.width
                limit: modelData
              }
            }
          }

          // ---------- AI credits ----------
          PanelSeparator {
            visible: creditsSection.visible
            foreground: root.foreground
          }

          Column {
            id: creditsSection
            visible: !!root.credits && root.numberValue(root.credits.total) > 0
            width: parent.width
            spacing: Style.spacing.md

            PanelSectionHeader {
              width: parent.width
              text: "AI CREDITS"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Item {
              width: parent.width
              implicitHeight: Math.max(creditsLabel.implicitHeight, creditsValue.implicitHeight)

              Text {
                id: creditsLabel
                textFormat: Text.PlainText
                text: "Rated cost on this machine"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
                anchors.left: parent.left
                anchors.right: creditsValue.left
                anchors.rightMargin: Style.spacing.sm
                anchors.verticalCenter: parent.verticalCenter
              }

              Text {
                id: creditsValue
                textFormat: Text.PlainText
                text: root.credits
                  ? root.formatCredits(root.credits.today) + " today · "
                    + root.formatCredits(root.credits.total) + " all time"
                  : ""
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
              }
            }
          }

          // ---------- Tokens by day ----------
          PanelSeparator {
            visible: daysSection.visible
            foreground: root.foreground
          }

          Column {
            id: daysSection
            visible: root.days.length > 0 && root.weekPeak > 0
            width: parent.width
            spacing: Style.spacing.md

            PanelSectionHeader {
              width: parent.width
              text: "TOKENS BY DAY"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Repeater {
              model: root.days

              DayRow {
                required property var modelData
                width: daysSection.width
                day: modelData
                ratio: root.numberValue(modelData.messageCount) / Math.max(1, root.weekPeak)
                // By date, not by position: a record written before midnight
                // and read after it still has to point at the right row.
                today: String(modelData.date || "") === root.todayDate()
              }
            }
          }

          // ---------- Tokens by model ----------
          PanelSeparator {
            visible: modelsSection.visible
            foreground: root.foreground
          }

          Column {
            id: modelsSection
            visible: root.models.length > 0
            width: parent.width
            spacing: Style.spacing.md

            PanelSectionHeader {
              width: parent.width
              text: "TOKENS BY MODEL"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Repeater {
              model: root.models

              ModelRow {
                required property var modelData
                width: modelsSection.width
                row: modelData
                // Scaled to the heaviest model, so the top row is always
                // full and the rest read as a share of it.
                share: modelData.total / Math.max(1, root.models[0].total)
              }
            }
          }

          Text {
            textFormat: Text.PlainText
            visible: text !== ""
            width: parent.width
            topPadding: Style.space(2)
            text: root.updatedText()
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            horizontalAlignment: Text.AlignHCenter
            elide: Text.ElideRight
          }
        }
      }
    }
  }

  // One allowance: label and percentage used, a meter, and the countdown to
  // the window rolling over.
  component LimitRow: Column {
    id: limitRow
    property var limit: null

    readonly property real percent: limitRow.limit ? Number(limitRow.limit.percent) : -1
    readonly property bool alarming: percent >= 0.9

    spacing: Style.space(6)

    Item {
      width: parent.width
      implicitHeight: Math.max(limitLabel.implicitHeight, limitValue.implicitHeight)

      Text {
        id: limitLabel
        textFormat: Text.PlainText
        text: limitRow.limit ? String(limitRow.limit.label || "") : ""
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        elide: Text.ElideRight
        anchors.left: parent.left
        anchors.right: limitValue.left
        anchors.rightMargin: Style.spacing.sm
        anchors.verticalCenter: parent.verticalCenter
      }

      Text {
        id: limitValue
        textFormat: Text.PlainText
        text: limitRow.percent >= 0 ? Math.round(limitRow.percent * 100) + "%" : "—"
        color: limitRow.alarming ? root.urgent : root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
      }
    }

    Meter {
      width: parent.width
      value: limitRow.percent
      alarming: limitRow.alarming
    }

    Text {
      textFormat: Text.PlainText
      width: parent.width
      text: {
        var remainingMs = root.resetMsFor(limitRow.limit)
        return remainingMs > 0 ? "Resets in " + root.formatDuration(remainingMs) : ""
      }
      visible: text !== ""
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }
  }

  // Rounded track showing the share of an allowance already spent.
  component Meter: Item {
    id: meter
    property real value: -1
    property bool alarming: false
    property real thickness: Math.max(Style.space(4), Math.round(Style.spacing.controlHeight * 0.14))

    implicitHeight: thickness

    Rectangle {
      id: meterTrack
      anchors.fill: parent
      radius: height / 2
      color: root.track
    }

    Rectangle {
      anchors.left: meterTrack.left
      anchors.verticalCenter: meterTrack.verticalCenter
      height: meterTrack.height
      radius: meterTrack.radius
      width: meterTrack.width * root.clamp(meter.value, 0, 1)
      color: meter.alarming ? root.urgent : root.foreground

      Behavior on width {
        NumberAnimation { duration: 160; easing.type: Easing.OutCubic }
      }
    }
  }

  // One row per day: label, bar, tokens. Today is picked out in full
  // foreground so the week reads as a run-up to right now.
  component DayRow: Item {
    id: dayRow
    property var day: null
    property real ratio: 0
    property bool today: false

    implicitHeight: Math.max(dayLabel.implicitHeight, dayValue.implicitHeight) + Style.spacing.sm

    Text {
      id: dayLabel
      textFormat: Text.PlainText
      text: root.dayLabel(dayRow.day ? dayRow.day.date : "", dayRow.today)
      color: dayRow.today ? root.foreground : root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: dayRow.today
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(52)
    }

    Rectangle {
      id: dayTrack
      anchors.left: dayLabel.right
      anchors.right: dayValue.left
      anchors.leftMargin: Style.space(8)
      anchors.rightMargin: Style.space(10)
      anchors.verticalCenter: parent.verticalCenter
      height: Math.max(Style.space(4), Math.round(Style.spacing.controlHeight * 0.14))
      radius: height / 2
      color: root.track

      Rectangle {
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        height: parent.height
        radius: parent.radius
        width: parent.width * root.clamp(dayRow.ratio, 0, 1)
        color: dayRow.today ? root.foreground : root.alpha(root.foreground, 0.55)

        Behavior on width {
          NumberAnimation { duration: 160; easing.type: Easing.OutCubic }
        }
      }
    }

    Text {
      id: dayValue
      textFormat: Text.PlainText
      text: root.formatTokenCount(dayRow.day ? dayRow.day.messageCount : 0)
      color: dayRow.today ? root.foreground : root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: true
      horizontalAlignment: Text.AlignRight
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(52)
    }

    MouseArea {
      id: dayHover
      anchors.fill: parent
      hoverEnabled: true
      acceptedButtons: Qt.NoButton
    }

    PanelToolTip {
      visible: dayHover.containsMouse
      text: root.dayTooltip(dayRow.day, dayRow.today)
      fontFamily: root.fontFamily
    }
  }

  // Model rows read as a table: the share bar fills the row behind the label
  // instead of stacking under it, which keeps the panel on one screen.
  component ModelRow: Item {
    id: modelRow
    property var row: null
    property real share: 0

    implicitHeight: modelName.implicitHeight + Style.spacing.lg

    Rectangle {
      anchors.fill: parent
      radius: Style.cornerRadius
      color: root.alpha(root.foreground, 0.05)
    }

    Rectangle {
      anchors.left: parent.left
      anchors.top: parent.top
      anchors.bottom: parent.bottom
      width: parent.width * root.clamp(modelRow.share, 0, 1)
      radius: Style.cornerRadius
      color: root.alpha(root.foreground, 0.14)

      Behavior on width {
        NumberAnimation { duration: 160; easing.type: Easing.OutCubic }
      }
    }

    Text {
      id: modelName
      textFormat: Text.PlainText
      text: modelRow.row ? modelRow.row.name : ""
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      elide: Text.ElideRight
      anchors.left: parent.left
      anchors.leftMargin: Style.space(8)
      anchors.right: modelTokens.left
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
    }

    Text {
      id: modelTokens
      textFormat: Text.PlainText
      text: modelRow.row ? root.formatTokenCount(modelRow.row.total) : ""
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      font.bold: true
      anchors.right: parent.right
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
    }

    MouseArea {
      id: modelHover
      anchors.fill: parent
      hoverEnabled: true
      acceptedButtons: Qt.NoButton
    }

    PanelToolTip {
      visible: modelHover.containsMouse
      text: root.modelTooltip(modelRow.row)
      fontFamily: root.fontFamily
    }
  }
}
