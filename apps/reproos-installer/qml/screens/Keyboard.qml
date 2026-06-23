// M9.R.18.7 -- Keyboard screen. Per ReproOS-Installer-PRD.md Sec 3.1
// screen 2 the user picks a keymap. v0.1 ships a curated list; M9.R.19
// loads xkbcommon's full inventory via locale-data.toml.

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

Item {
    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 32
        spacing: 18

        Label {
            text: qsTr("Pick your keyboard layout")
            font.pixelSize: 18
            color: "#e6e6f0"
        }

        Label {
            text: qsTr("The keymap is applied both to the live session and to the installed system. Type into the test area below to confirm before continuing.")
            font.pixelSize: 13
            color: "#8a8aa3"
            wrapMode: Text.WordWrap
            Layout.fillWidth: true
        }

        RowLayout {
            Layout.topMargin: 16
            spacing: 16

            Label { text: qsTr("Layout:"); color: "#e6e6f0"; font.pixelSize: 14 }
            ComboBox {
                id: layoutCombo
                Layout.preferredWidth: 280
                model: [
                    { display: qsTr("English (US)"), code: "us" },
                    { display: qsTr("English (US, intl)"), code: "us-intl" },
                    { display: qsTr("English (UK)"), code: "gb" },
                    { display: qsTr("German (no deadkeys)"), code: "de-nodeadkeys" },
                    { display: qsTr("German"), code: "de" },
                    { display: qsTr("French (AZERTY)"), code: "fr" },
                    { display: qsTr("Spanish"), code: "es" },
                    { display: qsTr("Italian"), code: "it" },
                    { display: qsTr("Bulgarian (BDS)"), code: "bg" },
                    { display: qsTr("Russian"), code: "ru" },
                    { display: qsTr("Japanese"), code: "jp" },
                    { display: qsTr("Dvorak"), code: "us-dvorak" },
                    { display: qsTr("Colemak"), code: "us-colemak" },
                ]
                textRole: "display"
                Component.onCompleted: {
                    for (var i = 0; i < model.length; ++i) {
                        if (model[i].code === installerState.keymap) {
                            currentIndex = i;
                            return;
                        }
                    }
                }
                onCurrentIndexChanged: {
                    if (currentIndex >= 0) {
                        installerState.keymap = model[currentIndex].code;
                    }
                }
            }
        }

        Label {
            Layout.topMargin: 20
            text: qsTr("Test area:")
            font.pixelSize: 14
            color: "#e6e6f0"
        }

        TextField {
            Layout.fillWidth: true
            Layout.preferredHeight: 40
            placeholderText: qsTr("Type here to verify the keymap...")
        }

        Item { Layout.fillHeight: true }
    }
}
