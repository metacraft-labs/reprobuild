// M9.R.18.4 -- InstallerState model holding the wizard's gathered
// choices. Exposed to QML via QObject properties so each screen can
// bind directly to `installerState.username`, `installerState.timezone`,
// etc. and the Summary screen can drive the system.nim preview off
// the same source of truth.
//
// M9.R.23.2 -- extended with the Disk-screen-driven properties
// (targetDevice, diskoPreset, diskPassphrase, wipeAcknowledged,
// availableDisks) + the install() orchestration entry point that drives
// the M9.R.21 / M9.R.22 / M9.R.22b CLI commands end-to-end.
//
// Per ReproOS-Installer-PRD.md Sec 3.1 the ten wizard screens collect:
//  - Welcome  (no state captured; orient the user)
//  - Locale   -> timezone + locale
//  - Keyboard -> keymap
//  - Users    -> username + fullName + password + isAdmin
//  - Disk     -> targetDevice + diskoPreset + diskPassphrase
//  - DE       -> desktopKind (sway / plasma / gnome / hyprland)
//  - Activities -> set of activity-name strings
//  - Summary  (no state captured; show preview)
//  - Install  (drives install() via QProcess wrappers)
//  - Finished (no state captured; reboot prompt)

#pragma once

#include <QtCore/QObject>
#include <QtCore/QProcess>
#include <QtCore/QString>
#include <QtCore/QStringList>

class InstallerState : public QObject {
    Q_OBJECT

    Q_PROPERTY(QString hostname READ hostname WRITE setHostname NOTIFY hostnameChanged)
    Q_PROPERTY(QString locale READ locale WRITE setLocale NOTIFY localeChanged)
    Q_PROPERTY(QString timezone READ timezone WRITE setTimezone NOTIFY timezoneChanged)
    Q_PROPERTY(QString keymap READ keymap WRITE setKeymap NOTIFY keymapChanged)
    Q_PROPERTY(QString username READ username WRITE setUsername NOTIFY usernameChanged)
    Q_PROPERTY(QString fullName READ fullName WRITE setFullName NOTIFY fullNameChanged)
    Q_PROPERTY(QString password READ password WRITE setPassword NOTIFY passwordChanged)
    Q_PROPERTY(bool isAdmin READ isAdmin WRITE setIsAdmin NOTIFY isAdminChanged)
    Q_PROPERTY(QString desktopKind READ desktopKind WRITE setDesktopKind NOTIFY desktopKindChanged)
    Q_PROPERTY(QStringList activeActivities READ activeActivities WRITE setActiveActivities NOTIFY activeActivitiesChanged)
    Q_PROPERTY(QString activitiesTomlPath READ activitiesTomlPath WRITE setActivitiesTomlPath NOTIFY activitiesTomlPathChanged)
    Q_PROPERTY(bool dryRun READ dryRun WRITE setDryRun NOTIFY dryRunChanged)

    // M9.R.23.2 disk-screen properties.
    Q_PROPERTY(QString targetDevice READ targetDevice WRITE setTargetDevice NOTIFY targetDeviceChanged)
    Q_PROPERTY(QString diskoPreset READ diskoPreset WRITE setDiskoPreset NOTIFY diskoPresetChanged)
    Q_PROPERTY(QString diskPassphrase READ diskPassphrase WRITE setDiskPassphrase NOTIFY diskPassphraseChanged)
    Q_PROPERTY(bool wipeAcknowledged READ wipeAcknowledged WRITE setWipeAcknowledged NOTIFY wipeAcknowledgedChanged)
    Q_PROPERTY(QStringList availableDisks READ availableDisks WRITE setAvailableDisks NOTIFY availableDisksChanged)

    // M9.R.23.3 install-runtime properties.
    Q_PROPERTY(QString installLog READ installLog NOTIFY installLogChanged)
    Q_PROPERTY(QString installStatus READ installStatus NOTIFY installStatusChanged)
    Q_PROPERTY(qreal installProgress READ installProgress NOTIFY installProgressChanged)
    Q_PROPERTY(bool installRunning READ installRunning NOTIFY installRunningChanged)

public:
    explicit InstallerState(QObject *parent = nullptr);

    QString hostname() const { return m_hostname; }
    void setHostname(const QString &v);

    QString locale() const { return m_locale; }
    void setLocale(const QString &v);

    QString timezone() const { return m_timezone; }
    void setTimezone(const QString &v);

    QString keymap() const { return m_keymap; }
    void setKeymap(const QString &v);

    QString username() const { return m_username; }
    void setUsername(const QString &v);

    QString fullName() const { return m_fullName; }
    void setFullName(const QString &v);

    QString password() const { return m_password; }
    void setPassword(const QString &v);

    bool isAdmin() const { return m_isAdmin; }
    void setIsAdmin(bool v);

    QString desktopKind() const { return m_desktopKind; }
    void setDesktopKind(const QString &v);

    QStringList activeActivities() const { return m_activeActivities; }
    void setActiveActivities(const QStringList &v);

    QString activitiesTomlPath() const { return m_activitiesTomlPath; }
    void setActivitiesTomlPath(const QString &v);

    bool dryRun() const { return m_dryRun; }
    void setDryRun(bool v);

    QString targetDevice() const { return m_targetDevice; }
    void setTargetDevice(const QString &v);

    QString diskoPreset() const { return m_diskoPreset; }
    void setDiskoPreset(const QString &v);

    QString diskPassphrase() const { return m_diskPassphrase; }
    void setDiskPassphrase(const QString &v);

