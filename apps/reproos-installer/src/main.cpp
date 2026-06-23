// M9.R.18.4 -- ReproOS Installer Qt6/QML entry point.
//
// Per ReproOS-Installer-PRD.md Sec 7.1 the installer is a Qt6 + QML
// application loaded into a single QQmlApplicationEngine. This file
// is the C++ shim PRD Sec 9 Q1 anticipated as the fallback for the
// patchy Nim Qt6 binding landscape -- the logic stays in Nim (via
// the libreproos_installer shared library the Nim recipe builds and
// links here), but the Qt object instantiation is C++.
//
// v0.1 scope (this commit): the engine loads qrc:/qml/main.qml which
// drives a StackView through the eight wizard screens documented in
// ReproOS-Installer-PRD.md Sec 3.1. The on-disk apply pipeline (Sec 7.2
// step 8) is stubbed -- the install screen shells out to `echo` until
// M9.R.19 wires it to `repro disk apply` + `repro infra apply`.

#include <QtCore/QCommandLineParser>
#include <QtGui/QGuiApplication>
#include <QtQml/QQmlApplicationEngine>
#include <QtQml/QQmlContext>
#include <QtCore/QStandardPaths>
#include <QtCore/QUrl>
#include <QtCore/QDebug>

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
    parser.addOption(activitiesOpt);
    parser.addOption(dryRunOpt);
    parser.process(app);

    InstallerState state;
    state.setActivitiesTomlPath(parser.value(activitiesOpt));
    state.setDryRun(parser.isSet(dryRunOpt));

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
