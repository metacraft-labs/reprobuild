// M9.R.18.8 -- Users screen. Per ReproOS-Installer-PRD.md Sec 3.1
// screen 6 the user picks username + full name + password + "make this
// user admin". v0.1 ships the form; M9.R.19 wires it to the M82
// broker so the password lands in the secrets channel before destructive
// disk operations begin (per PRD Sec 7.3).

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

Item {
    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 32
        spacing: 18

        Label {
            text: qsTr("Create your user account")
            font.pixelSize: 18
            color: "#e6e6f0"
        }

        Label {
            text: qsTr("The wizard creates one user account on the target system. You can add more users later via system.nim.")
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

            Label { text: qsTr("Full name:"); color: "#e6e6f0"; font.pixelSize: 14 }
            TextField {
                Layout.preferredWidth: 320
                text: installerState.fullName
                placeholderText: qsTr("Alice Example")
                onTextChanged: installerState.fullName = text
            }

            Label { text: qsTr("Username:"); color: "#e6e6f0"; font.pixelSize: 14 }
            TextField {
                Layout.preferredWidth: 320
                text: installerState.username
                placeholderText: qsTr("alice")
                validator: RegularExpressionValidator {
                    regularExpression: /^[a-z][a-z0-9_-]*$/
                }
                onTextChanged: installerState.username = text
            }

            Label { text: qsTr("Password:"); color: "#e6e6f0"; font.pixelSize: 14 }
            TextField {
                Layout.preferredWidth: 320
                echoMode: TextInput.Password
                text: installerState.password
                placeholderText: qsTr("Choose a password")
                onTextChanged: installerState.password = text
            }

            Label { text: qsTr("Confirm:"); color: "#e6e6f0"; font.pixelSize: 14 }
            TextField {
                id: confirmField
                Layout.preferredWidth: 320
                echoMode: TextInput.Password
                placeholderText: qsTr("Type the password again")
            }

            Label { text: ""; }
            CheckBox {
                checked: installerState.isAdmin
                text: qsTr("This user is the system administrator (add to wheel group)")
                onToggled: installerState.isAdmin = checked
            }
        }

        Label {
            Layout.topMargin: 12
            visible: confirmField.text.length > 0 && confirmField.text !== installerState.password
            text: qsTr("Passwords do not match.")
            color: "#e85050"
            font.pixelSize: 13
        }

        Item { Layout.fillHeight: true }
    }
}
