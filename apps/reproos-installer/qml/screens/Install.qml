// M9.R.18.12 -- Install screen. Per ReproOS-Installer-PRD.md Sec 3.1
// screen 9 + Sec 7.2 step 8 the wizard shells out to the actual
// install pipeline (`repro disk apply` -> `repro disk mount` -> file
// writes -> `repro infra apply --target /mnt`).
//
// M9.R.23.3 wires the screen to InstallerState.install() which drives
// the actual sequence via QProcess wrappers. The Stub button is gone;
// the screen is now bound to the install* properties + the
// installLogChanged signal updates the live log.

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

Item {
    id: installScreen

    Connections {
        target: installerState
        function onInstallLogChanged() {
            logArea.text = installerState.installLog;
            // Keep the log area scrolled to the bottom.
            logArea.cursorPosition = logArea.length;
        }
        function onInstallComplete() {
            // Surface the completion + let the user advance to the
            // Finished screen. main.qml's Next button enables once the
            // installRunning flag drops to false.
        }
        function onInstallFailed(reason) {
            // The reason already lands in the installLog via the C++
            // appendLog() call; no separate dialog needed.
        }
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 32
        spacing: 14

        Label {
            text: qsTr("Installing ReproOS")
            font.pixelSize: 18
            color: "#e6e6f0"
        }

        Label {
            text: installerState.installStatus
            font.pixelSize: 14
            color: "#b8b8d0"
            wrapMode: Text.WordWrap
            Layout.fillWidth: true
        }

        ProgressBar {
            Layout.fillWidth: true
            value: installerState.installProgress
            indeterminate: installerState.installRunning
                && installerState.installProgress < 0.05
        }

        Button {
            text: installerState.installRunning ? qsTr("Installing...")
                  : installerState.installProgress >= 1.0 ? qsTr("Done")
                  : qsTr("Start install")
            enabled: !installerState.installRunning
                && installerState.installProgress < 1.0
            highlighted: enabled
            onClicked: installerState.install()
        }

        Label {
            text: qsTr("Install log:")
            font.pixelSize: 13
            color: "#8a8aa3"
            Layout.topMargin: 12
        }

        Rectangle {
            Layout.fillWidth: true
            Layout.fillHeight: true
            color: "#0a0a14"
            border.color: "#2c2c3a"
            border.width: 1
            radius: 4

            ScrollView {
                anchors.fill: parent
                anchors.margins: 8
                clip: true

                TextArea {
                    id: logArea
                    readOnly: true
                    selectByMouse: true
                    color: "#a0d0a0"
                    font.family: "monospace"
                    font.pixelSize: 11
                    background: null
                    text: installerState.installLog
                    wrapMode: TextEdit.Wrap
                }
            }
        }
    }
}
