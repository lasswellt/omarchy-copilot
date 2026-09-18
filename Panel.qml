import QtQuick
import qs.Commons
import qs.Ui

// Stub bar widget. Proves the plugin loads and renders; carries no real
// Copilot data yet. See README for what's next.
Panel {
  id: root

  moduleName: "lasswellt.copilot"
  ipcTarget: "lasswellt.copilot"

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  WidgetButton {
    id: button
    anchors.top: parent.top
    anchors.bottom: parent.bottom
    bar: root.bar
    text: "GH"
    tooltipText: "Copilot (stub — not wired up yet)"
  }
}
