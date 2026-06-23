// M9.R.18.4 -- InstallerState model holding the wizard's gathered
// choices. Exposed to QML via QObject properties so each screen can
// bind directly to `installerState.username`, `installerState.timezone`,
// etc. and the Summary screen can drive the system.nim preview off
// the same source of truth.
//
// Per ReproOS-Installer-PRD.md Sec 3.1 the eight wizard screens collect:
//  - Welcome  (no state captured; orient the user)
//  - Locale   -> timezone + locale
//  - Keyboard -> keymap
//  - Users    -> username + fullName + password + isAdmin
//  - DE       -> desktopKind (sway / plasma / gnome / hyprland)
//  - Activities -> set of activity-name strings
//  - Summary  (no state captured; show preview)
//  - Install  (no state captured; runs the apply)

#pragma once

#include <QtCore/QObject>
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

    // Render the wizard's current selection into the system.nim text
    // PRD Sec 3.3 documents as the wizard's output. The Summary screen
    // binds its TextArea to the return value.
    Q_INVOKABLE QString renderSystemNim() const;

    // Toggle an activity on/off. Bound to each activity-card checkbox.
    Q_INVOKABLE void toggleActivity(const QString &name);
    Q_INVOKABLE bool hasActivity(const QString &name) const;

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
};
