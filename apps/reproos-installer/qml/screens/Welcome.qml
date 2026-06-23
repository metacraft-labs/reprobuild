// M9.R.18.5 -- Welcome screen. Per ReproOS-Installer-PRD.md Sec 3.1 the
// first wizard screen orients the user + surfaces the three quick-path
// alternatives (PRD Sec 5: USB stick / git URL / managed-service).
// v0.1 ships the Standard Configuration path button + a stub "Restore
// from existing config (coming soon)" affordance for the quick paths;
// M9.R.19 wires the actual USB + git URL flow.

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

Item {
    ColumnLayout {
        anchors.centerIn: parent
        spacing: 24
        width: 600

        Label {
            text: qsTr("Welcome to ReproOS")
            font.pixelSize: 36
            font.weight: Font.Light
            color: "#e6e6f0"
            Layout.alignment: Qt.AlignHCenter
        }

        Label {
            text: qsTr(
                "A reproducible operating system built on the reprobuild engine. "
                + "This installer will gather a few choices and write your machine's "
                + "system.nim + hardware.nim configuration before invoking the "
                + "standard apply pipeline.")
            wrapMode: Text.WordWrap
            font.pixelSize: 15
            color: "#b8b8d0"
            horizontalAlignment: Text.AlignHCenter
            Layout.fillWidth: true
        }

        Label {
            text: qsTr(
                "Click Next to begin with the Standard Configuration path. "
                + "The wizard takes about 10 minutes; you can move back and forth "
                + "between screens until the final Install step.")
            wrapMode: Text.WordWrap
            font.pixelSize: 13
            color: "#8a8aa3"
            horizontalAlignment: Text.AlignHCenter
            Layout.fillWidth: true
            Layout.topMargin: 8
        }

        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 1
            color: "#2c2c3a"
            Layout.topMargin: 16
            Layout.bottomMargin: 16
        }

        Label {
            text: qsTr("Have an existing system.nim configuration?")
            font.pixelSize: 14
            font.weight: Font.Medium
            color: "#e6e6f0"
            Layout.alignment: Qt.AlignHCenter
        }

        RowLayout {
            spacing: 16
            Layout.alignment: Qt.AlignHCenter

            Button {
                text: qsTr("Restore from USB stick")
                enabled: false
                ToolTip.text: qsTr("Coming in M9.R.19")
                ToolTip.visible: hovered
                ToolTip.delay: 600
            }

            Button {
                text: qsTr("Restore from git URL")
                enabled: false
                ToolTip.text: qsTr("Coming in M9.R.19")
                ToolTip.visible: hovered
                ToolTip.delay: 600
            }
        }
    }
}
