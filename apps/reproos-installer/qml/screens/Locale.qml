// M9.R.18.6 -- Locale screen. Per ReproOS-Installer-PRD.md Sec 3.1
// screen 3 the user picks timezone (IANA name) + locale (en_US.UTF-8
// shape). v0.1 ships a curated subset; M9.R.19 broadens it via the
// /usr/share/reproos-installer/locale-data.toml the PRD Sec 7.2 step 3
// pins.

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

Item {
    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 32
        spacing: 18

        Label {
            text: qsTr("Pick your language and timezone")
            font.pixelSize: 18
            color: "#e6e6f0"
        }

        Label {
            text: qsTr("These choices land in system.nim and are activated by `repro infra apply` at first boot.")
            font.pixelSize: 13
            color: "#8a8aa3"
            wrapMode: Text.WordWrap
            Layout.fillWidth: true
        }

        GridLayout {
            columns: 2
            rowSpacing: 14
            columnSpacing: 16
            Layout.topMargin: 16

            Label { text: qsTr("System locale:"); color: "#e6e6f0"; font.pixelSize: 14 }
            ComboBox {
                id: localeCombo
                Layout.preferredWidth: 280
                model: [
                    "en_US.UTF-8",
                    "en_GB.UTF-8",
                    "de_DE.UTF-8",
                    "fr_FR.UTF-8",
                    "es_ES.UTF-8",
                    "it_IT.UTF-8",
                    "pt_BR.UTF-8",
                    "ja_JP.UTF-8",
                    "zh_CN.UTF-8",
                    "bg_BG.UTF-8",
                ]
                Component.onCompleted: {
                    var idx = model.indexOf(installerState.locale);
                    if (idx >= 0) currentIndex = idx;
                }
                onCurrentTextChanged: installerState.locale = currentText
            }

            Label { text: qsTr("Timezone:"); color: "#e6e6f0"; font.pixelSize: 14 }
            ComboBox {
                id: tzCombo
                Layout.preferredWidth: 280
                model: [
                    "Europe/Sofia",
                    "Europe/Berlin",
                    "Europe/London",
                    "Europe/Paris",
                    "Europe/Madrid",
                    "America/New_York",
                    "America/Los_Angeles",
                    "America/Chicago",
                    "Asia/Tokyo",
                    "Asia/Shanghai",
                    "Australia/Sydney",
                    "UTC",
                ]
                Component.onCompleted: {
                    var idx = model.indexOf(installerState.timezone);
                    if (idx >= 0) currentIndex = idx;
                }
                onCurrentTextChanged: installerState.timezone = currentText
            }

            Label { text: qsTr("Hostname:"); color: "#e6e6f0"; font.pixelSize: 14 }
            TextField {
                Layout.preferredWidth: 280
                text: installerState.hostname
                placeholderText: "reproos"
                onTextChanged: installerState.hostname = text
            }
        }

        Item { Layout.fillHeight: true }
    }
}
