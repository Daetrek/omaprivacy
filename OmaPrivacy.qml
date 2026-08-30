import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

Panel {
  id: root
  moduleName: "io.github.daetrek.omaprivacy"
  ipcTarget: "io.github.daetrek.omaprivacy"

  readonly property string helperPath: Quickshell.env("HOME")
    + "/.config/omarchy/plugins/io.github.daetrek.omaprivacy/bin/omaprivacy"
  property var captures: []
  property var permissions: []
  property var browserPermissions: []
  property var browserProfiles: []
  property var runningBrowsers: []
  property var historyRows: []
  property var browserHealth: []
  property var automation: ({ captureAlerts: true, autoLock: false, autoUntrustedWifi: false, trustedWifi: [], currentWifi: "" })
  property var leakResult: null
  property var privacy: ({ enabled: false, microphoneMuted: null, dnd: null, locationEnabled: null })
  property var locationShield: ({ enabled: false, enabledAt: "", incomplete: false })
  property string permissionError: ""
  property string browserPermissionError: ""
  property string actionError: ""
  property string scanError: ""
  property bool scanLoading: false
  property bool refreshPending: false
  property bool hasScanned: false
  property bool actionBusy: false
  property var pendingPermission: null
  property string pendingAction: ""
  property string currentView: "overview"
  property string activityFilter: "all"
  property string ruleKind: "microphone"

  readonly property bool captureActive: captures.length > 0
  readonly property bool privacyEnabled: privacy && privacy.enabled === true
  readonly property int microphoneCaptures: captures.filter(function(row) { return row.kind === "microphone" }).length
  readonly property int cameraCaptures: captures.filter(function(row) { return row.kind === "camera" }).length
  readonly property int screenCaptures: captures.filter(function(row) { return row.kind === "screen" }).length
  readonly property int allowedBrowserSites: browserPermissions.filter(function(row) { return row.decision === "allow" }).length
  readonly property int allowedLocationSites: browserPermissions.filter(function(row) { return row.kind === "location" && row.decision === "allow" }).length
  readonly property int browserLocationAvailable: browserHealth.filter(function(row) { return row.location !== "blocked" }).length
  readonly property bool browserLocationBlocked: browserHealth.length > 0 && browserLocationAvailable === 0
  readonly property int appRuleCount: Object.keys(automation.microphoneRules || ({})).length
    + Object.keys(automation.cameraRules || ({})).length
    + Object.keys(automation.screenRules || ({})).length
  readonly property var ruleApps: {
    var seen = ({})
    var apps = []
    captures.concat(historyRows).forEach(function(row) {
      var app = String(row.app || "")
      if (row.kind === ruleKind && app !== "" && app !== "OmaPrivacy" && !seen[app.toLowerCase()]) {
        seen[app.toLowerCase()] = true
        apps.push(app)
      }
    })
    var rules = automation[ruleKind + "Rules"] || ({})
    Object.keys(rules).forEach(function(app) {
      if (!seen[app.toLowerCase()]) {
        seen[app.toLowerCase()] = true
        apps.push(app)
      }
    })
    return apps.sort(function(left, right) { return left.toLowerCase().localeCompare(right.toLowerCase()) })
  }
  readonly property var protectionCards: [
    {
      label: "MICROPHONE",
      value: microphoneCaptures > 0 ? "IN USE" : (privacy.microphoneMuted === true ? "MUTED" : (privacy.microphoneMuted === false ? "AVAILABLE" : "UNKNOWN")),
      detail: microphoneCaptures > 0 ? microphoneCaptures + " active · rules" : "Click for app rules",
      urgent: microphoneCaptures > 0,
      target: "apprules",
      ruleKind: "microphone"
    },
    {
      label: "CAMERA",
      value: cameraCaptures > 0 ? "IN USE" : ((privacyEnabled && (privacy.preset === "private" || privacy.preset === "lockdown")) ? "BROWSER BLOCK" : "AVAILABLE"),
      detail: cameraCaptures > 0 ? cameraCaptures + " active" : "Webcam access",
      urgent: cameraCaptures > 0,
      target: "apprules",
      ruleKind: "camera"
    },
    {
      label: "LOCATION",
      value: browserLocationBlocked && privacy.locationEnabled === false ? "PRECISE BLOCKED"
        : (browserLocationBlocked ? "BROWSERS BLOCKED"
          : (privacy.locationEnabled === false ? "SYSTEM OFF ONLY"
            : (privacy.locationEnabled === true ? "AVAILABLE" : "BROWSER AVAILABLE"))),
      detail: browserLocationBlocked ? "IP estimates remain possible" : browserLocationAvailable + " browser profiles available",
      urgent: !browserLocationBlocked,
      target: "location"
    },
    {
      label: "BROWSER ACCESS",
      value: allowedBrowserSites === 0 ? "NONE ALLOWED" : allowedBrowserSites + " ALLOWED",
      detail: browserProfiles.length + (browserProfiles.length === 1 ? " profile" : " profiles"),
      urgent: allowedBrowserSites > 0,
      target: "permissions"
    },
    {
      label: "SCREEN SHARE",
      value: screenCaptures > 0 ? "SHARING" : "CLEAR",
      detail: screenCaptures > 0 ? screenCaptures + " active" : "No active stream",
      urgent: screenCaptures > 0,
      target: "apprules",
      ruleKind: "screen"
    },
    {
      label: "NETWORK",
      value: leakResult ? "CHECKED" : "NOT CHECKED",
      detail: leakResult ? "IP + DNS inspected" : "Check exposure",
      urgent: false,
      target: "protection"
    }
  ]
  readonly property var findings: {
    var rows = []
    if (captureActive) {
      rows.push({
        severity: "urgent",
        title: captures.length + (captures.length === 1 ? " active capture" : " active captures"),
        detail: captures.map(function(row) { return row.app + " · " + root.kindName(row.kind) }).join(", "),
        action: "view",
        actionLabel: "View activity",
        target: "activity"
      })
    }
    if (locationShield.incomplete === true) {
      rows.push({
        severity: "urgent",
        title: "Location Shield setup was interrupted",
        detail: "Open Location Control and enable the shield again to restore the saved profile state and retry safely.",
        action: "view",
        actionLabel: "Recover",
        target: "location"
      })
    }

    var preset = String(privacy.preset || "normal")
    var drift = []
    if (privacyEnabled && preset === "lockdown" && privacy.microphoneMuted === false)
      drift.push("microphone is not muted")
    if (privacyEnabled && (preset === "private" || preset === "lockdown") && privacy.locationEnabled === true)
      drift.push("system location is still on")
    if (privacyEnabled && (preset === "private" || preset === "lockdown")) {
      var exposedBrowsers = browserHealth.filter(function(row) {
        return row.location !== "blocked" || row.camera !== "blocked"
      }).length
      if (exposedBrowsers > 0)
        drift.push(exposedBrowsers + (exposedBrowsers === 1 ? " browser profile is not blocked" : " browser profiles are not blocked"))
    }
    if (privacyEnabled && (preset === "meeting" || preset === "lockdown") && privacy.dnd === false)
      drift.push("Do Not Disturb is off")
    if (drift.length > 0) {
      rows.push({
        severity: "urgent",
        title: "Privacy mode needs repair",
        detail: drift.join(" · "),
        action: "repair",
        actionLabel: "Repair",
        target: "location"
      })
    }

    if (allowedBrowserSites > 0) {
      rows.push({
        severity: "review",
        title: allowedBrowserSites + (allowedBrowserSites === 1 ? " site retains access" : " sites retain access"),
        detail: "Saved browser allow decisions remain until you revoke them.",
        action: "view",
        actionLabel: "Review",
        target: "permissions"
      })
    }
    if (!privacyEnabled && browserLocationAvailable > 0) {
      rows.push({
        severity: "review",
        title: "Browser location remains available",
        detail: (privacy.locationEnabled === false ? "System location is off, but " : "")
          + browserLocationAvailable + (browserLocationAvailable === 1 ? " browser profile uses a separate location provider." : " browser profiles use separate location providers."),
        action: "view",
        actionLabel: "Review",
        target: "location"
      })
    }
    if (permissionError !== "") {
      rows.push({
        severity: "warning",
        title: "Desktop permissions could not be checked",
        detail: permissionError,
        action: "view",
        actionLabel: "Details",
        target: "permissions"
      })
    }
    if (browserPermissionError !== "") {
      rows.push({
        severity: "warning",
        title: "Some browser profiles could not be checked",
        detail: browserPermissionError,
        action: "view",
        actionLabel: "Details",
        target: "permissions"
      })
    }
    return rows
  }
  readonly property string protectionTitle: captureActive ? "CAPTURE ACTIVE"
    : (privacyEnabled ? "PROTECTED · " + String(privacy.preset || "lockdown").toUpperCase()
      : "PROTECTED")
  readonly property var filteredHistory: historyRows.filter(function(row) {
    if (activityFilter === "capture") return row.event === "started" || row.event === "stopped"
    if (activityFilter === "changes") return row.event !== "started" && row.event !== "stopped"
    return true
  })
  readonly property string statusLabel: captureActive
    ? captures.length + (captures.length === 1 ? " active capture" : " active captures")
    : (privacyEnabled ? "Privacy mode" : "Private")

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  function kindLabel(kind) {
    if (kind === "camera") return "CAM"
    if (kind === "screen") return "SCR"
    return "MIC"
  }

  function kindName(kind) {
    if (kind === "camera") return "Camera"
    if (kind === "screen") return "Screen sharing"
    return "Microphone"
  }

  function healthLabel(value) {
    if (value === "provider-dependent") return "Browser-managed"
    if (value === "blocked") return "Blocked"
    return "Ready"
  }

  function refresh(queueIfBusy) {
    if (scanProc.running) {
      if (queueIfBusy !== false) refreshPending = true
      return
    }
    refreshPending = false
    scanLoading = true
    scanProc.running = true
  }

  function applyScan(raw) {
    try {
      var result = JSON.parse(String(raw || "{}"))
      var nextCaptures = result.captures || []
      var nextPermissions = result.permissions || []
      var nextBrowserPermissions = result.browserPermissions || []
      var nextBrowserProfiles = result.browserProfiles || []
      var nextRunningBrowsers = result.runningBrowsers || []
      var nextHistory = result.history || []
      var nextPrivacy = result.privacy || ({ enabled: false, microphoneMuted: null, dnd: null, locationEnabled: null })
      var nextLocationShield = result.locationShield || ({ enabled: false, enabledAt: "", incomplete: false })
      var nextHealth = result.browserHealth || []
      var nextAutomation = result.automation || ({})
      var nextPermissionError = String(result.permissionError || "")
      var nextBrowserPermissionError = String(result.browserPermissionError || "")

      // The bar scans continuously, but most samples are identical. Replacing
      // a QML model on every sample destroys and recreates every delegate,
      // producing a visible flash in an open panel.
      if (JSON.stringify(captures) !== JSON.stringify(nextCaptures)) captures = nextCaptures
      if (JSON.stringify(permissions) !== JSON.stringify(nextPermissions)) permissions = nextPermissions
      if (JSON.stringify(browserPermissions) !== JSON.stringify(nextBrowserPermissions)) browserPermissions = nextBrowserPermissions
      if (JSON.stringify(browserProfiles) !== JSON.stringify(nextBrowserProfiles)) browserProfiles = nextBrowserProfiles
      if (JSON.stringify(runningBrowsers) !== JSON.stringify(nextRunningBrowsers)) runningBrowsers = nextRunningBrowsers
      if (JSON.stringify(historyRows) !== JSON.stringify(nextHistory)) historyRows = nextHistory
      if (JSON.stringify(privacy) !== JSON.stringify(nextPrivacy)) privacy = nextPrivacy
      if (JSON.stringify(locationShield) !== JSON.stringify(nextLocationShield)) locationShield = nextLocationShield
      if (JSON.stringify(browserHealth) !== JSON.stringify(nextHealth)) browserHealth = nextHealth
      if (JSON.stringify(automation) !== JSON.stringify(nextAutomation)) automation = nextAutomation
      if (permissionError !== nextPermissionError) permissionError = nextPermissionError
      if (browserPermissionError !== nextBrowserPermissionError) browserPermissionError = nextBrowserPermissionError
      scanError = ""
      hasScanned = true
    } catch (error) {
      scanError = "OmaPrivacy returned invalid scan data."
    }
  }

  function requestRevoke(permission) {
    pendingPermission = permission
    pendingAction = "revoke"
    confirm.message = "Revoke " + permission.app + " access to "
      + permission.table + " / " + permission.object + "?\n\n"
      + "This changes the desktop permission store. The application may ask again later."
    confirm.confirmText = "Revoke"
    confirm.opened = true
  }

  function requestBrowserRevoke(permission) {
    pendingPermission = permission
    pendingAction = "browser-revoke"
    confirm.message = "Revoke " + permission.origin + " " + permission.kind
      + " permission in " + permission.browser + "?\n\n"
      + "The browser must be fully closed. OmaPrivacy will keep a local backup and the site may ask again later."
    confirm.confirmText = "Revoke"
    confirm.opened = true
  }

  function requestPrivacyEnable() {
    pendingPermission = null
    pendingAction = "privacy-enable"
    confirm.message = "Enable Privacy Mode?\n\nThis will close ALL running browsers and browser-app windows"
      + (runningBrowsers.length ? " (" + runningBrowsers.join(", ") + ")" : "")
      + ", block browser location and webcam requests, mute the default microphone, disable system location, and enable Do Not Disturb. Previous settings are restored when Privacy Mode is turned off."
    confirm.confirmText = "Enable"
    confirm.opened = true
  }

  function requestPrivacyDisable() {
    pendingPermission = null
    pendingAction = "privacy-disable"
    confirm.message = "Turn off Privacy Mode?\n\nThis will close ALL running browsers and browser-app windows"
      + (runningBrowsers.length ? " (" + runningBrowsers.join(", ") + ")" : "")
      + " so OmaPrivacy can safely restore their previous location and webcam settings."
    confirm.confirmText = "Disable"
    confirm.opened = true
  }

  function requestLocationShieldEnable() {
    pendingPermission = null
    pendingAction = "location-shield-enable"
    confirm.message = "Enable Browser Location Shield?\n\nThis will close ALL running browsers and browser-app windows"
      + (runningBrowsers.length ? " (" + runningBrowsers.join(", ") + ")" : "")
      + ", save their precise-geolocation settings, block browser geolocation defaults and saved site grants, then restore those settings when the shield is turned off. Rough IP-based location estimates remain possible."
    confirm.confirmText = "Enable shield"
    confirm.opened = true
  }

  function requestLocationShieldDisable() {
    pendingPermission = null
    pendingAction = "location-shield-disable"
    confirm.message = "Turn off Browser Location Shield?\n\nThis will close ALL running browsers and restore the precise-geolocation settings saved when the shield was enabled."
    confirm.confirmText = "Disable shield"
    confirm.opened = true
  }

  function requestPreset(preset) {
    pendingPermission = { preset: preset }
    pendingAction = "preset"
    confirm.message = "Apply the " + preset + " preset?\n\nPrivate and Lockdown close browsers so their saved webcam and location settings can be changed safely."
    confirm.confirmText = "Apply"
    confirm.opened = true
  }

  function requestCleanup() {
    pendingPermission = null
    pendingAction = "cleanup"
    confirm.message = "Revoke every saved browser permission?\n\nAll browsers must be closed. Profile backups are created before changes."
    confirm.confirmText = "Clean up"
    confirm.opened = true
  }

  function runAction(arguments) {
    actionError = ""
    actionBusy = true
    actionProc.command = [helperPath].concat(arguments)
    actionProc.running = true
  }

  function runFinding(finding) {
    if (finding.action === "repair") {
      requestPreset(String(privacy.preset || "lockdown"))
      return
    }
    currentView = finding.target || "overview"
  }

  function appRule(app) {
    var rules = automation[ruleKind + "Rules"] || ({})
    var names = Object.keys(rules)
    for (var index = 0; index < names.length; index++) {
      if (names[index].toLowerCase() === String(app).toLowerCase()) return String(rules[names[index]])
    }
    return "default"
  }

  function nextAppRule(app) {
    var current = appRule(app)
    return current === "default" ? "alert" : (current === "alert" ? "stop" : "default")
  }

  function appRuleLabel(app) {
    var mode = appRule(app)
    if (mode === "alert") return "ALWAYS ALERT"
    if (mode === "stop") return "AUTO-STOP"
    return "DEFAULT"
  }

  function openAppRules(kind) {
    ruleKind = kind
    currentView = "apprules"
  }

  function runConfirmedAction() {
    confirm.opened = false
    actionError = ""
    actionBusy = true
    if (pendingAction === "revoke" && pendingPermission) {
      actionProc.command = [helperPath, "revoke", pendingPermission.table,
        pendingPermission.object, pendingPermission.app]
    } else if (pendingAction === "browser-revoke" && pendingPermission) {
      actionProc.command = [helperPath, "browser-revoke", pendingPermission.profile,
        pendingPermission.kind, pendingPermission.origin]
    } else if (pendingAction === "privacy-enable") {
      actionProc.command = [helperPath, "privacy", "enable"]
    } else if (pendingAction === "privacy-disable") {
      actionProc.command = [helperPath, "privacy", "disable"]
    } else if (pendingAction === "location-shield-enable") {
      actionProc.command = [helperPath, "location-shield", "enable"]
    } else if (pendingAction === "location-shield-disable") {
      actionProc.command = [helperPath, "location-shield", "disable"]
    } else if (pendingAction === "preset" && pendingPermission) {
      actionProc.command = [helperPath, "preset", pendingPermission.preset]
    } else if (pendingAction === "cleanup") {
      actionProc.command = [helperPath, "cleanup"]
    } else {
      actionBusy = false
      return
    }
    actionProc.running = true
  }

  // Refresh on both open and close. If another scan is still finishing,
  // refresh() queues one more pass instead of silently dropping the request.
  onOpenedChanged: refresh()
  Component.onCompleted: refresh()

  Timer {
    interval: 3000
    repeat: true
    running: true
    // A slow periodic scan is simply skipped. Only explicit/user-driven
    // refreshes queue a follow-up pass.
    onTriggered: root.refresh(false)
  }

  Component {
    id: animatedLock
    Item {
      id: lockMark
      readonly property bool unlocked: root.captureActive
      readonly property color markColor: unlocked ? Color.urgent : root.barForeground

      Rectangle {
        id: shackle
        width: parent.width * 0.48
        height: parent.height * 0.49
        x: parent.width * 0.26
        y: parent.height * 0.08
        radius: width / 2
        color: "transparent"
        border.width: Math.max(2, parent.width * 0.10)
        border.color: lockMark.markColor
        Behavior on border.color { ColorAnimation { duration: 140 } }
        transform: Rotation {
          id: shackleRotation
          // Pivot on the left: the right side releases first, then the whole
          // shackle slides left into the open position.
          origin.x: 0
          origin.y: shackle.height
          angle: 0
        }
      }

      states: [
        State {
          name: "locked"
          when: !lockMark.unlocked
          PropertyChanges { target: shackleRotation; angle: 0 }
          PropertyChanges { target: shackle; x: lockMark.width * 0.26; y: lockMark.height * 0.08 }
        },
        State {
          name: "unlocked"
          when: lockMark.unlocked
          PropertyChanges { target: shackleRotation; angle: -34 }
          PropertyChanges { target: shackle; x: lockMark.width * 0.17; y: lockMark.height * 0.025 }
        }
      ]

      transitions: [
        Transition {
          from: "locked"; to: "unlocked"
          SequentialAnimation {
            // Release the right side first.
            NumberAnimation { target: shackleRotation; property: "angle"; to: -12; duration: 105; easing.type: Easing.OutQuad }
            // Swing left as a single rigid piece.
            ParallelAnimation {
              NumberAnimation { target: shackleRotation; property: "angle"; to: -41; duration: 180; easing.type: Easing.OutCubic }
              NumberAnimation { target: shackle; property: "x"; to: lockMark.width * 0.14; duration: 180; easing.type: Easing.OutCubic }
              NumberAnimation { target: shackle; property: "y"; to: lockMark.height * 0.015; duration: 180; easing.type: Easing.OutCubic }
            }
            // One restrained settle, then stay still.
            ParallelAnimation {
              NumberAnimation { target: shackleRotation; property: "angle"; to: -34; duration: 115; easing.type: Easing.OutQuad }
              NumberAnimation { target: shackle; property: "x"; to: lockMark.width * 0.17; duration: 115; easing.type: Easing.OutQuad }
              NumberAnimation { target: shackle; property: "y"; to: lockMark.height * 0.025; duration: 115; easing.type: Easing.OutQuad }
            }
            NumberAnimation { target: lockMark; property: "scale"; to: 1.06; duration: 70; easing.type: Easing.OutQuad }
            NumberAnimation { target: lockMark; property: "scale"; to: 1.0; duration: 100; easing.type: Easing.InOutQuad }
          }
        },
        Transition {
          from: "unlocked"; to: "locked"
          SequentialAnimation {
            NumberAnimation { target: shackleRotation; property: "angle"; to: -40; duration: 75; easing.type: Easing.InQuad }
            ParallelAnimation {
              NumberAnimation { target: shackleRotation; property: "angle"; to: -10; duration: 180; easing.type: Easing.InOutCubic }
              NumberAnimation { target: shackle; property: "x"; to: lockMark.width * 0.26; duration: 180; easing.type: Easing.InOutCubic }
              NumberAnimation { target: shackle; property: "y"; to: lockMark.height * 0.08; duration: 180; easing.type: Easing.InOutCubic }
            }
            NumberAnimation { target: shackleRotation; property: "angle"; to: 0; duration: 105; easing.type: Easing.InQuad }
          }
        }
      ]

      Rectangle {
        id: lockBody
        anchors.horizontalCenter: parent.horizontalCenter
        y: parent.height * 0.43
        width: parent.width * 0.72
        height: parent.height * 0.48
        radius: Math.max(2, width * 0.12)
        color: lockMark.markColor
        Behavior on color { ColorAnimation { duration: 140 } }
      }
    }
  }

  Process {
    id: scanProc
    command: [root.helperPath, "scan"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyScan(text)
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var message = String(text || "").trim()
        if (message !== "") root.scanError = message
      }
    }
    onExited: function(exitCode) {
      root.scanLoading = false
      if (exitCode !== 0 && root.scanError === "")
        root.scanError = "OmaPrivacy could not inspect the desktop privacy backends."
      if (root.refreshPending) Qt.callLater(root.refresh)
    }
  }

  Process {
    id: reloadPluginProc
    command: ["omarchy-shell", "shell", "rescanPlugins"]
  }

  Process {
    id: actionProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var raw = String(text || "").trim()
        if (raw === "") return
        try {
          var result = JSON.parse(raw)
          if (result.ok === false) root.actionError = String(result.error || "Action failed")
          if (result.publicIp !== undefined) root.leakResult = result
        } catch (error) {}
      }
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var message = String(text || "").trim()
        if (message !== "") root.actionError = message
      }
    }
    onExited: function(exitCode) {
      root.actionBusy = false
      if (exitCode !== 0 && root.actionError === "") root.actionError = "The requested privacy action failed."
      root.pendingAction = ""
      root.pendingPermission = null
      root.refresh()
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    iconComponent: animatedLock
    active: root.captureActive
    tooltipText: "OmaPrivacy: " + root.statusLabel
    onPressed: root.toggle()
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(460))
    // Keep the layer-surface geometry stable while scan results arrive. A
    // content-driven height caused the popup to unmap and remap whenever the
    // first result (or a changed history list) altered implicitHeight.
    contentHeight: panel.cappedContentHeight(Style.space(620))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: confirm.opened
      Keys.onPressed: function(event) {
        if (confirm.handleKey(event)) event.accepted = true
      }
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(text) { if (text === "r" || text === "R") root.refresh() }
    }

    Flickable {
      anchors.fill: parent
      contentWidth: width
      contentHeight: content.implicitHeight
      clip: true
      boundsBehavior: Flickable.StopAtBounds

      ColumnLayout {
        id: content
        width: parent.width
        spacing: Style.space(12)

        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(12)
          Rectangle {
            width: Style.space(44)
            height: width
            radius: width / 2
            color: root.captureActive ? Color.accent : Style.selectedFillFor(root.barForeground, Color.accent)
            Loader {
              anchors.centerIn: parent
              width: parent.width * 0.62
              height: width
              sourceComponent: animatedLock
            }
          }
          ColumnLayout {
            Layout.fillWidth: true
            spacing: Style.space(2)
            Text {
              text: root.protectionTitle
              color: root.barForeground
              font.family: Style.font.family
              font.pixelSize: Style.font.title
              font.bold: true
            }
            Text {
              text: root.captureActive ? root.statusLabel + " detected by PipeWire."
                : "No active capture or unresolved browser warning."
              color: root.barForeground
              opacity: 0.65
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
              Layout.fillWidth: true
            }
          }
          ColumnLayout {
            spacing: Style.space(4)
            Button { text: root.scanLoading ? "Refreshing…" : "Refresh"; onClicked: root.refresh() }
            Button {
              text: "Reload plugin"
              enabled: !reloadPluginProc.running
              onClicked: {
                root.close()
                reloadPluginProc.running = true
              }
            }
          }
        }

        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(5)
          Button { text: "Overview"; enabled: root.currentView !== "overview"; onClicked: root.currentView = "overview" }
          Button { text: "Permissions"; enabled: root.currentView !== "permissions"; onClicked: root.currentView = "permissions" }
          Button { text: "Activity"; enabled: root.currentView !== "activity"; onClicked: root.currentView = "activity" }
          Button { text: "Protection"; enabled: root.currentView !== "protection"; onClicked: root.currentView = "protection" }
        }

        Rectangle {
          visible: root.currentView === "overview"
          Layout.fillWidth: true
          implicitHeight: privacyRow.implicitHeight + Style.space(12)
          radius: Style.cornerRadius
          color: Style.selectedFillFor(root.barForeground, Color.accent)
          RowLayout {
            id: privacyRow
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            anchors.margins: Style.space(6)
            spacing: Style.space(10)
            ColumnLayout {
              Layout.fillWidth: true
              spacing: Style.space(2)
              Text {
                text: "PRIVACY MODE"
                color: root.barForeground
                font.family: Style.font.family
                font.pixelSize: Style.font.body
                font.bold: true
              }
              Text {
                text: root.privacyEnabled
                  ? String(root.privacy.preset || "lockdown").toUpperCase() + " preset active"
                  : "Close browsers, block webcam + browser/system location, mute the microphone, and silence notifications"
                color: root.barForeground
                opacity: 0.6
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                wrapMode: Text.WordWrap
                Layout.fillWidth: true
              }
            }
            ToggleSwitch {
              checked: root.privacyEnabled
              busy: root.actionBusy
              foreground: root.barForeground
              onToggled: root.privacyEnabled ? root.requestPrivacyDisable() : root.requestPrivacyEnable()
            }
          }
        }

        GridLayout {
          visible: root.currentView === "overview"
          Layout.fillWidth: true
          columns: 3
          columnSpacing: Style.space(7)
          rowSpacing: Style.space(7)
          Repeater {
            model: root.protectionCards
            Rectangle {
              required property var modelData
              Layout.fillWidth: true
              Layout.preferredWidth: 1
              implicitHeight: Style.space(72)
              radius: Style.cornerRadius
              color: Style.selectedFillFor(root.barForeground, Color.accent)
              opacity: protectionCardMouse.containsMouse ? 1.0 : 0.88
              Behavior on opacity { NumberAnimation { duration: 100 } }
              ColumnLayout {
                anchors.fill: parent
                anchors.margins: Style.space(7)
                spacing: 0
                Text {
                  text: parent.parent.modelData.label
                  color: root.barForeground; opacity: 0.5; font.family: Style.font.family
                  font.pixelSize: Style.font.caption; font.bold: true
                  elide: Text.ElideRight; Layout.fillWidth: true
                }
                Text {
                  text: parent.parent.modelData.value
                  color: parent.parent.modelData.urgent ? Color.urgent : root.barForeground
                  font.family: Style.font.family; font.pixelSize: Style.font.body; font.bold: true
                  elide: Text.ElideRight; Layout.fillWidth: true
                }
                Text {
                  text: parent.parent.modelData.detail
                  color: root.barForeground; opacity: 0.45; font.family: Style.font.family
                  font.pixelSize: Style.font.caption; elide: Text.ElideRight; Layout.fillWidth: true
                }
              }
              MouseArea {
                id: protectionCardMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: parent.modelData.ruleKind
                  ? root.openAppRules(parent.modelData.ruleKind)
                  : root.currentView = parent.modelData.target
              }
            }
          }
        }

        Rectangle {
          visible: root.currentView === "overview"
          Layout.fillWidth: true
          implicitHeight: appRulesOverviewRow.implicitHeight + Style.space(12)
          radius: Style.cornerRadius
          color: Style.selectedFillFor(root.barForeground, Color.accent)
          RowLayout {
            id: appRulesOverviewRow
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            anchors.margins: Style.space(6)
            spacing: Style.space(8)
            ColumnLayout {
              Layout.fillWidth: true
              spacing: 0
              Text {
                text: "APP RULES"
                color: root.barForeground
                font.family: Style.font.family
                font.pixelSize: Style.font.body
                font.bold: true
              }
              Text {
                text: "Microphone, camera, and screen · " + root.appRuleCount
                  + (root.appRuleCount === 1 ? " configured rule" : " configured rules")
                color: root.barForeground
                opacity: 0.5
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
              }
            }
            Button { text: "Manage"; onClicked: root.openAppRules("microphone") }
          }
        }

        PanelSectionHeader {
          visible: root.currentView === "overview"
          text: root.findings.length > 0 ? "FINDINGS · " + root.findings.length : "FINDINGS"
          foreground: root.barForeground
        }
        Rectangle {
          visible: root.currentView === "overview" && root.findings.length === 0
          Layout.fillWidth: true
          implicitHeight: allClearRow.implicitHeight + Style.space(14)
          radius: Style.cornerRadius
          color: Style.selectedFillFor(root.barForeground, Color.accent)
          RowLayout {
            id: allClearRow
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            anchors.margins: Style.space(7)
            spacing: Style.space(8)
            Text {
              text: "✓"
              color: Color.accent
              font.family: Style.font.family
              font.pixelSize: Style.font.title
              font.bold: true
            }
            ColumnLayout {
              Layout.fillWidth: true
              spacing: 0
              Text {
                text: "All clear"
                color: root.barForeground
                font.family: Style.font.family
                font.pixelSize: Style.font.body
                font.bold: true
              }
              Text {
                text: "No active capture, broken protection, or saved browser allowance needs attention."
                color: root.barForeground
                opacity: 0.5
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                wrapMode: Text.WordWrap
                Layout.fillWidth: true
              }
            }
          }
        }
        Repeater {
          model: root.findings
          Rectangle {
            required property var modelData
            visible: root.currentView === "overview"
            Layout.fillWidth: true
            implicitHeight: findingRow.implicitHeight + Style.space(14)
            radius: Style.cornerRadius
            color: Style.selectedFillFor(root.barForeground, Color.accent)
            RowLayout {
              id: findingRow
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              anchors.margins: Style.space(7)
              spacing: Style.space(8)
              Rectangle {
                width: Style.space(7)
                height: findingText.implicitHeight
                radius: width / 2
                color: parent.parent.modelData.severity === "urgent" ? Color.urgent : Color.accent
              }
              ColumnLayout {
                id: findingText
                Layout.fillWidth: true
                spacing: 0
                Text {
                  text: parent.parent.parent.modelData.title
                  color: root.barForeground
                  font.family: Style.font.family
                  font.pixelSize: Style.font.body
                  font.bold: true
                  elide: Text.ElideRight
                  Layout.fillWidth: true
                }
                Text {
                  text: parent.parent.parent.modelData.detail
                  color: root.barForeground
                  opacity: 0.5
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                  wrapMode: Text.WordWrap
                  Layout.fillWidth: true
                }
              }
              Button {
                text: parent.parent.modelData.actionLabel
                enabled: !root.actionBusy
                onClicked: root.runFinding(parent.parent.modelData)
              }
            }
          }
        }

        RowLayout {
          visible: root.currentView === "apprules"
          Layout.fillWidth: true
          Button { text: "← Overview"; onClicked: root.currentView = "overview" }
          PanelSectionHeader { text: root.kindName(root.ruleKind).toUpperCase() + " APP RULES"; foreground: root.barForeground; Layout.fillWidth: true }
        }
        RowLayout {
          visible: root.currentView === "apprules"
          Layout.fillWidth: true
          spacing: Style.space(6)
          Button { text: "Microphone"; enabled: root.ruleKind !== "microphone"; onClicked: root.ruleKind = "microphone" }
          Button { text: "Camera"; enabled: root.ruleKind !== "camera"; onClicked: root.ruleKind = "camera" }
          Button { text: "Screen"; enabled: root.ruleKind !== "screen"; onClicked: root.ruleKind = "screen" }
        }
        Text {
          visible: root.currentView === "apprules"
          text: "Rules apply to apps OmaPrivacy has observed using " + root.kindName(root.ruleKind).toLowerCase()
            + ". Auto-stop reacts after PipeWire creates the stream; it does not kill the app or affect unrelated streams."
          color: root.barForeground
          opacity: 0.6
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
          Layout.fillWidth: true
        }
        Text {
          visible: root.currentView === "apprules" && root.ruleApps.length === 0
          text: "No " + root.kindName(root.ruleKind).toLowerCase() + " applications have been observed yet. Apps appear here after their first detected capture."
          color: root.barForeground
          opacity: 0.6
          font.family: Style.font.family
          font.pixelSize: Style.font.body
          wrapMode: Text.WordWrap
          Layout.fillWidth: true
        }
        Repeater {
          model: root.ruleApps
          Rectangle {
            required property string modelData
            visible: root.currentView === "apprules"
            Layout.fillWidth: true
            implicitHeight: microphoneRuleRow.implicitHeight + Style.space(14)
            radius: Style.cornerRadius
            color: Style.selectedFillFor(root.barForeground, Color.accent)
            RowLayout {
              id: microphoneRuleRow
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              anchors.margins: Style.space(7)
              spacing: Style.space(8)
              ColumnLayout {
                Layout.fillWidth: true
                spacing: 0
                Text {
                  text: parent.parent.parent.modelData
                  color: root.barForeground
                  font.family: Style.font.family
                  font.pixelSize: Style.font.body
                  font.bold: true
                  elide: Text.ElideRight
                  Layout.fillWidth: true
                }
                Text {
                  text: root.appRule(parent.parent.parent.modelData) === "stop"
                    ? "Matching capture streams are stopped reactively"
                    : (root.appRule(parent.parent.parent.modelData) === "alert"
                      ? "Notify even when general capture alerts are disabled"
                      : "Uses the general capture-alert setting")
                  color: root.barForeground
                  opacity: 0.5
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                  elide: Text.ElideRight
                  Layout.fillWidth: true
                }
              }
              Button {
                text: root.appRuleLabel(parent.parent.modelData)
                enabled: !root.actionBusy
                onClicked: root.runAction(["rule", root.ruleKind, parent.parent.modelData,
                  root.nextAppRule(parent.parent.modelData)])
              }
            }
          }
        }

        RowLayout {
          visible: root.currentView === "location"
          Layout.fillWidth: true
          Button { text: "← Overview"; onClicked: root.currentView = "overview" }
          PanelSectionHeader { text: "LOCATION CONTROL"; foreground: root.barForeground; Layout.fillWidth: true }
        }
        Text {
          visible: root.currentView === "location"
          text: "Location has separate layers. System location, browser geolocation, saved site grants, and IP estimates do not control one another."
          color: root.barForeground; opacity: 0.6; font.family: Style.font.family
          font.pixelSize: Style.font.caption; wrapMode: Text.WordWrap; Layout.fillWidth: true
        }
        Rectangle {
          visible: root.currentView === "location"
          Layout.fillWidth: true
          implicitHeight: locationShieldRow.implicitHeight + Style.space(14)
          radius: Style.cornerRadius
          color: Style.selectedFillFor(root.barForeground, Color.accent)
          RowLayout {
            id: locationShieldRow
            anchors.left: parent.left; anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter; anchors.margins: Style.space(7)
            spacing: Style.space(10)
            ColumnLayout {
              Layout.fillWidth: true; spacing: 0
              Text {
                text: "BROWSER LOCATION SHIELD"
                color: root.barForeground; font.family: Style.font.family
                font.pixelSize: Style.font.body; font.bold: true
              }
              Text {
                text: root.locationShield.incomplete
                  ? "Previous setup was interrupted · enable again to recover safely"
                  : (root.locationShield.enabled
                  ? "Precise browser geolocation is blocked · IP estimates remain possible"
                  : "Blocks browser defaults and saved precise-location grants")
                color: root.barForeground; opacity: 0.55; font.family: Style.font.family
                font.pixelSize: Style.font.caption; wrapMode: Text.WordWrap; Layout.fillWidth: true
              }
            }
            ToggleSwitch {
              checked: root.locationShield.enabled === true
              busy: root.actionBusy
              foreground: root.barForeground
              enabled: !root.actionBusy && !root.privacyEnabled
              onToggled: root.locationShield.enabled ? root.requestLocationShieldDisable() : root.requestLocationShieldEnable()
            }
          }
        }
        GridLayout {
          visible: root.currentView === "location"
          Layout.fillWidth: true
          columns: 2
          columnSpacing: Style.space(7); rowSpacing: Style.space(7)
          Repeater {
            model: [
              { label: "SYSTEM SERVICE", value: root.privacy.locationEnabled === false ? "OFF" : (root.privacy.locationEnabled === true ? "ON" : "UNKNOWN"), detail: "GNOME location" },
              { label: "BROWSER PRECISE", value: root.browserLocationBlocked ? "BLOCKED" : "AVAILABLE", detail: root.browserProfiles.length + " profiles" },
              { label: "SAVED SITE GRANTS", value: String(root.allowedLocationSites), detail: "Persistent allows" },
              { label: "IP ESTIMATE", value: "POSSIBLE", detail: "VPN/proxy controls this" }
            ]
            Rectangle {
              required property var modelData
              Layout.fillWidth: true; Layout.preferredWidth: 1
              implicitHeight: Style.space(68); radius: Style.cornerRadius
              color: Style.selectedFillFor(root.barForeground, Color.accent)
              ColumnLayout {
                anchors.fill: parent; anchors.margins: Style.space(7); spacing: 0
                Text { text: parent.parent.modelData.label; color: root.barForeground; opacity: 0.5; font.family: Style.font.family; font.pixelSize: Style.font.caption; font.bold: true; Layout.fillWidth: true; elide: Text.ElideRight }
                Text { text: parent.parent.modelData.value; color: root.barForeground; font.family: Style.font.family; font.pixelSize: Style.font.body; font.bold: true; Layout.fillWidth: true; elide: Text.ElideRight }
                Text { text: parent.parent.modelData.detail; color: root.barForeground; opacity: 0.45; font.family: Style.font.family; font.pixelSize: Style.font.caption; Layout.fillWidth: true; elide: Text.ElideRight }
              }
            }
          }
        }
        RowLayout {
          visible: root.currentView === "location"
          Layout.fillWidth: true
          spacing: Style.space(7)
          Button { text: "Review site grants"; onClicked: root.currentView = "permissions" }
          Button { text: "Check IP exposure"; enabled: !root.actionBusy; onClicked: root.runAction(["leak-check"]) }
        }
        Text {
          visible: root.currentView === "location"
          text: root.leakResult
            ? "Public IP: " + root.leakResult.publicIp + " · DNS: " + (root.leakResult.dns || []).join(", ")
            : "Blocking precise geolocation cannot hide the public IP address used for rough regional estimates."
          color: root.barForeground; opacity: 0.55; font.family: Style.font.family
          font.pixelSize: Style.font.caption; wrapMode: Text.WordWrap; Layout.fillWidth: true
        }

        PanelSectionHeader { visible: root.currentView === "protection"; text: "PRIVACY PRESETS"; foreground: root.barForeground }
        RowLayout {
          visible: root.currentView === "protection"
          Layout.fillWidth: true
          spacing: Style.space(6)
          Button { text: "Normal"; enabled: !root.actionBusy; onClicked: root.requestPreset("normal") }
          Button { text: "Meeting"; enabled: !root.actionBusy; onClicked: root.requestPreset("meeting") }
          Button { text: "Private"; enabled: !root.actionBusy; onClicked: root.requestPreset("private") }
          Button { text: "Lockdown"; enabled: !root.actionBusy; onClicked: root.requestPreset("lockdown") }
        }
        Text {
          visible: root.currentView === "protection"
          text: "Meeting silences notifications · Private blocks location + webcam · Lockdown also mutes the microphone"
          color: root.barForeground; opacity: 0.5; font.family: Style.font.family
          font.pixelSize: Style.font.caption; wrapMode: Text.WordWrap; Layout.fillWidth: true
        }
        Button {
          visible: root.currentView === "protection"
          text: "App rules"
          onClicked: root.openAppRules("microphone")
        }
        Button {
          visible: root.currentView === "protection"
          text: "Location controls"
          onClicked: root.currentView = "location"
        }

        PanelSectionHeader { visible: root.currentView === "protection"; text: "BROWSER HEALTH"; foreground: root.barForeground }
        Text {
          visible: root.currentView === "protection"
          text: "Browsers use their own geolocation providers. Turning off system location does not block browser geolocation, and blocking precise geolocation cannot prevent rough IP-based estimates."
          color: root.barForeground; opacity: 0.55; font.family: Style.font.family
          font.pixelSize: Style.font.caption; wrapMode: Text.WordWrap; Layout.fillWidth: true
        }
        Text {
          visible: root.currentView === "protection" && root.browserHealth.length === 0
          text: "No supported browser profiles were found."
          color: root.barForeground; opacity: 0.6; font.family: Style.font.family
          font.pixelSize: Style.font.body; Layout.fillWidth: true
        }
        Repeater {
          model: root.browserHealth
          Text {
            required property var modelData
            visible: root.currentView === "protection"
            text: modelData.browser + " · Location: " + root.healthLabel(modelData.location)
              + " · Webcam: " + root.healthLabel(modelData.camera)
            color: root.barForeground; opacity: 0.7; font.family: Style.font.family
            font.pixelSize: Style.font.caption; wrapMode: Text.WordWrap; Layout.fillWidth: true
          }
        }

        PanelSectionHeader { visible: root.currentView === "protection"; text: "PRIVACY CHECK"; foreground: root.barForeground }
        RowLayout {
          visible: root.currentView === "protection"
          Layout.fillWidth: true
          Button { text: "Check exposure"; enabled: !root.actionBusy; onClicked: root.runAction(["leak-check"]) }
          Text {
            Layout.fillWidth: true
            text: root.leakResult
              ? "Public IP: " + root.leakResult.publicIp + " · DNS: " + (root.leakResult.dns || []).join(", ")
              : "Checks public IP and configured DNS; WebRTC requires a browser test."
            color: root.barForeground; opacity: 0.6; font.family: Style.font.family
            font.pixelSize: Style.font.caption; wrapMode: Text.WordWrap
          }
        }

        PanelSectionHeader { visible: root.currentView === "protection"; text: "AUTOMATION & ALERTS"; foreground: root.barForeground }
        RowLayout {
          visible: root.currentView === "protection"
          Layout.fillWidth: true
          Text { text: "Capture alerts"; color: root.barForeground; font.family: Style.font.family; Layout.fillWidth: true }
          ToggleSwitch {
            checked: root.automation.captureAlerts === true; busy: root.actionBusy; foreground: root.barForeground
            onToggled: root.runAction(["configure", "captureAlerts", checked ? "on" : "off"])
          }
        }
        RowLayout {
          visible: root.currentView === "protection"
          Layout.fillWidth: true
          Text { text: "Lockdown when session locks"; color: root.barForeground; font.family: Style.font.family; Layout.fillWidth: true }
          ToggleSwitch {
            checked: root.automation.autoLock === true; busy: root.actionBusy; foreground: root.barForeground
            onToggled: root.runAction(["configure", "autoLock", checked ? "on" : "off"])
          }
        }
        RowLayout {
          visible: root.currentView === "protection"
          Layout.fillWidth: true
          Text {
            text: "Lockdown on untrusted Wi-Fi" + (root.automation.currentWifi ? " · " + root.automation.currentWifi : "")
            color: root.barForeground; font.family: Style.font.family; Layout.fillWidth: true
          }
          ToggleSwitch {
            checked: root.automation.autoUntrustedWifi === true; busy: root.actionBusy; foreground: root.barForeground
            onToggled: root.runAction(["configure", "autoUntrustedWifi", checked ? "on" : "off"])
          }
        }
        RowLayout {
          visible: root.currentView === "protection"
          Layout.fillWidth: true
          Text {
            text: root.automation.trustedWifi && root.automation.trustedWifi.length
              ? "Trusted: " + root.automation.trustedWifi.join(", ") : "No trusted Wi-Fi saved"
            color: root.barForeground; opacity: 0.55; font.family: Style.font.family
            font.pixelSize: Style.font.caption; elide: Text.ElideRight; Layout.fillWidth: true
          }
          Button {
            text: "Trust current"; enabled: !root.actionBusy && !!root.automation.currentWifi
            onClicked: root.runAction(["trust-current-wifi"])
          }
        }

        Text {
          visible: root.actionError !== ""
          text: root.actionError
          color: Color.urgent
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
          Layout.fillWidth: true
        }
        Text {
          visible: root.scanError !== ""
          text: root.scanError
          color: Color.urgent
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
          Layout.fillWidth: true
        }

        PanelSectionHeader { visible: root.currentView === "permissions"; text: "BROWSER SITE PERMISSIONS"; foreground: root.barForeground }
        RowLayout {
          visible: root.currentView === "permissions"
          Layout.fillWidth: true
          Text {
            text: "Saved decisions: " + root.browserPermissions.length
            color: root.barForeground; opacity: 0.55; font.family: Style.font.family; Layout.fillWidth: true
          }
          Button { text: "Revoke all"; enabled: !root.actionBusy && root.browserPermissions.length > 0; onClicked: root.requestCleanup() }
        }
        Text {
          visible: root.currentView === "permissions" && root.browserPermissionError !== ""
          text: root.browserPermissionError
          color: root.barForeground
          opacity: 0.65
          font.family: Style.font.family
          font.pixelSize: Style.font.body
          wrapMode: Text.WordWrap
          Layout.fillWidth: true
        }
        Text {
          visible: root.currentView === "permissions" && root.hasScanned && root.browserPermissionError === ""
            && root.browserPermissions.length === 0
          text: "No saved browser decisions were found. One-time grants (including Zen's current-session location access) stay in browser memory and cannot be read from the profile database."
          color: root.barForeground
          opacity: 0.65
          font.family: Style.font.family
          font.pixelSize: Style.font.body
          wrapMode: Text.WordWrap
          Layout.fillWidth: true
        }
        Text {
          visible: root.currentView === "permissions" && root.browserProfiles.length > 0
          text: "Profiles scanned: " + root.browserProfiles.join(", ")
            + ". Saved decisions update here automatically; one-time grants do not."
          color: root.barForeground
          opacity: 0.45
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
          Layout.fillWidth: true
        }
        Repeater {
          model: root.browserPermissions
          Rectangle {
            required property var modelData
            visible: root.currentView === "permissions"
            Layout.fillWidth: true
            implicitHeight: browserPermissionRow.implicitHeight + Style.space(14)
            radius: Style.cornerRadius
            color: Style.selectedFillFor(root.barForeground, Color.accent)
            RowLayout {
              id: browserPermissionRow
              anchors.left: parent.left; anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter; anchors.margins: Style.space(7)
              spacing: Style.space(8)
              ColumnLayout {
                Layout.fillWidth: true; spacing: 0
                Text {
                  text: parent.parent.parent.modelData.origin
                  color: root.barForeground
                  font.family: Style.font.family
                  font.pixelSize: Style.font.body
                  font.bold: true
                  elide: Text.ElideRight
                  Layout.fillWidth: true
                }
                Text {
                  text: parent.parent.parent.modelData.browser + " · "
                    + parent.parent.parent.modelData.kind + " · "
                    + parent.parent.parent.modelData.decision
                  color: root.barForeground
                  opacity: 0.55
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                  elide: Text.ElideRight
                  Layout.fillWidth: true
                }
              }
              Button {
                text: "Revoke"
                enabled: !root.actionBusy
                onClicked: root.requestBrowserRevoke(parent.parent.modelData)
              }
            }
          }
        }

        PanelSectionHeader { visible: root.currentView === "overview"; text: "ACTIVE CAPTURE"; foreground: root.barForeground }
        Text {
          visible: root.currentView === "overview" && root.captures.length === 0
          text: "Nothing is using a running PipeWire capture stream."
          color: root.barForeground
          opacity: 0.65
          font.family: Style.font.family
          font.pixelSize: Style.font.body
          Layout.fillWidth: true
        }
        Repeater {
          model: root.captures
          Rectangle {
            required property var modelData
            visible: root.currentView === "overview"
            Layout.fillWidth: true
            implicitHeight: captureRow.implicitHeight + Style.space(14)
            radius: Style.cornerRadius
            color: Style.selectedFillFor(root.barForeground, Color.accent)
            RowLayout {
              id: captureRow
              anchors.left: parent.left; anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter; anchors.margins: Style.space(7)
              spacing: Style.space(10)
              Text {
                text: root.kindLabel(parent.parent.modelData.kind)
                color: Color.accent
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                font.bold: true
              }
              ColumnLayout {
                Layout.fillWidth: true; spacing: 0
                Text {
                  text: parent.parent.parent.modelData.app
                  color: root.barForeground
                  font.family: Style.font.family
                  font.pixelSize: Style.font.body
                  font.bold: true
                  elide: Text.ElideRight
                  Layout.fillWidth: true
                }
                Text {
                  text: root.kindName(parent.parent.parent.modelData.kind)
                    + (parent.parent.parent.modelData.detail ? " · " + parent.parent.parent.modelData.detail : "")
                  color: root.barForeground
                  opacity: 0.55
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                  elide: Text.ElideRight
                  Layout.fillWidth: true
                }
              }
            }
          }
        }

        PanelSectionHeader { visible: root.currentView === "permissions"; text: "DESKTOP PERMISSIONS"; foreground: root.barForeground }
        Text {
          visible: false
        }
        Text {
          visible: root.currentView === "permissions" && root.permissionError !== ""
          text: root.permissionError
          color: root.barForeground
          opacity: 0.65
          font.family: Style.font.family
          font.pixelSize: Style.font.body
          wrapMode: Text.WordWrap
          Layout.fillWidth: true
        }
        Text {
          visible: root.currentView === "permissions" && root.hasScanned
            && root.permissionError === "" && root.permissions.length === 0
          text: "The XDG permission store is available, but contains no saved decisions yet. Permissions appear after a portal-based application asks for access."
          color: root.barForeground
          opacity: 0.65
          font.family: Style.font.family
          font.pixelSize: Style.font.body
          wrapMode: Text.WordWrap
          Layout.fillWidth: true
        }
        Repeater {
          model: root.permissions
          Rectangle {
            required property var modelData
            visible: root.currentView === "permissions"
            Layout.fillWidth: true
            implicitHeight: permissionRow.implicitHeight + Style.space(14)
            radius: Style.cornerRadius
            color: Style.selectedFillFor(root.barForeground, Color.accent)
            RowLayout {
              id: permissionRow
              anchors.left: parent.left; anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter; anchors.margins: Style.space(7)
              spacing: Style.space(8)
              ColumnLayout {
                Layout.fillWidth: true; spacing: 0
                Text {
                  text: parent.parent.parent.modelData.app
                  color: root.barForeground
                  font.family: Style.font.family
                  font.pixelSize: Style.font.body
                  font.bold: true
                  elide: Text.ElideRight
                  Layout.fillWidth: true
                }
                Text {
                  text: parent.parent.parent.modelData.table + " · "
                    + parent.parent.parent.modelData.object + " · "
                    + parent.parent.parent.modelData.permissions.join(", ")
                  color: root.barForeground
                  opacity: 0.55
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                  elide: Text.ElideRight
                  Layout.fillWidth: true
                }
              }
              Button {
                text: "Revoke"
                enabled: !root.actionBusy
                onClicked: root.requestRevoke(parent.parent.modelData)
              }
            }
          }
        }

        PanelSectionHeader { visible: root.currentView === "activity"; text: "PRIVACY TIMELINE · 7 DAYS"; foreground: root.barForeground }
        RowLayout {
          visible: root.currentView === "activity"
          Layout.fillWidth: true
          Button { text: "All"; enabled: root.activityFilter !== "all"; onClicked: root.activityFilter = "all" }
          Button { text: "Captures"; enabled: root.activityFilter !== "capture"; onClicked: root.activityFilter = "capture" }
          Button { text: "Changes"; enabled: root.activityFilter !== "changes"; onClicked: root.activityFilter = "changes" }
        }
        Text {
          visible: root.currentView === "activity" && root.historyRows.length === 0
          text: "No privacy activity has been recorded yet."
          color: root.barForeground
          opacity: 0.65
          font.family: Style.font.family
          font.pixelSize: Style.font.body
          Layout.fillWidth: true
        }
        Repeater {
          model: root.filteredHistory.slice(0, 20)
          RowLayout {
            required property var modelData
            visible: root.currentView === "activity"
            Layout.fillWidth: true
            spacing: Style.space(8)
            Text {
              text: parent.modelData.event === "started" ? "+" : (parent.modelData.event === "stopped" ? "−" : "•")
              color: parent.modelData.event === "started" ? Color.accent : root.barForeground
              opacity: parent.modelData.event === "started" ? 1 : 0.5
              font.family: Style.font.family
              font.pixelSize: Style.font.body
              font.bold: true
            }
            Text {
              text: parent.modelData.app + " · " + parent.modelData.event
                + (parent.modelData.detail ? " · " + parent.modelData.detail : "")
              color: root.barForeground
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
              Layout.fillWidth: true
            }
            Text {
              text: Qt.formatDateTime(new Date(parent.modelData.time), "MMM d HH:mm")
              color: root.barForeground
              opacity: 0.45
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }
          }
        }

        PanelSeparator { Layout.fillWidth: true; foreground: root.barForeground }
        Text {
          text: "Local data only · R refreshes · Esc closes"
          color: root.barForeground
          opacity: 0.45
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          horizontalAlignment: Text.AlignHCenter
          Layout.fillWidth: true
        }
      }
    }

    ConfirmDialog {
      id: confirm
      anchors.fill: parent
      z: 20
      foreground: root.barForeground
      onCanceled: {
        opened = false
        root.pendingAction = ""
        root.pendingPermission = null
      }
      onConfirmed: root.runConfirmedAction()
    }
  }
}
