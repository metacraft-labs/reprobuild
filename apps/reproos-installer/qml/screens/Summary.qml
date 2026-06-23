// M9.R.18.11 -- Summary screen. Per ReproOS-Installer-PRD.md Sec 3.1
// screen 9 + Sec 7.2 step 7 the wizard renders the synthesised
// system.nim text for the user to review before any destructive action.
// This is the transparency feature -- the user sees the exact bytes
// that will land at /etc/repro/system.nim.
//
// The preview text comes from installerState.renderSystemNim() (C++
// side; reactive on every property change so toggling a checkbox in
// Activities updates the preview when the user navigates back here).

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

Item {
    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 32
        spacing: 12

        Label {
            text: qsTr("Review your configuration")
            font.pixelSize: 18
            color: "#e6e6f0"
        }

        Label {
            text: qsTr("Below is the system.nim that will be written to /etc/repro/system.nim. Click Install to commit; click Back to revise.")
            font.pixelSize: 13
            color: "#8a8aa3"
            wrapMode: Text.WordWrap
            Layout.fillWidth: true
        }

        Rectangle {
            Layout.fillWidth: true
            Layout.fillHeight: true
            Layout.topMargin: 8
            color: "#0a0a14"
            border.color: "#2c2c3a"
            border.width: 1
            radius: 4

            ScrollView {
                anchors.fill: parent
                anchors.margins: 12
                clip: true

                TextArea {
                    id: previewArea
                    readOnly: true
                    selectByMouse: true
                    color: "#d0d0e0"
                    font.family: "monospace"
                    font.pixelSize: 12
                    background: null

                    // Re-render whenever the user revisits this screen. The
                    // C++ renderSystemNim() reads the current InstallerState
                    // properties; the binding refreshes on every navigation.
                    text: installerState.renderSystemNim()

                    // Connect to every property-changed signal so live edits
                    // (e.g. switching back to Locale and changing timezone)
                    // refresh this view when the user returns.
                    Connections {
                        target: installerState
                        function onHostnameChanged() { previewArea.text = installerState.renderSystemNim() }
                        function onLocaleChanged() { previewArea.text = installerState.renderSystemNim() }
                        function onTimezoneChanged() { previewArea.text = installerState.renderSystemNim() }
                        function onKeymapChanged() { previewArea.text = installerState.renderSystemNim() }
                        function onUsernameChanged() { previewArea.text = installerState.renderSystemNim() }
                        function onFullNameChanged() { previewArea.text = installerState.renderSystemNim() }
                        function onIsAdminChanged() { previewArea.text = installerState.renderSystemNim() }
                        function onDesktopKindChanged() { previewArea.text = installerState.renderSystemNim() }
                        function onActiveActivitiesChanged() { previewArea.text = installerState.renderSystemNim() }
                    }
                }
            }
        }

        Label {
            text: qsTr("The companion hardware.nim is auto-generated from `repro hardware probe` at install time.")
            font.pixelSize: 11
            color: "#6a6a83"
            wrapMode: Text.WordWrap
            Layout.fillWidth: true
        }
    }
}
