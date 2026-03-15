var panel = new Panel;
panel.location = "bottom";
panel.height = 2 * smallestFont.pixelSize;

panel.addWidget("org.kde.plasma.kickoff");

var tasks = panel.addWidget("org.kde.plasma.icontasks");
tasks.currentConfigGroup = ["General"];
tasks.writeConfig("launchers", [
    "applications:mullvad-browser.desktop",
    "applications:mullvad-vpn.desktop",
    "applications:org.keepassxc.KeePassXC.desktop",
    "applications:org.kde.konsole.desktop",
    "preferred://filemanager"
]);

panel.addWidget("org.kde.plasma.marginsseparator");
panel.addWidget("org.kde.plasma.systemtray");
panel.addWidget("org.kde.plasma.digitalclock");
panel.addWidget("org.kde.plasma.showdesktop");
