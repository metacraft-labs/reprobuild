// M9.R.18.12 -- Install screen. Per ReproOS-Installer-PRD.md Sec 3.1
// screen 10 + Sec 7.2 step 8 the wizard shells out to the actual
// install pipeline (`repro disk apply` -> `repro disk mount` -> file
// writes -> `repro infra apply --target /mnt`).
//
// v0.1 stubs the destructive pipeline: the screen runs `echo` and
// reports success. M9.R.19 wires it to the M82 broker per PRD Sec 7.3.

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

Item {
    property real installProgress: 0.0
    property string installStatus: qsTr("Ready to install")
    property bool installRunning: false
    property bool installFinished: false
    property bool installFailed: false
    property string installLog: ""

    Timer {
        id: stubTimer
        interval: 250
        repeat: true
        onTriggered: {
            installProgress += 0.04;
            if (installProgress >= 1.0) {
                installProgress = 1.0;
                installRunning = false;
                installFinished = true;
                installStatus = qsTr("Install completed (M9.R.19 will wire the real apply).");
                appendLog("[done] stub install pipeline completed");
                stop();
            } else {
                var step = Math.floor(installProgress * 8);
                var labels = [
                    qsTr("Probing target hardware..."),
                    qsTr("Planning disk layout..."),
                    qsTr("Applying disk layout..."),
                    qsTr("Mounting target rootfs at /mnt..."),
                    qsTr("Writing /mnt/etc/repro/system.nim..."),
                    qsTr("Copying activity modules..."),
                    qsTr("Running repro infra apply --target /mnt..."),
                    qsTr("Finalising bootloader install...")
                ];
                if (step < labels.length) {
                    installStatus = labels[step];
                    appendLog("[" + step + "] " + labels[step]);
                }
            }
        }
    }

    function appendLog(line) {
        installLog += line + "\n";
        logArea.text = installLog;
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
            text: installStatus
            font.pixelSize: 14
            color: "#b8b8d0"
            wrapMode: Text.WordWrap
            Layout.fillWidth: true
        }

        ProgressBar {
            Layout.fillWidth: true
            value: installProgress
            indeterminate: installRunning && installProgress < 0.05
        }

        Button {
            text: installRunning ? qsTr("Installing...")
                  : installFinished ? qsTr("Done")
                  : qsTr("Start install (stub)")
            enabled: !installRunning && !installFinished
            highlighted: !installRunning && !installFinished
            onClicked: {
                installRunning = true;
                installProgress = 0.0;
                installLog = "";
                appendLog("# ReproOS installer stub log");
                appendLog("# M9.R.18.12 -- the real apply lands in M9.R.19");
                appendLog("");
                stubTimer.start();
            }
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
                    text: ""
                }
            }
        }
    }
}
