// Jump To bar widget: a bar button that toggles the switcher overlay.
//
// The overlay stays owned by the shell's panel loader (the plugin keeps its
// "overlay" kind), so this button just fires the same IPC toggle the keybind
// and the menu row use.

import QtQuick
import qs.Ui

BarWidget {
  id: root
  moduleName: "dev.cstav.omarchy.plugin.jump-to"

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    // nf-md window-restore: two overlapping windows. Chosen from the bar
    // font's charset (JetBrainsMono Nerd Font covers F400-F533); the README's
    // menu-row icon U+F59F falls outside it and renders as a box in the bar.
    text: "\uf4bb"
    tooltipText: "Jump To"
    horizontalMargin: 7.5
    onPressed: function(pressedButton) {
      if (!root.bar) return
      if (pressedButton === Qt.LeftButton)
        root.bar.run("omarchy-shell -q shell toggle dev.cstav.omarchy.plugin.jump-to")
    }
  }
}
