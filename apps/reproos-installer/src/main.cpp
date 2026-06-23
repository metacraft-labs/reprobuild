// M9.R.18.4 -- ReproOS Installer Qt6/QML entry point.
//
// Per ReproOS-Installer-PRD.md Sec 7.1 the installer is a Qt6 + QML
// application loaded into a single QQmlApplicationEngine. This file
// is the C++ shim PRD Sec 9 Q1 anticipated as the fallback for the
// patchy Nim Qt6 binding landscape -- the logic stays in Nim (via
// the libreproos_installer shared library the Nim recipe builds and
// links here), but the Qt object instantiation is C++.
//
// M9.R.23.5 -- adds the --automated CONFIG_TOML CLI flag that
// bypasses the wizard, loads CONFIG_TOML, and runs install()
// directly. Used by the smoke harness + future first-boot kiosks
// that prefer pre-configured installs.

#include <QtCore/QCommandLineParser>
#include <QtCore/QStandardPaths>
#include <QtCore/QUrl>
#include <QtCore/QDebug>
#include <QtGui/QGuiApplication>
#include <QtQml/QQmlApplicationEngine>
#include <QtQml/QQmlContext>

#include "installer_state.h"

int main(int argc, char *argv[]) {
    QGuiApplication::setApplicationName("ReproOS Installer");
    QGuiApplication::setApplicationVersion("0.1.0");
    QGuiApplication::setOrganizationName("ReproOS");
    QGuiApplication::setOrganizationDomain("reproos.org");

    QGuiApplication app(argc, argv);

    QCommandLineParser parser;
    parser.setApplicationDescription(
        "ReproOS first-boot installer wizard. "
        "See ReproOS-Installer-PRD.md for the user-facing spec.");
    parser.addHelpOption();
    parser.addVersionOption();
    QCommandLineOption activitiesOpt(
        "activities-toml",
        "Path to the activity catalog TOML (default: "
        "/usr/share/reproos-installer/activities.toml).",
        "path",
        "/usr/share/reproos-installer/activities.toml");
    QCommandLineOption dryRunOpt(
        "dry-run",
        "Stop before the destructive install step -- prints the planned "
        "system.nim instead.");
    QCommandLineOption automatedOpt(
        "automated",
        "Skip the wizard + run install() directly using CONFIG_TOML as "
        "the source of truth. The TOML is read with a minimal key=value "
        "parser (no nested tables). Smoke harness + first-boot kiosk "
        "use this path.",
        "config-toml");
    parser.addOption(activitiesOpt);
    parser.addOption(dryRunOpt);
    parser.addOption(automatedOpt);
    parser.process(app);

    InstallerState state;
    state.setActivitiesTomlPath(parser.value(activitiesOpt));
    state.setDryRun(parser.isSet(dryRunOpt));

    if (parser.isSet(automatedOpt)) {
        // Headless install path. main.cpp returns the install() exit
        // code directly without entering the QML event loop.
        const QString cfg = parser.value(automatedOpt);
        const int rc = state.runAutomatedConfig(cfg);
        return rc;
    }

    QQmlApplicationEngine engine;
    engine.rootContext()->setContextProperty("installerState", &state);

    const QUrl url(QStringLiteral("qrc:/qml/main.qml"));
    QObject::connect(&engine, &QQmlApplicationEngine::objectCreated, &app,
        [url](QObject *obj, const QUrl &objUrl) {
            if (!obj && url == objUrl) {
                QGuiApplication::exit(-1);
            }
        }, Qt::QueuedConnection);
    engine.load(url);

    return app.exec();
}
