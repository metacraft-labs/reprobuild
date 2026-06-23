// M9.R.18.4 -- top-level wizard chrome. Per ReproOS-Installer-PRD.md
// Sec 3.1 the wizard is an 8-screen StackView with a persistent
// progress header + Back / Next buttons. This file owns:
//   * The ApplicationWindow + colour palette
//   * The progress strip (1 of 8 ... 8 of 8)
//   * The StackView the per-screen .qml files push/pop
//   * The Back / Next bar at the bottom

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

import "screens" as Screens

ApplicationWindow {
    id: window
    visible: true
    width: 960
    height: 720
    minimumWidth: 720
    minimumHeight: 540
    title: qsTr("ReproOS Installer")

    // PRD Sec 3.1 doesn't pin a colour scheme; this is the M9.R.18 v0.1
    // placeholder. M9.R.19 polish replaces with proper Material 3 dark
    // tokens.
    palette.window: "#1a1a22"
    palette.windowText: "#e6e6f0"
    palette.button: "#2c2c3a"
    palette.buttonText: "#e6e6f0"
    palette.highlight: "#5a82c8"
    palette.highlightedText: "#ffffff"
    palette.text: "#e6e6f0"
    palette.base: "#0f0f17"

    // Screen names in display order. Each entry maps to a file under
    // qml/screens/. The StackView is initialised with the first; Back /
    // Next push or pop the rest as the user navigates.
    // M9.R.23.1 -- ten-screen flow (was nine). Disk inserts at position 5
    // between Users and DeSelect: PRD Sec 3.1 lists target-disk + layout
    // preset as a top-level wizard step, but M9.R.18.4 v0.1 stubbed it
    // out. M9.R.23 wires the screen + the underlying install() driver.
    readonly property var screens: [
        { id: "welcome",     file: "Welcome.qml",     title: qsTr("Welcome") },
        { id: "locale",      file: "Locale.qml",      title: qsTr("Language and Timezone") },
        { id: "keyboard",    file: "Keyboard.qml",    title: qsTr("Keyboard Layout") },
        { id: "users",       file: "Users.qml",       title: qsTr("User Account") },
        { id: "disk",        file: "Disk.qml",        title: qsTr("Target Disk") },
        { id: "deSelect",    file: "DeSelect.qml",    title: qsTr("Desktop Environment") },
        { id: "activities",  file: "Activities.qml",  title: qsTr("Activities") },
        { id: "summary",     file: "Summary.qml",     title: qsTr("Review") },
        { id: "install",     file: "Install.qml",     title: qsTr("Install") },
        { id: "finished",    file: "Finished.qml",    title: qsTr("Finished") },
    ]

    // 0-based index into screens[]; drives the StackView depth + the
    // progress header text.
    property int currentScreenIndex: 0

    function gotoScreenIndex(idx) {
        if (idx < 0 || idx >= screens.length) return;
        currentScreenIndex = idx;
        stack.clear();
        stack.push(Qt.resolvedUrl("screens/" + screens[idx].file));
    }

    function nextScreen() {
        if (currentScreenIndex < screens.length - 1) {
            gotoScreenIndex(currentScreenIndex + 1);
        }
    }

    function prevScreen() {
        if (currentScreenIndex > 0) {
            gotoScreenIndex(currentScreenIndex - 1);
        }
    }

    Component.onCompleted: gotoScreenIndex(0)

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        // Header: title + progress.
        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 64
            color: "#13131c"

            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: 24
                anchors.rightMargin: 24
                spacing: 12

                Label {
                    text: window.screens[window.currentScreenIndex].title
                    color: "#e6e6f0"
                    font.pixelSize: 22
                    font.weight: Font.Medium
                    Layout.fillWidth: true
                }

                Label {
                    text: qsTr("Step %1 of %2")
                        .arg(window.currentScreenIndex + 1)
                        .arg(window.screens.length)
                    color: "#8a8aa3"
                    font.pixelSize: 14
                }
            }
        }

        // Progress strip.
        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 4
            color: "#0a0a14"
            Rectangle {
                anchors.left: parent.left
                anchors.top: parent.top
                anchors.bottom: parent.bottom
                width: parent.width * (window.currentScreenIndex + 1) / window.screens.length
                color: "#5a82c8"
                Behavior on width { NumberAnimation { duration: 200 } }
            }
        }

        // Per-screen content.
        StackView {
            id: stack
            Layout.fillWidth: true
            Layout.fillHeight: true
        }

        // Footer: Back / Next.
        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 72
            color: "#13131c"

            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: 24
                anchors.rightMargin: 24
                spacing: 12

                Button {
                    text: qsTr("Back")
                    enabled: window.currentScreenIndex > 0
                        && window.currentScreenIndex < window.screens.length - 2
                    onClicked: window.prevScreen()
                }

                Item { Layout.fillWidth: true }

                Button {
                    text: window.currentScreenIndex === window.screens.length - 3
                        ? qsTr("Install")
                        : window.currentScreenIndex === window.screens.length - 1
                            ? qsTr("Reboot")
                            : qsTr("Next")
                    highlighted: true
                    enabled: window.currentScreenIndex < window.screens.length - 1
                        || window.currentScreenIndex === window.screens.length - 1
                    onClicked: {
                        if (window.currentScreenIndex === window.screens.length - 1) {
                            Qt.quit();
                        } else {
                            window.nextScreen();
                        }
                    }
                }
            }
        }
    }
}
