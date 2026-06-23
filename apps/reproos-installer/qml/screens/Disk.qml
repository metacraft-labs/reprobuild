// M9.R.23.1 -- Disk screen. Per ReproOS-Installer-PRD.md Sec 3.1 step 5
// the user picks the target disk + a layout preset (simple ext4 /
// LUKS-btrfs / advanced). The choice produces a DiskoIntent on
// InstallerState that drives renderDiskoNim() + the install()
// orchestration the M9.R.23.3 step shells out via `repro disk apply`.
//
// Wire-up:
//   * "Refresh disks" button calls installerState.refreshAvailableDisks()
//     which shells out to `lsblk -d -o NAME,SIZE,MODEL,VENDOR` and
//     populates `availableDisks`.
//   * The combo box lets the user pick one entry. The string is the
//     full device path ("/dev/sda") so renderDiskoNim() can drop it
//     verbatim into the disko block.
//   * Three radios pick the preset:
//       - simple   -> GPT + ESP(vfat /boot) + ext4(/)
//       - encrypted -> GPT + ESP(vfat /boot) + LUKS2(btrfs /,@home,...)
//       - advanced -> the user hand-edits the disko block post-install
//   * Encrypted-only fields: passphrase + confirm. Both must match.
//   * "I understand all data will be destroyed" checkbox gates Next.
//
// PRD Sec 7.2 step 4-5 frames this as the disk-layout choice that
// precedes the destructive `repro disk apply`. The wizard does NOT
// expose mkfs/luksformat operations directly -- it stays at the
// disko-intent level + lets the engine drive the underlying tools
// (M9.R.22b's disk_apply.nim).

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