    bool wipeAcknowledged() const { return m_wipeAcknowledged; }
    void setWipeAcknowledged(bool v);

    QStringList availableDisks() const { return m_availableDisks; }
    void setAvailableDisks(const QStringList &v);

    QString installLog() const { return m_installLog; }
    QString installStatus() const { return m_installStatus; }
    qreal installProgress() const { return m_installProgress; }
    bool installRunning() const { return m_installRunning; }

    // Render the wizard's current selection into the system.nim text
    // PRD Sec 3.3 documents as the wizard's output. The Summary screen
    // binds its TextArea to the return value.
    Q_INVOKABLE QString renderSystemNim() const;

    // M9.R.23.2 -- render the disko block the M9.R.22 macro consumes.
    // Composes the hardware "<id>": ... disko: ... text per the preset
    // choice; the wizard's target hardware.nim layers this on top of
    // the M9.R.21 probe output.
    Q_INVOKABLE QString renderDiskoNim(const QString &id = QString("INSTALL")) const;

    // Toggle an activity on/off. Bound to each activity-card checkbox.
    Q_INVOKABLE void toggleActivity(const QString &name);
    Q_INVOKABLE bool hasActivity(const QString &name) const;

    // M9.R.23.2 -- shell out to `lsblk -d -o NAME,SIZE,MODEL,VENDOR` and
    // populate availableDisks. The Disk screen calls this on first
    // mount + when the user clicks Refresh.
    Q_INVOKABLE void refreshAvailableDisks();

    // M9.R.23.3 -- the install() orchestration. Drives the full
    // sequence: hardware probe -> disk apply -> mount -> write
    // system.nim + hardware.nim -> system apply -> unmount. Each step
    // emits an installLog line + advances installProgress. The Install
    // screen QML binds to those properties for the live feedback.
    //
    // Honours REPRO_DISK_DRY_RUN=1 by skipping the destructive disk
    // apply step + emitting a "would apply" log line instead. The
    // M9.R.23.4 tests + M9.R.23.5 smoke harness both rely on this gate.
    Q_INVOKABLE void install();

    // M9.R.23.5 -- automated-mode entry point. The smoke harness passes
    // --automated CONFIG_TOML; main.cpp reads the TOML, calls the
    // setters, then invokes install() directly without showing the
    // wizard. Returns the recommended exit code (0 success, 1 failure).
    Q_INVOKABLE int runAutomatedConfig(const QString &configPath);

    // Helper hooks used by install() + the tests. Public so a test
    // harness can mock them in.
    void writeFileAtomic(const QString &path, const QString &text);

signals:
    void hostnameChanged();
    void localeChanged();
    void timezoneChanged();
    void keymapChanged();
    void usernameChanged();
    void fullNameChanged();
    void passwordChanged();
    void isAdminChanged();
    void desktopKindChanged();
    void activeActivitiesChanged();
    void activitiesTomlPathChanged();
    void dryRunChanged();

    void targetDeviceChanged();
    void diskoPresetChanged();
    void diskPassphraseChanged();
    void wipeAcknowledgedChanged();
    void availableDisksChanged();

    void installLogChanged();
    void installStatusChanged();
    void installProgressChanged();
    void installRunningChanged();
    void installComplete();
    void installFailed(const QString &reason);

private:
    // PRD Sec 3.3 baseline defaults -- safe starting values for a
    // first-time user who clicks Next through every screen.
    QString m_hostname = "reproos";
    QString m_locale = "en_US.UTF-8";
    QString m_timezone = "Europe/Sofia";
    QString m_keymap = "us";
    QString m_username = "alice";
    QString m_fullName = "Alice Example";
    QString m_password;
    bool m_isAdmin = true;
    QString m_desktopKind = "plasma";
    // PRD Sec 4.2 pre-checks Daily Computing + System Tools.
    QStringList m_activeActivities = {"daily-computing", "system-tools"};
    QString m_activitiesTomlPath;
    bool m_dryRun = false;

    // M9.R.23 disk fields. Empty targetDevice forces the wizard to
    // re-probe before allowing Next on the Disk screen.
    QString m_targetDevice;
    QString m_diskoPreset = "simple";
    QString m_diskPassphrase;
    bool m_wipeAcknowledged = false;
    QStringList m_availableDisks;

    // M9.R.23 install runtime.
    QString m_installLog;
    QString m_installStatus = "Ready to install";
    qreal m_installProgress = 0.0;
    bool m_installRunning = false;

    // Helpers used by install() -- each runs the matching `repro`
    // subcommand and returns true on exit 0. The bool* outResult is set
    // when the caller wants to inspect the exit code.
    bool runReproHardwareProbe(const QString &outputPath);
    bool runReproDiskApply();
    bool runReproDiskMount(const QString &mountPoint);
    bool runReproDiskUnmount(const QString &mountPoint);
    bool runReproSystemApply(const QString &target);

    // Append a line to installLog + emit installLogChanged.
    void appendLog(const QString &line);
    void setInstallStatus(const QString &s);
    void setInstallProgress(qreal v);
    void setInstallRunning(bool v);

    // Spawn `repro <subcommand>` synchronously, capturing stdout +
    // stderr into installLog. Returns the exit code (-1 on spawn fail).
    int runReproSubcommand(const QStringList &args, int timeoutMs = 300000);

    // M9.R.23.3 -- when REPRO_DISK_DRY_RUN=1 is set, every destructive
    // step is logged but skipped. Used by the tests + the
    // --automated smoke harness.
    bool dryRunDestructive() const;
};
