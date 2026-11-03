import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// The Firetower in Omarchy's bar (Omarchy 4, whose bar is a Quickshell shell
// rather than Waybar): binoculars, and a panel with the board's summary.
//
// It reads `firetower bar --format json`, the same summary the other bars
// print, as data. Two triggers, one read: `firetower watch --json` is the feed
// the board reads, so a fire shows the moment its check says so; but no word
// is worked out from the clock (a report that didn't come), and nothing
// arrives on the feed for that, so a slow timer re-reads too. The feed is
// restarted if it ever exits.
//
// Hidden with no lookouts, the bar's white when all is clear, a count when
// something needs a look, yellow on smoke, red on fire.
//
// Click opens the panel: the summary, every lookout that isn't clear (worst
// first), sources out of contact, and a row that opens the board. A lookout's
// row opens the board too; smoke or fire on this machine's own lookouts can be
// marked seen from the panel (a source's lookouts are seen on the board,
// which routes them to their machine). Right click opens the board directly.
//
// Colors come from the bar: fire is its alert color (the
// theme's red), smoke the theme's yellow. A theme can set its own in a
// firetower.toml beside its colors.toml:
//
//   fire = "#fd6883"
//   smoke = "#f9cc6c"
//   no_word = "#a79c9d"
Panel {
  id: root
  moduleName: "firetower"
  ipcTarget: "firetower"

  readonly property string home: Quickshell.env("HOME")
  readonly property string firetower: home + "/.local/bin/firetower"
  readonly property string themeDir: home + "/.local/state/omarchy/current/theme"
  readonly property string openBoardScript: Qt.resolvedUrl("open-board.sh").toString().replace(/^file:\/\//, "")

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // The theme's palette, then the theme's own firetower.toml over it.
  property var palette: ({})
  property var overrides: ({})
  readonly property color fireColor: overrides.fire || (bar ? bar.urgent : Color.urgent)
  readonly property color smokeColor: overrides.smoke || palette.yellow || "#e0b040"
  readonly property color noWordColor: overrides.no_word || foreground

  property string worst: "none"
  property int count: 0
  property int attention: 0
  property string tooltip: "Firetower"
  property var trouble: []      // lookouts that aren't clear, worst first
  property var lostSources: []  // sources out of contact

  // Keyboard cursor: 0 is the board row, 1..N the lookouts.
  property int cursor: 0
  property bool cursorActive: false

  // Out of contact (a source unreachable) lights the bar like smoke rather
  // than turning it red: nothing is known to be burning.
  readonly property bool fire: worst === "red"
  readonly property bool smoke: worst === "yellow"
  readonly property bool needsLook: attention > 0

  visible: count > 0 || opened
  implicitWidth: visible ? button.implicitWidth : 0
  implicitHeight: visible ? button.implicitHeight : 0

  readonly property var words: ({ red: "fire", yellow: "smoke", stale: "no word", lost: "out of contact", waiting: "waiting", green: "clear", done: "stood down" })
  readonly property var rank: ({ red: 0, yellow: 1, stale: 2, lost: 3, waiting: 4 })

  function word(state) { return root.words[state] || String(state) }

  function colorFor(state) {
    if (state === "red") return root.fireColor
    if (state === "yellow") return root.smokeColor
    if (state === "stale" || state === "lost") return root.noWordColor
    return root.foreground
  }

  function headline() {
    if (root.attention > 0)
      return root.attention + " need" + (root.attention === 1 ? "s" : "") + " a look"
    return "All clear"
  }

  // `name = "#rrggbb"` lines, as Omarchy's colors.toml has them.
  function colorsIn(raw) {
    var out = {}
    var lines = String(raw || "").split("\n")
    for (var i = 0; i < lines.length; i++) {
      var m = lines[i].match(/^\s*([A-Za-z0-9_-]+)\s*=\s*["']?(#[0-9A-Fa-f]{6})/)
      if (m) out[m[1]] = m[2]
    }
    return out
  }

  function refresh() {
    if (!summary.running) summary.running = true
  }

  function openBoard() {
    Quickshell.execDetached(["sh", root.openBoardScript, root.firetower])
    root.close()
  }

  function see(o) {
    Quickshell.execDetached([root.firetower, "seen", String(o.id)])
    settle.restart()
  }

  function update(raw) {
    var data
    try { data = JSON.parse(raw) } catch (e) { return }
    root.worst = String(data.worst || "none")
    root.count = Number(data.count || 0)
    root.attention = Number(data.attention || 0)

    var list = []
    var districts = data.districts || []
    for (var d = 0; d < districts.length; d++) {
      var towers = districts[d].towers || []
      for (var t = 0; t < towers.length; t++) {
        var lookouts = towers[t].lookouts || []
        for (var l = 0; l < lookouts.length; l++) {
          var state = String(lookouts[l].state || "")
          if (state !== "green" && state !== "done") list.push(lookouts[l])
        }
      }
    }
    list.sort(function(a, b) {
      var ra = root.rank[a.state] !== undefined ? root.rank[a.state] : 9
      var rb = root.rank[b.state] !== undefined ? root.rank[b.state] : 9
      return ra !== rb ? ra - rb : String(a.id).localeCompare(String(b.id))
    })
    root.trouble = list
    if (root.cursor > list.length) root.cursor = list.length

    var lost = []
    var sources = data.sources || []
    for (var s = 0; s < sources.length; s++)
      if (sources[s].contact !== "ok") lost.push(String(sources[s].name))
    root.lostSources = lost

    var lines = []
    for (var i = 0; i < list.length; i++)
      lines.push(list[i].id + ": " + word(list[i].state) + (list[i].message ? " -- " + list[i].message : ""))
    root.tooltip = ["Firetower: " + headline().toLowerCase()].concat(lines).join("\n")
  }

  function activateCursor() {
    root.openBoard()
  }

  function moveCursor(dy) {
    root.cursor = Math.max(0, Math.min(root.trouble.length, root.cursor + dy))
    var item = root.cursor === 0 ? boardRow : (lookoutColumn.children[root.cursor - 1] || null)
    if (!item) return
    Qt.callLater(function() {
      var margin = Style.space(6)
      var top = item.mapToItem(panelFlick.contentItem, 0, 0).y
      var bottom = top + item.height
      var maxY = Math.max(0, panelFlick.contentHeight - panelFlick.height)
      if (top < panelFlick.contentY + margin) panelFlick.contentY = Math.max(0, top - margin)
      else if (bottom > panelFlick.contentY + panelFlick.height - margin)
        panelFlick.contentY = Math.min(maxY, bottom + margin - panelFlick.height)
    })
  }

  onOpenedChanged: if (opened) {
    cursorActive = false
    cursor = 0
    panelFlick.contentY = 0
    refresh()
  }

  FileView {
    path: root.themeDir + "/colors.toml"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.palette = root.colorsIn(text())
  }

  FileView {
    path: root.themeDir + "/firetower.toml"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.overrides = root.colorsIn(text())
    onLoadFailed: root.overrides = ({})
  }

  Process {
    id: summary
    command: [root.firetower, "bar", "--format", "json"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.update(text)
    }
  }

  // The feed: any line means something changed, so re-read the summary.
  Process {
    id: feed
    command: [root.firetower, "watch", "--json"]
    running: true
    stdout: SplitParser {
      onRead: function(line) { root.refresh() }
    }
    onExited: function(exitCode) { restartFeed.start() }
  }

  Timer {
    id: restartFeed
    interval: 30000
    onTriggered: feed.running = true
  }

  Timer {
    interval: 30000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  // A seen lands on the feed too; this is for when the feed is down.
  Timer {
    id: settle
    interval: 1500
    onTriggered: root.refresh()
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar

    // nf-md-binoculars, the glyph the SwiftBar plugin uses.
    text: "󰂥" + (root.needsLook ? " " + root.attention : "")
    active: root.fire || root.smoke
    activeColor: root.fire ? root.fireColor : root.smokeColor

    tooltipText: root.opened ? "" : root.tooltip

    onPressed: function(b) {
      if (b === Qt.RightButton) root.openBoard()
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
    contentWidth: panel.fittedContentWidth(Style.space(400))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(620))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive) { root.cursorActive = true; return }
        root.moveCursor(dy)
      }
      onActivateRequested: if (root.cursorActive) root.activateCursor()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "r" || t === "R") root.refresh()
        else if (t === "b" || t === "B") root.openBoard()
        else if ((t === "s" || t === "S") && root.cursorActive && root.cursor > 0) {
          var o = root.trouble[root.cursor - 1]
          if (o && !o.origin && !o.seen && (o.state === "red" || o.state === "yellow")) root.see(o)
        }
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

          PanelHero {
            width: parent.width
            title: "Firetower"
            meta: root.headline() + " · " + root.count + " lookout" + (root.count === 1 ? "" : "s")
            foreground: root.foreground
            fontFamily: root.fontFamily
            iconComponent: Component {
              Text {
                text: "󰂥"
                color: root.fire ? root.fireColor : (root.smoke ? root.smokeColor : root.foreground)
                font.family: root.fontFamily
                font.pixelSize: Style.font.display
              }
            }
          }

          LinkRow {
            id: boardRow
            width: parent.width
            hasCursor: root.cursorActive && root.cursor === 0
            onHoveredRow: { root.cursorActive = true; root.cursor = 0 }
            onActivated: root.openBoard()
          }

          PanelSeparator {
            visible: root.trouble.length > 0 || root.lostSources.length > 0
            foreground: root.foreground
          }

          Column {
            id: lookoutColumn
            visible: root.trouble.length > 0
            width: parent.width
            spacing: Style.space(4)

            Repeater {
              model: root.trouble
              LookoutRow {
                required property var modelData
                required property int index
                width: lookoutColumn.width
                lookout: modelData
                rowIndex: index + 1
              }
            }
          }

          Column {
            visible: root.lostSources.length > 0
            width: parent.width
            spacing: Style.space(4)

            Repeater {
              model: root.lostSources
              Text {
                required property string modelData
                textFormat: Text.PlainText
                width: parent.width
                leftPadding: Style.space(10)
                text: modelData + ": out of contact"
                color: root.noWordColor
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                elide: Text.ElideRight
              }
            }
          }
        }
      }
    }
  }

  component LinkRow: CursorSurface {
    id: link
    signal hoveredRow()
    signal activated()

    foreground: root.foreground
    implicitHeight: linkRow.implicitHeight + Style.spacing.rowPaddingX

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onEntered: link.hoveredRow()
      onClicked: link.activated()
    }

    RowLayout {
      id: linkRow
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(10)
      spacing: Style.space(8)

      Text {
        text: "󰖟"
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.icon
      }

      Text {
        Layout.fillWidth: true
        textFormat: Text.PlainText
        text: "Open the board"
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        elide: Text.ElideRight
      }
    }
  }

  component LookoutRow: CursorSurface {
    id: row
    property var lookout: ({})
    property int rowIndex: 0
    // Seen acknowledges smoke or fire; a source's lookouts are seen on the board.
    readonly property bool canSee: !lookout.origin && !lookout.seen
      && (lookout.state === "red" || lookout.state === "yellow")

    hasCursor: root.cursorActive && root.cursor === rowIndex
    foreground: root.foreground
    implicitHeight: content.implicitHeight + Style.spacing.rowPaddingX

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onEntered: { root.cursorActive = true; root.cursor = row.rowIndex }
      onClicked: root.openBoard()
    }

    RowLayout {
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(6)
      spacing: Style.space(8)

      Rectangle {
        Layout.alignment: Qt.AlignTop
        Layout.topMargin: Style.space(6)
        implicitWidth: Style.space(8)
        implicitHeight: Style.space(8)
        radius: width / 2
        color: root.colorFor(row.lookout.state)
        opacity: row.lookout.seen ? 0.35 : 1
      }

      ColumnLayout {
        id: content
        Layout.fillWidth: true
        spacing: Style.space(1)

        Text {
          Layout.fillWidth: true
          textFormat: Text.PlainText
          text: (row.lookout.label || row.lookout.id) + " · " + root.word(row.lookout.state) + (row.lookout.seen ? ", seen" : "")
          color: root.colorFor(row.lookout.state)
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          font.bold: row.lookout.state === "red"
          elide: Text.ElideRight
        }

        Text {
          Layout.fillWidth: true
          visible: text !== ""
          textFormat: Text.PlainText
          text: String(row.lookout.message || "")
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
          maximumLineCount: 3
          elide: Text.ElideRight
        }
      }

      PanelActionButton {
        visible: row.canSee
        Layout.alignment: Qt.AlignVCenter
        iconText: "󰈈"
        tooltipText: "Seen"
        foreground: root.foreground
        fontFamily: root.fontFamily
        onClicked: root.see(row.lookout)
      }
    }
  }
}
