import QtQuick
import QtQuick.Effects
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui

Panel {
  id: root
  moduleName: "io.github.0gulcandogann.asus-rog-monitor"
  ipcTarget: "io.github.0gulcandogann.asus-rog-monitor"

  readonly property var prefs: stats.prefs || ({})
  // ASUS hardware only for now. Elsewhere the panel is blurred behind a notice.
  // It stays blocked unless both this file and stats.py confirm ASUS hardware,
  // so a failed stats script or an unreadable vendor file never unlocks it.
  property string sysVendor: ""
  property string boardVendor: ""
  readonly property bool supported: stats.supported === true && (isAsusVendor(sysVendor) || isAsusVendor(boardVendor))
  // The one system colour: the panel, the bar and the logo all follow it.
  readonly property color rogRed: "#" + (prefs.systemColor || "ff0033")
  readonly property color rogRedDim: Qt.darker(rogRed, 2.1)
  // Readable text on top of the accent colour, which the user can make very light.
  readonly property color onAccent: 0.299 * rogRed.r + 0.587 * rogRed.g + 0.114 * rogRed.b > 0.62 ? "#0b0b0f" : textColor
  readonly property color textColor: "#f4f4f6"
  readonly property color mutedColor: "#8d8d97"
  readonly property color trackColor: "#1e1e25"
  readonly property string fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
  readonly property string statsScript: localPath("stats.py")
  readonly property string actionsScript: localPath("actions.py")
  // Optional shell.json widget settings: logo (image path), title (header text).
  readonly property string logoSource: {
    var path = String(setting("logo", ""))
    return path !== "" ? "file://" + path : "mark.png"
  }
  readonly property string headerTitle: String(setting("title", "SYSTEM MONITOR"))
  readonly property bool logoTint: setting("logoTint", true) === true
  readonly property var profiles: ["Quiet", "Balanced", "Performance"]
  readonly property var swatches: ["ff0033", "fe8722", "ffc400", "00e676", "00e5ff", "2b6cff", "b000ff", "ffffff"]
  readonly property var keyboardModes: ["static", "breathe", "rainbow"]
  readonly property var keyboardLevels: ["off", "low", "med", "high"]
  readonly property var fanPresets: ["AUTO", "COOL", "MAX"]
  readonly property var batteryLimits: [60, 80, 100]
  readonly property var topModes: ["cpu", "ram", "gpu"]
  readonly property int historySeconds: 60
  readonly property var barItemChoices: [
    { id: "logo", label: "LOGO" }, { id: "cpu", label: "CPU" }, { id: "cpuTemp", label: "CPU °C" },
    { id: "cores", label: "CORES" }, { id: "ram", label: "RAM" }, { id: "gpu", label: "GPU W" },
    { id: "gpuTemp", label: "GPU °C" }
  ]
  readonly property var barItems: !supported ? ["logo"] : (prefs.barItems || ["logo", "cpu", "gpu"])
  readonly property bool barCpuGroup: barHas("cpu") || barHas("cpuTemp") || barHas("cores")
  readonly property bool barGpuGroup: !!gpu && (barHas("gpu") || barHas("gpuTemp"))
  readonly property string statsMode: opened ? "1 detail" : (barHas("cores") ? "2" : "4")
  property string rightView: "controls"
  property bool hexFieldFocused: false

  property string topMode: "cpu"
  property string confirmKillName: ""
  // PIDs shown at the first click; only these may be signalled on confirm.
  property var confirmKillPids: []
  property var history: []
  property int historyRevision: 0

  property var stats: ({})
  readonly property var ram: stats.ram || ({})
  readonly property var gpu: stats.gpu || null
  readonly property var cores: stats.cores || []
  readonly property int coreCount: cores.length
  readonly property var topRows: stats.top ? (stats.top[topMode] || []) : []
  readonly property var keyboardState: stats.keyboard || ({})
  readonly property var driver: stats.driver || null
  readonly property string driverState: driver ? driver.state : ""
  readonly property string driverIcon: driverState === "update" ? "\u{F01DA}" : (driverState === "restart" ? "\u{F0709}" : (driverState === "current" ? "\u{F012C}" : ""))
  readonly property var updateCommand: ["omarchy-launch-floating-terminal-with-presentation", "omarchy-update"]
  readonly property bool hasAsus: stats.hasAsus === true
  readonly property bool hasChargeLimit: hasAsus && stats.batteryLimit !== undefined && stats.batteryLimit !== null
  readonly property bool boostOn: !!gpu && gpu.limit > gpu.defaultLimit + 1
  // Optional shell.json widget setting `"barStyle": "plain"`: one quiet line of
  // temperatures in the bar's own color (no logo, labels or accent), e.g. for
  // bars with a monochrome look. Values over their alarm limit use bar.urgent.
  readonly property bool plainBar: String(setting("barStyle", "")) === "plain"
  // The bar shows the CPU temperature averaged over the last 5 s (stats.py
  // cpuTempAvg); Tctl swings tens of degrees within seconds. The panel keeps
  // the instant reading.
  readonly property var barCpuTemp: stats.cpuTempAvg !== undefined && stats.cpuTempAvg !== null ? stats.cpuTempAvg : stats.cpuTemp
  readonly property bool cpuHot: (barCpuTemp || 0) >= 90
  readonly property bool gpuHot: !!gpu && (gpu.temp || 0) >= 87
  readonly property color plainColor: root.bar && root.bar.barForeground ? root.bar.barForeground : textColor
  readonly property color plainAlert: root.bar && root.bar.urgent ? root.bar.urgent : rogRed
  readonly property real barContentWidth: plainBar ? plainBarRow.implicitWidth : barContentRow.implicitWidth

  // Show a choice straight away; the next stats sample then confirms the saved value.
  function setPreference(key, value, argument) {
    var nextPrefs = Object.assign({}, prefs)
    nextPrefs[key] = value
    stats = Object.assign({}, stats, { prefs: nextPrefs })
    act(key === "systemColor" ? "system-color" : "bar-items", argument)
  }
  function isAsusVendor(vendor) {
    return String(vendor).trim().toUpperCase().indexOf("ASUS") === 0
  }
  function barHas(item) {
    return barItems.indexOf(item) !== -1
  }
  function toggleBarItem(item) {
    var next = barHas(item) ? barItems.filter(function(id) { return id !== item }) : barItems.concat([item])
    if (next.length > 0) setPreference("barItems", next, next.join(","))
  }
  function localPath(name) {
    return decodeURIComponent(String(Qt.resolvedUrl(name)).replace("file://", ""))
  }
  function fixed(value, digits, suffix) {
    return value === undefined || value === null ? "—" : Number(value).toFixed(digits) + suffix
  }
  function ratio(value, total) {
    return total > 0 && value !== undefined && value !== null ? Math.max(0, Math.min(1, value / total)) : 0
  }
  function act() {
    actionProc.exec(["python3", "-I", root.actionsScript].concat(Array.prototype.slice.call(arguments)))
  }
  function record(sample) {
    var now = Date.now() / 1000
    var kept = history.filter(function(point) { return now - point.t <= root.historySeconds })
    kept.push({
      t: now,
      cpu: sample.cpu || 0,
      gpu: sample.gpu ? ratio(sample.gpu.power, sample.gpu.limit) * 100 : 0,
      temp: sample.cpuTemp || 0
    })
    history = kept
    historyRevision++
  }
  function requestKill(row) {
    if (confirmKillName !== row.name) {
      confirmKillName = row.name
      confirmKillPids = row.pids.slice()
      killConfirmTimer.restart()
      return
    }
    // Only PIDs present at the first click AND still in this group now, so a
    // process that joined the group (or reused a PID) in between is never hit.
    var current = row.pids
    var targets = confirmKillPids.filter(function (pid) { return current.indexOf(pid) >= 0 })
    confirmKillName = ""
    confirmKillPids = []
    if (targets.length > 0)
      killProc.exec(["python3", "-I", root.actionsScript, "close"].concat(targets))
  }
  function coreColor(load) {
    return Qt.tint(root.rogRedDim, Qt.rgba(root.rogRed.r, root.rogRed.g, root.rogRed.b, ratio(load, 100)))
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  FileView {
    path: "/sys/class/dmi/id/sys_vendor"
    printErrors: false
    onLoaded: root.sysVendor = text()
  }
  FileView {
    path: "/sys/class/dmi/id/board_vendor"
    printErrors: false
    onLoaded: root.boardVendor = text()
  }

  Process {
    id: statsProc
    command: ["python3", "-I", root.statsScript].concat(root.statsMode.split(" "))
    running: true
    stdout: SplitParser {
      onRead: function(line) {
        try {
          var sample = JSON.parse(line)
          root.stats = sample
          root.record(sample)
        } catch (error) {
          console.warn("asus-rog-monitor: bad stats line", error)
        }
      }
    }
  }

  // The interval is part of the command, so restart when it changes.
  onStatsModeChanged: {
    statsProc.running = false
    restartTimer.restart()
  }
  Timer { id: restartTimer; interval: 50; onTriggered: statsProc.running = true }
  Timer { id: killConfirmTimer; interval: 3000; onTriggered: { root.confirmKillName = ""; root.confirmKillPids = [] } }
  Process { id: profileProc }
  Process { id: actionProc }
  Process { id: killProc }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: " "
    slotSize: vertical ? Style.bar.iconSlot : root.barContentWidth + Style.space(14)
    tooltipText: ""
    onPressed: root.toggle()

    // Drawn as a direct child: BarIconButton scales iconComponent content down
    // until its longest side fits one icon, which shrinks a row of stats to specks.
    Row {
      id: plainBarRow
      visible: !button.vertical && root.plainBar
      scale: button.pressScale
      anchors.centerIn: parent
      spacing: 0

      Text {
        textFormat: Text.PlainText
        text: root.fixed(root.barCpuTemp, 0, "°")
        color: root.cpuHot ? root.plainAlert : root.plainColor
        font.family: root.fontFamily
        font.pixelSize: Math.round(Style.bar.iconFont * 0.8)
      }
      Text {
        visible: !!root.gpu
        textFormat: Text.PlainText
        text: " / " + (root.gpu ? root.fixed(root.gpu.temp, 0, "°") : "")
        color: root.gpuHot ? root.plainAlert : root.plainColor
        opacity: root.gpuHot ? 1 : 0.55
        font.family: root.fontFamily
        font.pixelSize: Math.round(Style.bar.iconFont * 0.8)
      }
    }

    Row {
      id: barContentRow
      visible: !button.vertical && !root.plainBar
      scale: button.pressScale
      anchors.centerIn: parent
      spacing: Style.space(6)

      BarStat { visible: !root.supported; label: ""; value: "ASUS ONLY" }
      LogoMark {
        visible: root.barHas("logo")
        anchors.verticalCenter: parent.verticalCenter
        height: Style.bar.iconCanvas * 0.92
        width: height * 2
      }
      BarStat { visible: root.barHas("cpu"); label: "CPU"; value: Math.round(root.stats.cpu || 0) + "%"; alert: (root.stats.cpu || 0) >= 90 }
      BarStat { visible: root.barHas("cpuTemp"); label: root.barHas("cpu") ? "" : "CPU"; value: root.fixed(root.barCpuTemp, 0, "°"); alert: root.cpuHot }
      Row {
        visible: root.barHas("cores")
        anchors.verticalCenter: parent.verticalCenter
        spacing: 1
        Repeater {
          model: root.coreCount
          delegate: Item {
            required property int index
            width: Math.max(2, Style.space(3))
            height: Style.bar.iconCanvas * 0.9
            Rectangle { anchors.fill: parent; color: root.rogRed; opacity: 0.18 }
            Rectangle {
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.bottom: parent.bottom
              height: Math.max(1, parent.height * root.ratio(root.cores[parent.index], 100))
              color: root.rogRed
            }
          }
        }
      }
      BarDivider { visible: root.barCpuGroup && (root.barHas("ram") || root.barGpuGroup) }
      BarStat { visible: root.barHas("ram"); label: "RAM"; value: root.fixed(root.ram.used, 1, "G"); alert: root.ratio(root.ram.used, root.ram.total) >= 0.9 }
      BarDivider { visible: root.barHas("ram") && root.barGpuGroup }
      BarStat { visible: !!root.gpu && root.barHas("gpu"); label: "GPU"; value: root.gpu ? Math.round(root.gpu.power || 0) + "W" : "—"; alert: !!root.gpu && (root.gpu.temp || 0) >= 87 }
      BarStat { visible: !!root.gpu && root.barHas("gpuTemp"); label: root.barHas("gpu") ? "" : "GPU"; value: root.gpu ? root.fixed(root.gpu.temp, 0, "°") : "—"; alert: !!root.gpu && (root.gpu.temp || 0) >= 87 }
    }
  }

  SlidePanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    borderSpec: Border.flat(root.rogRed, 1)
    contentWidth: panel.fittedContentWidth(Style.space(960))
    contentHeight: panel.fittedContentHeight(dashboard.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: root.hexFieldFocused
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Item {
        anchors.fill: dashboard
        z: 10
        visible: !root.supported

        // Swallows pointer input so the blurred controls cannot be used.
        MouseArea {
          anchors.fill: parent
          acceptedButtons: Qt.AllButtons
          hoverEnabled: true
          preventStealing: true
          onWheel: function(wheel) { wheel.accepted = true }
        }
        Rectangle {
          anchors.fill: parent
          color: "#0b0b0f"
          opacity: 0.55
        }
        Column {
          anchors.centerIn: parent
          width: parent.width * 0.72
          spacing: Style.space(10)

          Text {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            text: "UNSUPPORTED SYSTEM"
            color: root.rogRed
            font.family: root.fontFamily
            font.pixelSize: Style.font.title
            font.bold: true
            font.letterSpacing: 2.4
          }
          Text {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
            text: "You are not using an ASUS ROG system. This plugin only works on ASUS and ROG devices."
            color: root.textColor
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
          }
          Text {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
            text: "Versions for other brands are planned."
            color: root.mutedColor
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }
        }
      }

      Row {
        id: dashboard
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(22)
        enabled: root.supported
        layer.enabled: !root.supported
        layer.effect: MultiEffect {
          blurEnabled: true
          blur: 1.0
          blurMax: 48
        }
        readonly property real columnWidth: (width - spacing) / 2

      Column {
        id: column
        width: dashboard.columnWidth
        spacing: Style.space(14)

        // ---------- Header: logo, name, slanted stripes ----------
        Item {
          width: parent.width
          height: Style.space(50)

          LogoMark {
            id: rogLogo
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            height: parent.height * 0.82
            width: height * 1.7
          }
          Column {
            anchors.left: rogLogo.right
            anchors.leftMargin: Style.space(12)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)

            Text {
              text: root.headerTitle
              color: root.rogRed
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              font.letterSpacing: 2.4
            }
            Text {
              text: root.stats.model || ""
              color: root.textColor
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
              font.letterSpacing: 1.2
            }
          }
          Chip {
            id: boostChip
            visible: !!root.gpu
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            title: root.boostOn ? "BOOST ON" : "BOOST OFF"
            lit: root.boostOn
          }
          Canvas {
            readonly property color paintAccent: root.rogRed
            onPaintAccentChanged: requestPaint()
            anchors.right: boostChip.left
            anchors.rightMargin: Style.space(8)
            anchors.verticalCenter: parent.verticalCenter
            width: Style.space(70)
            height: Style.space(24)
            onPaint: {
              var ctx = getContext("2d")
              ctx.reset()
              ctx.fillStyle = root.rogRed
              var step = width / 7
              for (var i = 0; i < 7; i++) {
                ctx.globalAlpha = 0.14 + i * 0.14
                var x = i * step
                ctx.beginPath()
                ctx.moveTo(x + height * 0.5, 0)
                ctx.lineTo(x + height * 0.5 + step * 0.45, 0)
                ctx.lineTo(x + step * 0.45, height)
                ctx.lineTo(x, height)
                ctx.closePath()
                ctx.fill()
              }
            }
          }
        }

        Rule {}

        // ---------- Gauges ----------
        Row {
          id: gaugeRow
          width: parent.width
          spacing: Style.space(10)
          readonly property real cell: (width - spacing * 2) / 3

          Gauge {
            width: gaugeRow.cell
            value: root.ratio(root.stats.cpu, 100)
            big: Math.round(root.stats.cpu || 0) + "%"
            label: "CPU"
            sub: root.fixed(root.stats.cpuTemp, 0, "°C")
          }
          Gauge {
            width: gaugeRow.cell
            value: root.gpu ? root.ratio(root.gpu.power, root.gpu.limit) : 0
            big: root.gpu ? Math.round(root.gpu.power || 0) + "W" : "—"
            label: "GPU"
            sub: root.gpu ? root.fixed(root.gpu.temp, 0, "°C") + " · " + root.fixed(root.gpu.limit, 0, "W") : "N/A"
          }
          Gauge {
            width: gaugeRow.cell
            value: root.ratio(root.ram.used, root.ram.total)
            big: root.fixed(root.ram.used, 1, "")
            label: "RAM"
            sub: "/ " + root.fixed(root.ram.total, 1, " GB")
          }
        }

        // ---------- Last 60 seconds ----------
        Row {
          id: sparkRow
          width: parent.width
          spacing: Style.space(10)
          readonly property real cell: (width - spacing * 2) / 3

          Spark { width: sparkRow.cell; title: "CPU %"; series: "cpu"; low: 0; high: 100 }
          Spark { width: sparkRow.cell; title: "GPU W %"; series: "gpu"; low: 0; high: 100 }
          Spark { width: sparkRow.cell; title: "CPU °C"; series: "temp"; low: 30; high: 100 }
        }

        // ---------- Per-core load ----------
        SectionLabel { text: "CORE LOAD" }

        Row {
          id: coreRow
          width: parent.width
          spacing: Style.space(4)

          Repeater {
            model: root.coreCount
            delegate: Column {
              required property int index
              readonly property real load: root.cores[index] || 0
              width: (coreRow.width - coreRow.spacing * Math.max(0, root.coreCount - 1)) / Math.max(1, root.coreCount)
              spacing: Style.space(4)

              Item {
                width: parent.width
                height: Style.space(46)

                Rectangle { anchors.fill: parent; color: root.trackColor }
                Rectangle {
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.bottom: parent.bottom
                  height: Math.max(2, parent.height * root.ratio(parent.parent.load, 100))
                  color: root.coreColor(parent.parent.load)
                  Behavior on height { NumberAnimation { duration: 280; easing.type: Easing.OutCubic } }
                }
              }
              Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: Math.round(parent.load)
                color: root.mutedColor
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }
          }
        }

        Rule {}

        // ---------- Details ----------
        Row {
          id: detailRow
          width: parent.width
          spacing: Style.space(24)
          readonly property real cell: (width - spacing) / 2

          Column {
            width: detailRow.cell
            spacing: Style.space(6)
            Stat { label: "CPU GHz"; value: root.fixed(root.stats.cpuGhz, 2, "") + " / " + root.fixed(root.stats.cpuPeakGhz, 2, "") }
            Stat { label: "GPU MHz"; value: root.gpu ? root.fixed(root.gpu.clock, 0, "") : "—" }
            Stat { label: "VRAM"; value: root.gpu ? root.fixed(root.gpu.memUsed / 1024, 1, "") + " / " + root.fixed(root.gpu.memTotal / 1024, 1, " GB") : "—" }
          }
          Column {
            width: detailRow.cell
            spacing: Style.space(6)
            Stat { visible: root.hasAsus; label: "CPU FAN"; value: root.fixed(root.stats.cpuFan, 0, " rpm") }
            Stat { visible: root.hasAsus; label: "GPU FAN"; value: root.fixed(root.stats.gpuFan, 0, " rpm") }
            Stat { label: "SSD"; value: root.fixed(root.stats.nvmeTemp, 0, "°C") }
          }
        }


        // ---------- GPU driver ----------
        Rule { visible: !!root.driver }
        Item {
          visible: !!root.driver
          width: parent.width
          height: Style.space(30)

          Column {
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)
            SectionLabel { text: "GPU DRIVER" }
            Text {
              text: {
                if (!root.driver) return ""
                if (root.driverState === "update") return root.driver.version + " → " + root.driver.available
                if (root.driverState === "restart") return root.driver.version + "  ·  restart to finish"
                return root.driver.version
              }
              color: root.textColor
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              font.bold: true
            }
          }
          // One icon: a quiet tick normally, a lit download button when an update arrives.
          Text {
            id: driverIconText
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            visible: root.driverIcon !== ""
            text: root.driverIcon
            color: root.driverState === "current" ? root.mutedColor : root.rogRed
            font.family: root.fontFamily
            font.pixelSize: Style.font.title * 1.3

            MouseArea {
              anchors.fill: parent
              anchors.margins: -Style.space(6)
              enabled: root.driverState === "update"
              cursorShape: Qt.PointingHandCursor
              onClicked: Quickshell.execDetached(root.updateCommand)
            }
          }
        }
      }

      Column {
        id: controlsColumn
        width: dashboard.columnWidth
        spacing: Style.space(12)

        OptionRow {
          options: ["controls", "customize"]
          current: root.rightView
          onPicked: function(option) { root.rightView = option }
        }

        // ---------- Customize: colours and bar contents ----------
        Column {
          visible: root.rightView === "customize"
          width: parent.width
          spacing: Style.space(12)

          SectionLabel { text: "SYSTEM COLOR" }
          ColorPicker {
            current: root.prefs.systemColor || "ff0033"
            onPicked: function(hex) { root.setPreference("systemColor", hex, hex) }
          }

          Rule { visible: root.hasAsus }
          SectionLabel { visible: root.hasAsus; text: "KEYBOARD COLOR" }
          ColorPicker {
            visible: root.hasAsus
            current: root.keyboardState.colour || "ff0033"
            onPicked: function(hex) { root.act("keyboard", root.keyboardState.mode === "breathe" ? "breathe" : "static", hex) }
          }

          Rule {}
          SectionLabel { text: "SHOW IN BAR" }
          Grid {
            id: barItemGrid
            width: parent.width
            columns: 4
            columnSpacing: Style.space(2)
            rowSpacing: Style.space(4)
            Repeater {
              model: root.barItemChoices
              delegate: ProfileTab {
                required property var modelData
                width: (barItemGrid.width - barItemGrid.columnSpacing * 3) / 4
                height: Style.space(28)
                title: modelData.label
                active: root.barHas(modelData.id)
                onClicked: root.toggleBarItem(modelData.id)
              }
            }
          }
        }

        // ---------- Everyday controls ----------
        Column {
          visible: root.rightView === "controls"
          width: parent.width
          spacing: Style.space(12)

        // ---------- Heaviest applications ----------
        Item {
          width: parent.width
          height: topTabs.height

          SectionLabel { text: "TOP APPS"; anchors.verticalCenter: parent.verticalCenter }
          Row {
            id: topTabs
            anchors.right: parent.right
            spacing: Style.space(2)
            Repeater {
              model: root.topModes
              delegate: ProfileTab {
                required property var modelData
                width: Style.space(62)
                height: Style.space(26)
                title: String(modelData)
                active: root.topMode === modelData
                onClicked: root.topMode = modelData
              }
            }
          }
        }

        Column {
          width: parent.width
          spacing: Style.space(4)

          Repeater {
            model: 5
            delegate: Item {
              required property int index
              readonly property var row: index < root.topRows.length ? root.topRows[index] : null
              width: parent.width
              height: Style.space(25)

              Text {
                anchors.left: parent.left
                anchors.right: topValue.left
                anchors.rightMargin: Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                // Any process can choose its name, so never treat it as markup.
                textFormat: Text.PlainText
                text: parent.row ? parent.row.name : ""
                elide: Text.ElideRight
                color: root.textColor
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
              }
              Text {
                id: topValue
                anchors.right: killButton.left
                anchors.rightMargin: Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                text: parent.row ? parent.row.value : ""
                color: root.mutedColor
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
              }
              ProfileTab {
                id: killButton
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                readonly property bool armed: !!parent.row && root.confirmKillName === parent.row.name
                visible: !!parent.row && parent.row.pids.length > 0
                width: Style.space(72)
                height: Style.space(23)
                title: armed ? "SURE?" : "CLOSE"
                active: armed
                onClicked: root.requestKill(parent.row)
              }
            }
          }
        }

        Rule { visible: root.hasAsus }

        // ---------- ASUS keyboard lighting ----------
        SectionLabel { visible: root.hasAsus; text: "KEYBOARD" }

        Row {
          id: swatchRow
          visible: root.hasAsus
          width: parent.width
          spacing: Style.space(6)

          Repeater {
            model: root.swatches
            delegate: Rectangle {
              required property var modelData
              readonly property bool selected: root.keyboardState.colour === modelData && root.keyboardState.mode !== "rainbow"
              width: (swatchRow.width - swatchRow.spacing * 7) / 8
              height: Style.space(30)
              color: "#" + modelData
              border.width: selected ? 2 : 0
              border.color: root.textColor
              opacity: swatchMouse.containsMouse || selected ? 1 : 0.72

              MouseArea {
                id: swatchMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.act("keyboard", root.keyboardState.mode === "breathe" ? "breathe" : "static", parent.modelData)
              }
            }
          }
        }

        OptionRow {
          visible: root.hasAsus
          options: root.keyboardModes
          current: root.keyboardState.mode || "static"
          onPicked: function(option) { root.act("keyboard", option) }
        }
        OptionRow {
          visible: root.hasAsus
          options: root.keyboardLevels
          current: root.stats.keyboardLevel === undefined || root.stats.keyboardLevel === null ? "" : root.keyboardLevels[root.stats.keyboardLevel]
          onPicked: function(option) { actionProc.exec(["asusctl", "leds", "set", option]) }
        }

        Rule { visible: root.hasAsus }

        // ---------- ASUS fan, battery, performance ----------
        SectionLabel { visible: root.hasAsus; text: "FAN" }
        OptionRow {
          visible: root.hasAsus
          options: root.fanPresets
          current: root.stats.fanPreset || "AUTO"
          onPicked: function(option) { root.act("fan", option) }
        }

        Item {
          visible: root.hasChargeLimit
          width: parent.width
          height: batteryLabel.implicitHeight
          SectionLabel { id: batteryLabel; text: "CHARGE LIMIT" }
          Text {
            anchors.right: parent.right
            text: root.fixed(root.stats.batteryPercent, 0, "%") + (root.stats.onAc === true ? "  ·  AC" : (root.stats.onAc === false ? "  ·  BATTERY" : ""))
            color: root.mutedColor
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }
        OptionRow {
          visible: root.hasChargeLimit
          options: root.batteryLimits
          suffix: "%"
          current: root.stats.batteryLimit === undefined || root.stats.batteryLimit === null ? "" : Math.round(root.stats.batteryLimit)
          onPicked: function(option) { actionProc.exec(["asusctl", "battery", "limit", String(option)]) }
        }

        SectionLabel { visible: root.hasAsus; text: "PERFORMANCE" }
        OptionRow {
          visible: root.hasAsus
          options: root.profiles
          current: root.profiles.find(function(name) { return name.toLowerCase() === String(root.stats.profile || "").toLowerCase() }) || ""
          onPicked: function(option) { profileProc.exec(["asusctl", "profile", "set", String(option)]) }
        }
        }
      }
      }
    }
  }

  // Label and value share one font size and baseline so the bar reads as a single line.
  component BarStat: Row {
    property string label: ""
    property string value: ""
    property bool alert: false
    anchors.verticalCenter: parent ? parent.verticalCenter : undefined
    spacing: Style.space(4)

    Text {
      visible: parent.label !== ""
      anchors.baseline: barValue.baseline
      text: parent.label
      color: root.rogRed
      font.family: root.fontFamily
      font.pixelSize: Math.round(Style.bar.iconFont * 0.72)
      font.bold: true
    }
    Text {
      id: barValue
      anchors.verticalCenter: parent.verticalCenter
      text: parent.value
      color: parent.alert ? root.rogRed : root.textColor
      font.family: root.fontFamily
      font.pixelSize: Math.round(Style.bar.iconFont * 0.72)
      font.bold: true
    }
  }

  component BarDivider: Rectangle {
    anchors.verticalCenter: parent ? parent.verticalCenter : undefined
    width: 1
    height: Style.bar.iconCanvas * 0.8
    color: root.rogRed
    opacity: 0.55
  }

  // The logo image, flat-tinted with the accent colour unless logoTint is off.
  // The mask works at four times the item size so small logos keep their detail.
  component LogoMark: Item {
    property color tint: root.rogRed
    readonly property size maskSize: Qt.size(Math.ceil(width * 4), Math.ceil(height * 4))

    Image {
      id: logoImage
      anchors.fill: parent
      source: root.logoSource
      sourceSize: parent.maskSize
      fillMode: Image.PreserveAspectFit
      smooth: true
      visible: !root.logoTint
      layer.enabled: root.logoTint
      layer.smooth: true
      layer.textureSize: parent.maskSize
    }
    Rectangle {
      anchors.fill: parent
      visible: root.logoTint
      color: parent.tint
      layer.enabled: root.logoTint
      layer.smooth: true
      layer.textureSize: parent.maskSize
      layer.effect: MultiEffect {
        maskEnabled: true
        maskSource: logoImage
        maskThresholdMin: 0.35
        maskSpreadAtMin: 0.5
      }
    }
  }

  // Preset colours, a hue strip and a hex field. Emits a colour once the user commits to it.
  component ColorPicker: Column {
    id: picker
    property string current: "ff0033"
    property color draft: "#" + current
    signal picked(string hex)
    width: parent ? parent.width : 0
    spacing: Style.space(6)
    onCurrentChanged: {
      draft = "#" + current
    }

    Row {
      id: pickerSwatches
      width: parent.width
      spacing: Style.space(6)
      Repeater {
        model: root.swatches
        delegate: Rectangle {
          required property var modelData
          width: (pickerSwatches.width - pickerSwatches.spacing * 7) / 8
          height: Style.space(24)
          color: "#" + modelData
          border.width: picker.current === modelData ? 2 : 0
          border.color: root.textColor
          MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: picker.picked(parent.modelData)
          }
        }
      }
    }
    Row {
      width: parent.width
      spacing: Style.space(8)

      Rectangle {
        anchors.verticalCenter: parent.verticalCenter
        width: Style.space(30)
        height: Style.space(30)
        color: picker.draft
        border.width: 1
        border.color: root.mutedColor
      }
      Rectangle {
        id: hueStrip
        anchors.verticalCenter: parent.verticalCenter
        width: parent.width - Style.space(30) - hexField.width - parent.spacing * 2
        height: Style.space(30)
        gradient: Gradient {
          orientation: Gradient.Horizontal
          GradientStop { position: 0.000; color: "#ff0000" }
          GradientStop { position: 0.167; color: "#ffff00" }
          GradientStop { position: 0.333; color: "#00ff00" }
          GradientStop { position: 0.500; color: "#00ffff" }
          GradientStop { position: 0.667; color: "#0000ff" }
          GradientStop { position: 0.833; color: "#ff00ff" }
          GradientStop { position: 1.000; color: "#ff0000" }
        }
        MouseArea {
          anchors.fill: parent
          cursorShape: Qt.CrossCursor
          function preview(mouse) {
            picker.draft = Qt.hsva(Math.max(0, Math.min(0.9999, mouse.x / width)), 1, 1, 1)
          }
          onPressed: function(mouse) { preview(mouse) }
          onPositionChanged: function(mouse) { preview(mouse) }
          onReleased: picker.picked(String(picker.draft).slice(1, 7))
        }
      }
      // Hex entry driven by keys, not an editable text control: Qt's text
      // controls read the Wayland clipboard on every clipboard change to update
      // canPaste, so an oversized or slow clipboard owner could stall the shared
      // shell while the picker is open. This entry never touches the clipboard.
      FocusScope {
        id: hexField
        anchors.verticalCenter: parent.verticalCenter
        width: Style.space(110)
        height: Style.space(30)
        property string draft: ""

        onActiveFocusChanged: {
          root.hexFieldFocused = activeFocus
          draft = activeFocus ? picker.current : ""
        }

        Rectangle {
          anchors.fill: parent
          radius: Style.space(4)
          color: "transparent"
          border.width: 1
          border.color: hexField.activeFocus ? root.rogRed : Qt.alpha(root.textColor, 0.25)
        }
        Text {
          anchors.verticalCenter: parent.verticalCenter
          x: Style.space(10)
          textFormat: Text.PlainText
          text: "#" + (hexField.activeFocus ? hexField.draft + "\u258f" : picker.current)
          color: root.textColor
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
        }
        MouseArea {
          anchors.fill: parent
          cursorShape: Qt.IBeamCursor
          onClicked: hexField.forceActiveFocus()
        }

        Keys.onPressed: function(event) {
          if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            if (draft.length === 6) picker.picked(draft)
            root.forceActiveFocus()
          } else if (event.key === Qt.Key_Escape) {
            root.forceActiveFocus()
          } else if (event.key === Qt.Key_Backspace) {
            draft = draft.slice(0, -1)
          } else if (/^[0-9a-fA-F]$/.test(event.text) && draft.length < 6) {
            draft += event.text.toLowerCase()
          }
          event.accepted = true
        }
      }
    }
  }

  component Chip: Item {
    property string title: ""
    property bool lit: false
    implicitWidth: chipText.implicitWidth + Style.space(22)
    width: implicitWidth
    height: Style.space(24)
    onLitChanged: chipCanvas.requestPaint()

    Canvas {
      readonly property color paintAccent: root.rogRed
      onPaintAccentChanged: requestPaint()
      id: chipCanvas
      anchors.fill: parent
      onWidthChanged: requestPaint()
      onPaint: {
        var ctx = getContext("2d")
        ctx.reset()
        var slant = height * 0.35
        ctx.beginPath()
        ctx.moveTo(slant, 0)
        ctx.lineTo(width, 0)
        ctx.lineTo(width - slant, height)
        ctx.lineTo(0, height)
        ctx.closePath()
        ctx.fillStyle = parent.lit ? root.rogRed : root.trackColor
        ctx.fill()
      }
    }
    Text {
      id: chipText
      anchors.centerIn: parent
      text: parent.title
      color: parent.lit ? root.onAccent : root.mutedColor
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: true
      font.letterSpacing: 1
    }
  }

  component Spark: Column {
    id: spark
    property string title: ""
    property string series: "cpu"
    property real low: 0
    property real high: 100
    spacing: Style.space(4)

    Text {
      text: spark.title
      color: root.mutedColor
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }
    Canvas {
      readonly property color paintAccent: root.rogRed
      onPaintAccentChanged: requestPaint()
      id: sparkCanvas
      width: parent.width
      height: Style.space(42)
      readonly property int revision: root.historyRevision
      onRevisionChanged: requestPaint()
      onWidthChanged: requestPaint()
      onPaint: {
        var ctx = getContext("2d")
        ctx.reset()
        ctx.fillStyle = root.trackColor
        ctx.globalAlpha = 0.55
        ctx.fillRect(0, 0, width, height)
        ctx.globalAlpha = 1
        var points = root.history
        if (points.length < 2) return
        var now = Date.now() / 1000
        var xAt = function(point) { return width * (1 - (now - point.t) / root.historySeconds) }
        var yAt = function(point) {
          var value = (point[spark.series] - spark.low) / (spark.high - spark.low)
          return height - 1 - (height - 2) * Math.max(0, Math.min(1, value))
        }
        ctx.beginPath()
        ctx.moveTo(xAt(points[0]), yAt(points[0]))
        for (var i = 1; i < points.length; i++) ctx.lineTo(xAt(points[i]), yAt(points[i]))
        ctx.strokeStyle = root.rogRed
        ctx.lineWidth = Math.max(1, Style.space(2))
        ctx.stroke()
        ctx.lineTo(xAt(points[points.length - 1]), height)
        ctx.lineTo(xAt(points[0]), height)
        ctx.closePath()
        ctx.fillStyle = root.rogRed
        ctx.globalAlpha = 0.16
        ctx.fill()
      }
    }
  }

  component OptionRow: Row {
    id: optionRow
    property var options: []
    property var current: ""
    property string suffix: ""
    signal picked(var option)
    width: parent.width
    spacing: Style.space(2)

    Repeater {
      model: optionRow.options
      delegate: ProfileTab {
        required property var modelData
        width: (optionRow.width - optionRow.spacing * (optionRow.options.length - 1)) / optionRow.options.length
        height: Style.space(28)
        title: String(modelData) + optionRow.suffix
        active: String(optionRow.current) === String(modelData)
        onClicked: optionRow.picked(modelData)
      }
    }
  }

  component Rule: Rectangle {
    width: parent.width
    height: 1
    color: root.trackColor
  }

  component SectionLabel: Text {
    color: root.mutedColor
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
    font.bold: true
    font.letterSpacing: 2
  }

  component Stat: Item {
    property string label: ""
    property string value: ""
    width: parent.width
    implicitHeight: statValue.implicitHeight

    Text {
      text: parent.label
      color: root.mutedColor
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
    }
    Text {
      id: statValue
      anchors.right: parent.right
      text: parent.value
      color: root.textColor
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      font.bold: true
    }
  }

  // 270 degree arc with a soft glow under the value.
  component Gauge: Item {
    id: gauge
    property real value: 0
    property string big: ""
    property string label: ""
    property string sub: ""
    height: width

    Canvas {
      readonly property color paintAccent: root.rogRed
      onPaintAccentChanged: requestPaint()
      id: gaugeCanvas
      anchors.fill: parent
      property real shown: gauge.value
      Behavior on shown { NumberAnimation { duration: 420; easing.type: Easing.OutCubic } }
      onShownChanged: requestPaint()
      onWidthChanged: requestPaint()
      onPaint: {
        var ctx = getContext("2d")
        ctx.reset()
        var cx = width / 2, cy = height / 2
        var r = Math.min(width, height) / 2 - Style.space(7)
        var start = Math.PI * 0.75, sweep = Math.PI * 1.5
        ctx.lineCap = "butt"
        ctx.strokeStyle = root.trackColor
        ctx.lineWidth = Style.space(5)
        ctx.beginPath(); ctx.arc(cx, cy, r, start, start + sweep); ctx.stroke()
        var end = start + sweep * Math.max(0.005, shown)
        ctx.strokeStyle = root.rogRed
        ctx.globalAlpha = 0.22
        ctx.lineWidth = Style.space(12)
        ctx.beginPath(); ctx.arc(cx, cy, r, start, end); ctx.stroke()
        ctx.globalAlpha = 1
        ctx.lineWidth = Style.space(5)
        ctx.beginPath(); ctx.arc(cx, cy, r, start, end); ctx.stroke()
      }
    }

    Column {
      anchors.centerIn: parent
      spacing: 0

      Text {
        anchors.horizontalCenter: parent.horizontalCenter
        text: gauge.label
        color: root.rogRed
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        font.bold: true
        font.letterSpacing: 2
      }
      Text {
        anchors.horizontalCenter: parent.horizontalCenter
        text: gauge.big
        color: root.textColor
        font.family: root.fontFamily
        font.pixelSize: Style.font.displayLarge
        font.bold: true
      }
      Text {
        anchors.horizontalCenter: parent.horizontalCenter
        text: gauge.sub
        color: root.mutedColor
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }
    }
  }

  // Slanted tab in the ROG style.
  component ProfileTab: Item {
    id: tab
    property string title: ""
    property bool active: false
    signal clicked()
    height: Style.space(36)
    onActiveChanged: tabCanvas.requestPaint()

    Canvas {
      readonly property color paintAccent: root.rogRed
      onPaintAccentChanged: requestPaint()
      id: tabCanvas
      anchors.fill: parent
      property bool hovered: tabMouse.containsMouse
      onHoveredChanged: requestPaint()
      onWidthChanged: requestPaint()
      onPaint: {
        var ctx = getContext("2d")
        ctx.reset()
        var slant = height * 0.35
        ctx.beginPath()
        ctx.moveTo(slant, 0)
        ctx.lineTo(width, 0)
        ctx.lineTo(width - slant, height)
        ctx.lineTo(0, height)
        ctx.closePath()
        ctx.fillStyle = tab.active ? root.rogRed : (hovered ? root.rogRedDim : root.trackColor)
        ctx.fill()
      }
    }
    Text {
      anchors.centerIn: parent
      text: tab.title.toUpperCase()
      color: tab.active ? root.onAccent : (tabMouse.containsMouse ? root.textColor : root.mutedColor)
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: true
      font.letterSpacing: 1.2
    }
    MouseArea {
      id: tabMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: tab.clicked()
    }
  }
}