Item {
    id: diskScreen

    // Local helper -- pretty-print one lsblk row. The string format is
    // "/dev/sda  (476.9G, Samsung SSD 870 EVO)" so the combo box is
    // human-readable while still picking the canonical device path
    // via Component.onCompleted.
    function pickDevicePath(entry) {
        // entry shape: "sda 476.9G Samsung SSD_870_EVO Samsung"
        var parts = entry.trim().split(/\s+/);
        if (parts.length === 0) return "";
        return "/dev/" + parts[0];
    }

    function formatEntry(entry) {
        var parts = entry.trim().split(/\s+/);
        if (parts.length < 2) return entry;
        var dev = "/dev/" + parts[0];
        var size = parts[1];
        var rest = parts.slice(2).join(" ");
        return dev + "  (" + size + (rest.length > 0 ? ", " + rest : "") + ")";
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 32
        spacing: 16

        Label {
            text: qsTr("Choose your target disk")
            font.pixelSize: 18
            color: "#e6e6f0"
        }

        Label {
            text: qsTr("ReproOS will be installed on the selected disk. All existing data on that disk will be erased. The wizard runs `repro disk apply` on this layout once you confirm on the Install screen.")
            font.pixelSize: 13
            color: "#8a8aa3"
            wrapMode: Text.WordWrap
            Layout.fillWidth: true
        }

        // Target device picker.
        GridLayout {
            columns: 2
            rowSpacing: 14
            columnSpacing: 16
            Layout.topMargin: 16
            Layout.fillWidth: true

            Label { text: qsTr("Target disk:"); color: "#e6e6f0"; font.pixelSize: 14 }
            RowLayout {
                spacing: 8
                Layout.fillWidth: true

                ComboBox {
                    id: diskCombo
                    Layout.fillWidth: true
                    model: installerState.availableDisks
                    textRole: ""
                    displayText: currentText.length > 0
                        ? diskScreen.formatEntry(currentText)
                        : qsTr("(no disks detected)")
                    delegate: ItemDelegate {
                        width: diskCombo.width
                        text: diskScreen.formatEntry(modelData)
                    }
                    onCurrentTextChanged: {
                        if (currentText.length > 0) {
                            installerState.targetDevice =
                                diskScreen.pickDevicePath(currentText);
                        }
                    }
                    Component.onCompleted: {
                        // Sync current selection with state.
                        for (var i = 0; i < model.length; ++i) {
                            if (diskScreen.pickDevicePath(model[i]) === installerState.targetDevice) {
                                currentIndex = i; break;
                            }
                        }
                    }
                }

                Button {
                    text: qsTr("Refresh")
                    onClicked: {
                        installerState.refreshAvailableDisks();
                        // Re-pick the saved device once the model
                        // refreshes (the model length may grow).
                        diskCombo.currentIndex = 0;
                    }
                }
            }
        }

        // Layout preset.
        Label {
            text: qsTr("Layout preset:")
            color: "#e6e6f0"
            font.pixelSize: 14
            Layout.topMargin: 12
        }

        ColumnLayout {
            spacing: 8
            Layout.leftMargin: 16

            RadioButton {
                id: presetSimple
                text: qsTr("Simple (GPT + ESP + ext4 root)")
                checked: installerState.diskoPreset === "simple"
                onToggled: if (checked) installerState.diskoPreset = "simple"
            }
            Label {
                text: qsTr("Recommended. One 512 MiB EFI System Partition mounted at /boot, ext4 root on the remainder. Best for single-disk first installs.")
                font.pixelSize: 12
                color: "#8a8aa3"
                wrapMode: Text.WordWrap
                Layout.fillWidth: true
                Layout.leftMargin: 28
            }

            RadioButton {
                id: presetEncrypted
                text: qsTr("Encrypted (GPT + ESP + LUKS2 + btrfs subvols)")
                checked: installerState.diskoPreset === "encrypted"
                onToggled: if (checked) installerState.diskoPreset = "encrypted"
            }
            Label {
                text: qsTr("LUKS2 full-disk encryption on the root partition. Btrfs subvolumes @, @home, @nix. You will type a passphrase at every boot.")
                font.pixelSize: 12
                color: "#8a8aa3"
                wrapMode: Text.WordWrap
                Layout.fillWidth: true
                Layout.leftMargin: 28
            }

            RadioButton {
                id: presetAdvanced
                text: qsTr("Advanced (skip wizard, edit hardware.nim manually)")
                checked: installerState.diskoPreset === "advanced"
                onToggled: if (checked) installerState.diskoPreset = "advanced"
            }
            Label {
                text: qsTr("Skip the disko block. The installer will boot to a shell after first boot so you can hand-author hardware.nim.")
                font.pixelSize: 12
                color: "#8a8aa3"
                wrapMode: Text.WordWrap
                Layout.fillWidth: true
                Layout.leftMargin: 28
            }
        }

        // Encrypted-only passphrase fields.
        GridLayout {
            visible: installerState.diskoPreset === "encrypted"
            columns: 2
            rowSpacing: 10
            columnSpacing: 16
            Layout.topMargin: 12

            Label { text: qsTr("Passphrase:"); color: "#e6e6f0"; font.pixelSize: 14 }
            TextField {
                id: passField
                Layout.preferredWidth: 320
                echoMode: TextInput.Password
                text: installerState.diskPassphrase
                placeholderText: qsTr("LUKS2 unlock passphrase")
                onTextChanged: installerState.diskPassphrase = text
            }

            Label { text: qsTr("Confirm:"); color: "#e6e6f0"; font.pixelSize: 14 }
            TextField {
                id: passConfirm
                Layout.preferredWidth: 320
                echoMode: TextInput.Password
                placeholderText: qsTr("Type the passphrase again")
            }
        }

        Label {
            visible: installerState.diskoPreset === "encrypted"
                && passConfirm.text.length > 0
                && passConfirm.text !== installerState.diskPassphrase
            text: qsTr("Passphrases do not match.")
            color: "#e85050"
            font.pixelSize: 13
        }

        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 1
            color: "#2c2c3a"
            Layout.topMargin: 12
        }

        // Destructive opt-in.
        CheckBox {
            id: wipeAck
            text: qsTr("I understand all data on %1 will be destroyed.")
                .arg(installerState.targetDevice.length > 0
                     ? installerState.targetDevice : qsTr("the selected disk"))
            checked: installerState.wipeAcknowledged
            onToggled: installerState.wipeAcknowledged = checked
            visible: installerState.diskoPreset !== "advanced"
        }

        Label {
            visible: installerState.diskoPreset !== "advanced"
                && !wipeAck.checked
            text: qsTr("Tick the box above before continuing.")
            color: "#e8a050"
            font.pixelSize: 12
        }

        Item { Layout.fillHeight: true }
    }

    Component.onCompleted: {
        // Populate the disks list the first time the screen is shown.
        // The user may hit Refresh to re-probe (e.g. plugged in a USB
        // mid-wizard).
        if (installerState.availableDisks.length === 0) {
            installerState.refreshAvailableDisks();
        }
    }
}
