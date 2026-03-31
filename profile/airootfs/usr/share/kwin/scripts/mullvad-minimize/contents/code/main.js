(function () {
    var startTime = Date.now();
    var GRACE_MS = 10000;

    function isMullvad(w) {
        if (!w) return false;
        var rc = (w.resourceClass || "").toString().toLowerCase();
        var cap = (w.caption || "").toString().toLowerCase();
        return rc.indexOf("mullvad") >= 0 || cap.indexOf("mullvad") >= 0;
    }

    function handle(w) {
        if (!isMullvad(w)) return;
        if (Date.now() - startTime > GRACE_MS) return;
        w.minimized = true;
    }

    workspace.windowAdded.connect(handle);
    workspace.windowActivated.connect(handle);
})();
