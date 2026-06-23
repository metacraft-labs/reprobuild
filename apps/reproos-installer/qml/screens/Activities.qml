// M9.R.18.10 -- Activities screen. Per ReproOS-Installer-PRD.md Sec 3.1
// screen 8 + Sec 4.2 the user picks from a curated catalog of 12
// system-scope activities. v0.1 hardcodes the catalog inline; M9.R.19
// loads it from /usr/share/reproos-installer/activities.toml per
// PRD Sec 7.4.
//
// Daily Computing + System Tools are pre-checked per PRD Sec 4.2.

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

Item {
    // Inline catalog -- PRD Sec 4.2 inventory. The TOML loader replaces
    // this in M9.R.19; the IDs stay stable.
    readonly property var catalog: [
        { id: "daily-computing", name: qsTr("Daily Computing"),
          desc: qsTr("Browser, file manager, email, document viewer.") },
        { id: "system-tools", name: qsTr("System Tools"),
          desc: qsTr("Terminal, basic CLI utilities, text editor, system monitor.") },
        { id: "development", name: qsTr("Development"),
          desc: qsTr("Programming languages, dev tools, container engine.") },
        { id: "creative", name: qsTr("Creative"),
          desc: qsTr("Graphics, image editing, vector tools, audio/video production.") },
        { id: "gaming", name: qsTr("Gaming"),
          desc: qsTr("Game launchers, controllers, performance tooling.") },
        { id: "office", name: qsTr("Office"),
          desc: qsTr("Office suite, PIM, project management.") },
        { id: "media-consumption", name: qsTr("Media Consumption"),
          desc: qsTr("Video player, music player, podcast client.") },
        { id: "system-administration", name: qsTr("System Administration"),
          desc: qsTr("Sysadmin tooling, monitoring, networking, containers, dev VMs.") },
        { id: "privacy-security", name: qsTr("Privacy and Security"),
          desc: qsTr("Tor, VPN clients, password managers, secrets tooling.") },
        { id: "communication", name: qsTr("Communication"),
          desc: qsTr("Chat, video call, social.") },
        { id: "photography", name: qsTr("Photography"),
          desc: qsTr("RAW processing, library management, tethering.") },
        { id: "home-server", name: qsTr("Home Server"),
          desc: qsTr("Selfhost basics, container engine, reverse proxy, file sharing.") }
    ]

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 32
        spacing: 12

        Label {
            text: qsTr("Pick the activities you want enabled")
            font.pixelSize: 18
            color: "#e6e6f0"
        }

        Label {
            text: qsTr("Each activity ships a curated set of packages + services. You can author your own activities post-install by editing system.nim.")
            font.pixelSize: 13
            color: "#8a8aa3"
            wrapMode: Text.WordWrap
            Layout.fillWidth: true
        }

        ScrollView {
            Layout.fillWidth: true
            Layout.fillHeight: true
            Layout.topMargin: 12
            clip: true

            GridLayout {
                width: parent.availableWidth
                columns: 2
                rowSpacing: 8
                columnSpacing: 12

                Repeater {
                    model: catalog

                    delegate: Rectangle {
                        required property var modelData
                        Layout.fillWidth: true
                        Layout.preferredHeight: 64
                        color: installerState.hasActivity(modelData.id) ? "#1c2840" : "#22222e"
                        border.color: installerState.hasActivity(modelData.id) ? "#5a82c8" : "#3c3c4a"
                        border.width: 1
                        radius: 4

                        RowLayout {
                            anchors.fill: parent
                            anchors.margins: 12
                            spacing: 8

                            CheckBox {
                                checked: installerState.hasActivity(modelData.id)
                                onToggled: installerState.toggleActivity(modelData.id)
                            }

                            ColumnLayout {
                                spacing: 1
                                Layout.fillWidth: true
                                Label {
                                    text: modelData.name
                                    color: "#e6e6f0"
                                    font.pixelSize: 14
                                    font.weight: Font.Medium
                                }
                                Label {
                                    text: modelData.desc
                                    color: "#a0a0b8"
                                    font.pixelSize: 11
                                    wrapMode: Text.WordWrap
                                    Layout.fillWidth: true
                                }
                            }
                        }

                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: installerState.toggleActivity(modelData.id)
                        }
                    }
                }
            }
        }
    }
}
