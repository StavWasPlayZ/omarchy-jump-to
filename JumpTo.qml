// Jump To: a searchable window switcher for the omarchy shell.
//
// Opens as an overlay styled off the [menu] theme surface, so it looks and
// keys like the omarchy menu itself: type to filter, ↑/↓ to move, → or Enter
// to go in, ← or Backspace to come back, Esc to leave.
//
// Two levels. The first lists every app that has a window open, most recently
// used first, with the window you are currently in pushed to the back. An app
// with one window jumps straight to it; an app with several shows a chevron
// into its own window list. Typing flattens both levels into one ranked list.
//
// Ctrl+B on a window row sends that window to a workspace and follows it
// there. One digit covers workspaces 1-9; Ctrl+Shift+B collects digits until
// Enter, for anything higher. A hint line under the list says which keys are
// live.
//
// Window data comes from `hyprctl clients -j` rather than Quickshell's
// Hyprland.toplevels. focusHistoryID only exists in the IPC payload, and the
// MRU ordering here is built from it.

import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland
import QtQuick
import qs.Commons
import qs.Ui
import "Model.js" as Model

Item {
  id: root

  // Injected by the shell's panel loader when this plugin is summoned.
  property string omarchyPath: Quickshell.env("OMARCHY_PATH")
  property var shell: null
  property var manifest: null

  // Shared application engine, for turning a window class into the .desktop
  // entry's name and icon.
  readonly property var appLibrary: root.shell ? root.shell.appLibrary : null

  property bool opened: false
  property string filterText: ""
  property int selectedIndex: 0
  property bool cursorActive: false
  // "" is the app list; otherwise the group key being drilled into.
  property string activeGroup: ""
  property var groups: []
  property bool loaded: false
  // Armed by Ctrl+B on a window row. "single" takes the next digit as the
  // whole workspace number; "multi" collects digits until Enter, so anything
  // past workspace 9 is still reachable. A group row has no one window to
  // move, so it never arms either.
  property string moveMode: ""
  property string movePending: ""

  // ------------------------------------------------------------- lifecycle

  function open(payloadJson) {
    root.filterText = ""
    root.selectedIndex = 0
    root.activeGroup = ""
    root.cancelMove()
    root.cursorActive = true
    // Drop the rows from the previous summon: this plugin is keepLoaded, and
    // rebuildDisplay's selection-preserving pass would otherwise restore the
    // cursor to whatever was picked last time instead of the MRU window.
    displayModel.clear()
    if (root.appLibrary) root.appLibrary.refreshIcons()
    root.reload()
    root.opened = true
    Qt.callLater(function () { keyCatcher.forceActiveFocus() })
  }

  function close() {
    root.opened = false
    root.filterText = ""
    root.activeGroup = ""
    root.cancelMove()
  }

  function toggle() {
    if (root.opened) root.close()
    else root.open("{}")
  }

  function ping() { return "ok" }

  // ------------------------------------------------------------------ data

  function reload() {
    clientsProc.running = false
    clientsProc.running = true
  }

  // DesktopEntries indexes by StartupWMClass and by id, so most native apps
  // resolve; omarchy web apps get a class of their own with no entry behind
  // it, and Model.prettyClass names those.
  function lookupEntry(value) {
    if (!value) return null
    try { return DesktopEntries.heuristicLookup(String(value)) } catch (e) { return null }
  }

  function resolveClass(cls) {
    var entry = root.lookupEntry(cls)
    if (entry) return { name: entry.name, icon: entry.icon }
    // The browser hosting a web app still gives the row a real icon instead of
    // the generic placeholder, while Model.prettyClass keeps the site as the
    // name.
    var browser = root.lookupEntry(Model.browserOf(cls))
    if (browser) return { name: "", icon: browser.icon }
    return null
  }

  function applyClients(raw) {
    var windows = Model.parseClients(raw)
    root.groups = Model.buildGroups(windows, root.resolveClass)
    root.loaded = true
    // A drilled-into app whose last window just closed has nowhere to be.
    if (root.activeGroup && !root.groupFor(root.activeGroup)) root.activeGroup = ""
    root.rebuildDisplay()
  }

  function groupFor(key) {
    for (var i = 0; i < root.groups.length; i++)
      if (root.groups[i].key === key) return root.groups[i]
    return null
  }

  function currentRows() {
    if (root.filterText) return Model.searchRows(root.groups, root.filterText)
    if (root.activeGroup) {
      var group = root.groupFor(root.activeGroup)
      return group ? Model.groupWindowRows(group) : []
    }
    return Model.topRows(Model.demoteFocused(root.groups))
  }

  function rebuildDisplay() {
    var rows = root.currentRows()
    // Keep the cursor on the row it was on where the row still exists, so a
    // window closing elsewhere does not move the selection under the hand.
    var previousKey = root.selectedIndex >= 0 && root.selectedIndex < displayModel.count
      ? displayModel.get(root.selectedIndex).key : ""

    displayModel.clear()
    for (var i = 0; i < rows.length; i++) displayModel.append(rows[i])
    root.layoutSerial++

    var next = 0
    if (previousKey) {
      for (var j = 0; j < displayModel.count; j++)
        if (displayModel.get(j).key === previousKey) { next = j; break }
    }
    root.selectedIndex = Math.min(next, Math.max(0, displayModel.count - 1))
    resultList.positionViewAtIndex(root.selectedIndex, ListView.Contain)
  }

  // ---------------------------------------------------------- interactions

  function setFilter(value) {
    root.filterText = value
    root.selectedIndex = 0
    root.cursorActive = true
    root.rebuildDisplay()
    resultList.positionViewAtBeginning()
  }

  function select(delta) {
    if (displayModel.count === 0) return
    root.cursorActive = true
    var next = root.selectedIndex + delta
    // Wrap, so ↑ from the first row reaches the least recently used window.
    if (next < 0) next = displayModel.count - 1
    else if (next >= displayModel.count) next = 0
    root.selectedIndex = next
    resultList.positionViewAtIndex(next, ListView.Contain)
  }

  function goBack() {
    if (!root.activeGroup) { root.close(); return }
    var leaving = root.activeGroup
    root.activeGroup = ""
    root.rebuildDisplay()
    // Come back onto the app you just backed out of, not onto row zero.
    for (var i = 0; i < displayModel.count; i++) {
      if (displayModel.get(i).key === leaving) {
        root.selectedIndex = i
        resultList.positionViewAtIndex(i, ListView.Contain)
        break
      }
    }
  }

  function focusAddress(address) {
    var target = String(address || "")
    if (!target) return
    // Hyprland's config language is Lua from 0.52 on. hyprctl exits 0 even when
    // it rejects a dispatcher, so the fallback to the classic syntax keys off
    // the reply text instead of the exit status.
    Quickshell.execDetached(["bash", "-c",
      'out=$(hyprctl dispatch "hl.dsp.focus({ window = \\"address:$1\\" })" 2>&1); '
      + '[ "$out" = ok ] || hyprctl dispatch focuswindow "address:$1" >/dev/null 2>&1',
      "omarchy-jump-to", target])
  }

  function selectedRow() {
    if (root.selectedIndex < 0 || root.selectedIndex >= displayModel.count) return null
    return displayModel.get(root.selectedIndex)
  }

  function beginMove(mode) {
    var row = root.selectedRow()
    if (!row || row.kind !== "window" || !row.address) return
    root.moveMode = mode
    root.movePending = ""
  }

  function cancelMove() {
    root.moveMode = ""
    root.movePending = ""
  }

  function commitMove() {
    var row = root.selectedRow()
    var workspace = root.movePending
    root.cancelMove()
    if (!row || row.kind !== "window" || !row.address || !workspace) return
    root.moveToWorkspace(row.address, workspace)
    root.close()
  }

  // Move first, then focus, both in one shell: two detached commands would race
  // and the focus could land before the window had moved. The move itself is
  // silent (follow = false) so the compositor does not switch to the target
  // workspace ahead of the window; the focus that follows is what takes you
  // there.
  function moveToWorkspace(address, workspace) {
    Quickshell.execDetached(["bash", "-c",
      'out=$(hyprctl dispatch "hl.dsp.window.move({ workspace = $2, window = \\"address:$1\\", follow = false })" 2>&1); '
      + '[ "$out" = ok ] || hyprctl dispatch movetoworkspacesilent "$2,address:$1" >/dev/null 2>&1; '
      + 'out=$(hyprctl dispatch "hl.dsp.focus({ window = \\"address:$1\\" })" 2>&1); '
      + '[ "$out" = ok ] || hyprctl dispatch focuswindow "address:$1" >/dev/null 2>&1',
      "omarchy-jump-to", String(address), String(workspace)])
  }

  function activateIndex(index) {
    if (index < 0 || index >= displayModel.count) return
    var row = displayModel.get(index)
    if (row.kind === "group") {
      root.activeGroup = row.key
      root.filterText = ""
      root.selectedIndex = 0
      root.rebuildDisplay()
      resultList.positionViewAtBeginning()
      return
    }
    if (row.kind !== "window") return
    root.focusAddress(row.address)
    root.close()
  }

  // Pointer hover only takes the cursor once the pointer has moved, so the card
  // opening under a resting pointer does not steal the selection the keyboard
  // just set.
  property real pointerX: -1
  property real pointerY: -1
  function disarmPointer() { root.pointerX = -1; root.pointerY = -1 }
  function selectFromPointer(index, item, position) {
    var x = item.x + position.x
    var y = item.y + position.y
    if (root.pointerX === x && root.pointerY === y) return
    root.pointerX = x
    root.pointerY = y
    root.cursorActive = true
    root.selectedIndex = index
  }

  // -------------------------------------------------------------- plumbing

  property Process clientsProc: Process {
    command: ["hyprctl", "clients", "-j"]
    stdout: StdioCollector {
      id: clientsOut
      waitForEnd: true
    }
    onExited: root.applyClients(clientsOut.text || "[]")
  }

  // A window closing or being renamed behind the overlay would otherwise leave
  // a row that jumps nowhere.
  Connections {
    target: Hyprland
    function onRawEvent(event) {
      if (!root.opened) return
      var name = String(event.name || "")
      if (name === "openwindow" || name === "closewindow" || name === "windowtitle"
          || name === "windowtitlev2" || name === "movewindow" || name === "movewindowv2")
        reloadDebounce.restart()
    }
  }

  property Timer reloadDebounce: Timer {
    interval: 80
    onTriggered: if (root.opened) root.reload()
  }

  ListModel { id: displayModel }

  // ----------------------------------------------------------------- theme

  // Shares the [menu] surface tokens, so a theme that styles the omarchy menu
  // styles this the same way. There is no separate palette here to drift.
  property string fontFamily: Style.font.menuFamily
  property color background: Color.menu.background
  property color foreground: Color.menu.text
  property color border: Color.menu.border
  property var borderSpec: Border.surfaceSpec("menu", "border", border, Math.max(1, Style.space(2)))
  property color scrim: Color.menu.scrim
  property color selectedBackground: Color.menu.selectedBackground
  property color selectedText: Color.menu.selectedText
  property color selectedBorder: Color.menu.selectedBorder
  property var selectedBorderSpec: Border.surfaceSpec("menu", "selected-border", selectedBorder, 0)
  readonly property real rowReservedBorderLeft: Border.left(selectedBorderSpec)
  readonly property real rowReservedBorderRight: Border.right(selectedBorderSpec)

  readonly property int cornerRadius: Style.cornerRadius
  property int contentMargin: Style.spacing.panelPadding
  property int headerHeight: Math.max(Style.space(34), Style.font.title + Style.spacing.controlPaddingY * 2)
  property int contentSpacing: Style.spacing.md
  property int rowHeight: Math.max(Style.space(58), Style.font.body + Style.font.caption + Style.spacing.rowPaddingX * 2)
  property int rowSpacing: Style.spacing.xs
  // How much of the first hidden row stays visible at the fold: enough to read
  // as a cut-off row, not as a bottom border.
  property int rowPeek: Math.round(rowHeight * 0.55)
  property int maxVisibleRows: 8
  property int layoutSerial: 0

  property int cardWidth: Math.min(Style.space(460), panel.width - Style.gapsOut * 2)
  readonly property int visibleRowsHeight: root.rowsHeight(layoutSerial, displayModel.count)
  function rowsHeight(serial, count) {
    var rows = Math.max(1, count)
    var shown = Math.min(rows, root.maxVisibleRows)
    var height = shown * root.rowHeight + Math.max(0, shown - 1) * root.rowSpacing
    if (rows > shown) height += root.rowSpacing + root.rowPeek
    return height
  }
  property int hintHeight: Math.max(Style.space(18), Style.font.bodySmall + Style.space(6))
  property int cardHeight: Math.min(
    contentMargin * 2 + headerHeight + contentSpacing + visibleRowsHeight
      + contentSpacing + hintHeight,
    panel.height - Style.gapsOut * 2)

  // What the keys do right now, shown in the card so nobody has to remember it.
  // Depends on selectedIndex/layoutSerial so it re-evaluates when the cursor
  // or the rows move; ListModel.count alone would not repaint it.
  readonly property string hintText: root.hintFor(root.moveMode, root.selectedIndex,
                                                  root.layoutSerial, root.cursorActive)
  function hintFor(mode, index, serial, active) {
    if (mode === "single") return "Type a workspace digit · Ctrl+Shift+B to type a longer number"
    if (mode === "multi") return "Type a workspace number, then Enter"
    if (!active) return ""
    var row = (index >= 0 && index < displayModel.count) ? displayModel.get(index) : null
    if (!row || row.kind !== "window") return ""
    return "Ctrl+B · move this window to a workspace and follow it"
  }

  readonly property string headerText: {
    if (root.moveMode)
      return root.movePending ? ("Move to workspace " + root.movePending + "…")
                              : "Move to workspace…"
    if (root.filterText) return root.filterText
    if (root.activeGroup) {
      var group = root.groupFor(root.activeGroup)
      return (group ? group.label : "Jump To") + "…"
    }
    return "Jump To…"
  }

  // -------------------------------------------------------------------- UI

  PanelWindow {
    id: panel
    visible: root.opened && root.loaded
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "omarchy-jump-to"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    // The card opens centered. The first keystroke or drill-down freezes the
    // top line where it sits, so the card grows and shrinks downward instead
    // of re-centering on every resize and jumping around under the cursor.
    property int cardTop: -1
    readonly property int centeredTop: Math.max(Style.gapsOut, Math.round((height - root.cardHeight) / 2))
    readonly property int effectiveCardTop: cardTop >= 0 ? cardTop : centeredTop
    function freezeCardTop() { if (visible && cardTop < 0) cardTop = effectiveCardTop }
    onVisibleChanged: {
      cardTop = -1
      if (visible) { root.disarmPointer(); Qt.callLater(function () { keyCatcher.forceActiveFocus() }) }
    }

    Rectangle {
      anchors.fill: parent
      color: root.scrim
    }

    MouseArea {
      anchors.fill: parent
      onClicked: root.close()
    }

    BorderSurface {
      id: card
      width: root.cardWidth
      height: Math.min(root.cardHeight, panel.height - Style.gapsOut - panel.effectiveCardTop)
      radius: root.cornerRadius
      anchors.horizontalCenter: parent.horizontalCenter
      y: panel.effectiveCardTop
      color: root.background
      borderSpec: root.borderSpec
      padding: root.contentMargin

      MouseArea { anchors.fill: parent; onClicked: {} }

      Item {
        id: keyCatcher
        anchors.fill: parent
        focus: true

        Keys.priority: Keys.BeforeItem
        Keys.onPressed: function (event) {
          if (root.moveMode) {
            var digit = event.text.length === 1 && event.text >= "0" && event.text <= "9"
            // The hint offers Ctrl+Shift+B as the way out of one-digit mode, so
            // it has to be reachable from inside it.
            if (event.key === Qt.Key_B && (event.modifiers & Qt.ControlModifier)) {
              root.moveMode = (event.modifiers & Qt.ShiftModifier) ? "multi" : "single"
              event.accepted = true
              return
            }
            if (event.key === Qt.Key_Escape) root.cancelMove()
            else if (root.moveMode === "single") {
              if (digit) { root.movePending = event.text; root.commitMove() }
              // Anything that is not a workspace digit means you did not want
              // the move after all; drop out rather than swallow the key
              // silently.
              else root.cancelMove()
            } else if (digit) root.movePending += event.text
            else if (event.key === Qt.Key_Backspace) root.movePending = root.movePending.slice(0, -1)
            else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) root.commitMove()
            event.accepted = true
            return
          }

          if (event.key === Qt.Key_B && (event.modifiers & Qt.ControlModifier)) {
            root.beginMove((event.modifiers & Qt.ShiftModifier) ? "multi" : "single")
            event.accepted = true
          } else if (event.key === Qt.Key_Escape) {
            if (root.filterText) root.setFilter("")
            else root.close()
            event.accepted = true
          } else if (Util.editsFilter(event, root.filterText)) {
            panel.freezeCardTop()
            root.setFilter(Util.editedFilter(event, root.filterText))
            event.accepted = true
          } else if ((event.key === Qt.Key_Backspace || event.key === Qt.Key_Left) && !root.filterText) {
            panel.freezeCardTop()
            root.goBack()
            event.accepted = true
          } else if (event.key === Qt.Key_Up) {
            root.select(-1)
            event.accepted = true
          } else if (event.key === Qt.Key_Down) {
            root.select(1)
            event.accepted = true
          } else if (event.key === Qt.Key_PageUp) {
            root.select(-root.maxVisibleRows)
            event.accepted = true
          } else if (event.key === Qt.Key_PageDown) {
            root.select(root.maxVisibleRows)
            event.accepted = true
          } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Right) {
            panel.freezeCardTop()
            root.activateIndex(root.selectedIndex)
            event.accepted = true
          } else if (event.text && event.text.length === 1 && event.text.charCodeAt(0) >= 32
                     && event.text.charCodeAt(0) !== 127
                     && (event.modifiers === Qt.NoModifier || event.modifiers === Qt.ShiftModifier)) {
            panel.freezeCardTop()
            root.setFilter(root.filterText + event.text)
            event.accepted = true
          }
        }
      }

      Column {
        anchors.fill: parent
        anchors.topMargin: card.contentTopInset
        anchors.rightMargin: card.contentRightInset
        anchors.bottomMargin: card.contentBottomInset
        anchors.leftMargin: card.contentLeftInset
        spacing: root.contentSpacing

        Item {
          width: parent.width
          height: root.headerHeight

          Text {
            textFormat: Text.PlainText
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: root.headerText
            color: root.foreground
            opacity: (root.filterText || root.moveMode) ? 1 : 0.58
            font.family: root.fontFamily
            font.pixelSize: Style.font.heading
            elide: Text.ElideRight
          }
        }

        Item {
          width: parent.width
          height: root.visibleRowsHeight

          Text {
            textFormat: Text.PlainText
            anchors.left: parent.left
            anchors.leftMargin: root.rowReservedBorderLeft + Style.space(18)
            anchors.top: parent.top
            anchors.topMargin: Style.space(14)
            visible: displayModel.count === 0
            text: root.filterText ? "No window matches" : "No open windows"
            color: root.foreground
            opacity: 0.52
            font.family: root.fontFamily
            font.pixelSize: Style.font.heading
          }

          ListView {
            id: resultList
            anchors.fill: parent
            model: displayModel
            clip: true
            spacing: root.rowSpacing
            boundsBehavior: Flickable.StopAtBounds

            delegate: BorderSurface {
              id: row
              required property int index
              required property string kind
              required property string label
              required property string detail
              required property string appIcon
              required property string address
              required property bool chevron

              readonly property bool hasCursor: root.cursorActive && row.index === root.selectedIndex

              width: ListView.view.width
              height: root.rowHeight
              radius: root.cornerRadius
              color: row.hasCursor ? root.selectedBackground : "transparent"
              borderSpec: row.hasCursor ? root.selectedBorderSpec : Border.none()

              Image {
                id: appIconImage
                width: Style.font.iconLarge
                height: Style.font.iconLarge
                fillMode: Image.PreserveAspectFit
                // Decode at physical pixels: a logical-size decode leaves PNG
                // icons upscaled and blurry on HiDPI displays.
                sourceSize.width: width * Screen.devicePixelRatio
                sourceSize.height: height * Screen.devicePixelRatio
                source: root.appLibrary ? root.appLibrary.iconSource(row.appIcon) : ""
                asynchronous: true
                anchors.left: parent.left
                anchors.leftMargin: root.rowReservedBorderLeft + Style.space(8)
                  + (Style.space(36) - width) / 2
                y: contentColumn.y + labelText.y + (labelText.height - height) / 2
              }

              Column {
                id: contentColumn
                anchors.left: parent.left
                anchors.leftMargin: root.rowReservedBorderLeft + Style.space(8) + Style.space(36) + Style.space(6)
                anchors.right: trail.left
                anchors.rightMargin: Style.space(6)
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(3)

                Text {
                  id: labelText
                  textFormat: Text.PlainText
                  width: parent.width
                  text: row.label
                  color: row.hasCursor ? root.selectedText : root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.heading
                  font.weight: Font.Medium
                  elide: Text.ElideRight
                }

                Text {
                  textFormat: Text.PlainText
                  width: parent.width
                  text: row.detail
                  visible: row.detail.length > 0
                  color: root.foreground
                  opacity: 0.52
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  elide: Text.ElideRight
                }
              }

              Text {
                id: trail
                textFormat: Text.PlainText
                width: Style.space(14)
                anchors.right: parent.right
                anchors.rightMargin: root.rowReservedBorderRight + Style.space(8)
                text: row.chevron ? "›" : ""
                color: row.hasCursor ? root.selectedText : root.foreground
                opacity: row.chevron ? 0.36 : 0
                font.family: root.fontFamily
                font.pixelSize: Style.font.heading
                horizontalAlignment: Text.AlignHCenter
                y: contentColumn.y + labelText.y + (labelText.height - height) / 2
              }

              MouseArea {
                id: mouseArea
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onEntered: root.selectFromPointer(row.index, row, { x: mouseArea.mouseX, y: mouseArea.mouseY })
                onPositionChanged: function (mouse) { root.selectFromPointer(row.index, row, mouse) }
                onClicked: {
                  panel.freezeCardTop()
                  root.cursorActive = true
                  root.selectedIndex = row.index
                  root.activateIndex(row.index)
                }
              }
            }
          }
        }

        Text {
          textFormat: Text.PlainText
          width: parent.width
          height: root.hintHeight
          text: root.hintText
          color: root.foreground
          opacity: root.moveMode ? 0.7 : 0.4
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          verticalAlignment: Text.AlignVCenter
          elide: Text.ElideRight
        }
      }
    }
  }
}
