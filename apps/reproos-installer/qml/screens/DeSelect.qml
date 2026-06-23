// M9.R.18.9 -- DE-select screen. Per ReproOS-Installer-PRD.md Sec 3.1
// screen 7 the user picks a single desktop environment. PRD Sec 9 Q5
// recommends single-select for v1; multi-DE is a v2 advanced toggle.
//
// The four cards mirror the from-source-recipe coverage already
// shipping in the live ISO (M9.R.16/17): KDE Plasma + GNOME + Sway,
// plus Hyprland which the multi-de grub.cfg already pre-selects as
// the default cmdline entry.

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

Item {
    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 32
        spacing: 18

        Label {
            text: qsTr("Choose your desktop environment")
            font.pixelSize: 18
            color: "#e6e6f0"
        }

        Label {
            text: qsTr("ReproOS supports all four out of the box. You can switch DEs post-install by editing system.nim.")
            font.pixelSize: 13
            color: "#8a8aa3"
            wrapMode: Text.WordWrap
            Layout.fillWidth: true
        }

        GridLayout {
            columns: 2
            rowSpacing: 16
            columnSpacing: 16
            Layout.topMargin: 16
            Layout.fillWidth: true

            DeCard {
                Layout.fillWidth: true
                Layout.preferredHeight: 140
                cardId: "plasma"
                title: qsTr("KDE Plasma")
                description: qsTr("Feature-rich Qt-based desktop. Familiar to Windows/macOS users; SDDM greeter.")
                selected: installerState.desktopKind === "plasma"
                onClicked: installerState.desktopKind = "plasma"
            }

            DeCard {
                Layout.fillWidth: true
                Layout.preferredHeight: 140
                cardId: "gnome"
                title: qsTr("GNOME")
                description: qsTr("Workflow-focused GTK desktop. Touch-friendly; opinionated defaults; GDM greeter.")
                selected: installerState.desktopKind === "gnome"
                onClicked: installerState.desktopKind = "gnome"
            }

            DeCard {
                Layout.fillWidth: true
                Layout.preferredHeight: 140
                cardId: "sway"
                title: qsTr("Sway")
                description: qsTr("Tiling Wayland compositor; keyboard-driven; i3-compatible config. Minimal resource footprint.")
                selected: installerState.desktopKind === "sway"
                onClicked: installerState.desktopKind = "sway"
            }

            DeCard {
                Layout.fillWidth: true
                Layout.preferredHeight: 140
                cardId: "hyprland"
                title: qsTr("Hyprland")
                description: qsTr("Dynamic tiling Wayland compositor; eye-candy + animations; power-user audience.")
                selected: installerState.desktopKind === "hyprland"
                onClicked: installerState.desktopKind = "hyprland"
            }
        }

        Item { Layout.fillHeight: true }
    }

    // Inline component for the four DE cards. Each is a clickable rect
    // with title + description; the selected one gets a coloured border.
    component DeCard : Rectangle {
        id: card
        property string cardId
        property string title
        property string description
        property bool selected: false
        signal clicked()

        color: selected ? "#1c2840" : "#2c2c3a"
        border.color: selected ? "#5a82c8" : "#3c3c4a"
        border.width: 2
        radius: 6

        ColumnLayout {
            anchors.fill: parent
            anchors.margins: 16
            spacing: 6

            Label {
                text: card.title
                color: "#e6e6f0"
                font.pixelSize: 16
                font.weight: Font.Medium
            }

            Label {
                text: card.description
                color: "#b8b8d0"
                font.pixelSize: 12
                wrapMode: Text.WordWrap
                Layout.fillWidth: true
            }

            Item { Layout.fillHeight: true }
        }

        MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: card.clicked()
        }
    }
}
