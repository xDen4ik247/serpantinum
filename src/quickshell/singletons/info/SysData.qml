pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import "../../"

Item {
    id: root

    property int cpu: 0
    property int ramPercent: 0
    property real ramGb: 0.0
    property int temp: 0
    property real netRx: 0
    property real netTx: 0
    property int diskPercent: 0
    property real diskGb: 0.0
    property real diskTotalGb: 0.0

    property int subscribers: 0
    property bool isScanningNet: false

    // glass: serp-sysdata (Rust) streams the samples from one long-running process; the bash
    // fetcher on a timer (about ten processes per sample) is the fallback when it isn't installed.
    property bool streamFailed: false
    readonly property int sampleInterval: PowerSaver.interval(2000, 5000)
    onSampleIntervalChanged: {
        if (sysStream.running) {
            sysStream.running = false;
            sysStream.running = true;
        }
    }

    function startPolling() {
        if (!streamFailed) {
            sysStream.running = true;
        } else {
            fetchTimer.restart();
            fetchProc.running = true;
        }
    }

    function applyLine(text) {
        text = text ? text.trim() : "";
        if (!text) return;
        let p = text.split("|");
        if (p.length >= 4) {
            root.cpu = parseInt(p[0]);
            root.ramPercent = parseInt(p[1]);
            root.ramGb = parseFloat(p[2]);
            root.temp = parseInt(p[3]);
        }
        if (p.length >= 9) {
            root.diskPercent = parseInt(p[6]);
            root.diskGb = parseFloat(p[7]);
            root.diskTotalGb = parseFloat(p[8]);
        }
    }

    function subscribe() {
        subscribers++;
        if (subscribers === 1) {
            startPolling();
        }
    }

    function unsubscribe() {
        subscribers = Math.max(0, subscribers - 1);
        if (subscribers === 0) {
            sysRestart.stop();
            sysStream.running = false;
            fetchTimer.stop();
            fetchProc.running = false;
        }
    }

    function prewarm() {
        if (!fetchProc.running) {
            fetchProc.running = true;
        }
    }

    function scanNetwork() {
        if (isScanningNet) return;
        isScanningNet = true;
        netScanProc.running = false;
        netScanProc.running = true;
    }

    Process {
        id: sysStream
        running: false
        command: ["sh", "-c", "command -v serp-sysdata >/dev/null 2>&1 || exit 127; exec serp-sysdata --interval \"$0\"", String(root.sampleInterval)]
        stdout: SplitParser {
            onRead: data => root.applyLine(data)
        }
        onExited: (exitCode, exitStatus) => {
            if (exitCode === 127) {
                root.streamFailed = true;
                if (root.subscribers > 0) root.startPolling();
            } else if (root.subscribers > 0 && !sysStream.running) {
                sysRestart.restart();
            }
        }
    }

    Timer {
        id: sysRestart
        interval: 2000
        repeat: false
        onTriggered: if (root.subscribers > 0 && !sysStream.running) sysStream.running = true
    }

    Timer {
        id: fetchTimer
        // battery worker: 5 s while PowerSaver is saving (on battery), 2 s on AC
        interval: PowerSaver.interval(2000, 5000)
        repeat: true
        running: false
        onTriggered: {
            fetchProc.running = false;
            fetchProc.running = true;
        }
    }

    Process {
        id: fetchProc
        running: false
        command: ["bash", "-c", "export QS_CACHE_SYSDATA='" + Caching.getCacheDir("sysdata") + "'; export QS_SCAN_NET=0; bash '" + Caching.qsDir + "/watchers/sys_fetcher.sh'"]
        stdout: StdioCollector {
            onStreamFinished: root.applyLine(this.text)
        }
    }

    Process {
        id: netScanProc
        running: false
        command: ["bash", "-c", "export QS_CACHE_SYSDATA='" + Caching.getCacheDir("sysdata") + "'; export QS_SCAN_NET=1; bash '" + Caching.qsDir + "/watchers/sys_fetcher.sh'"]
        stdout: StdioCollector {
            onStreamFinished: {
                let text = this.text ? this.text.trim() : "";
                if (text) {
                    let p = text.split("|");
                    if (p.length >= 6) {
                        root.cpu = parseInt(p[0]);
                        root.ramPercent = parseInt(p[1]);
                        root.ramGb = parseFloat(p[2]);
                        root.temp = parseInt(p[3]);
                        root.netRx = parseFloat(p[4]);
                        root.netTx = parseFloat(p[5]);
                    }
                    if (p.length >= 9) {
                        root.diskPercent = parseInt(p[6]);
                        root.diskGb = parseFloat(p[7]);
                        root.diskTotalGb = parseFloat(p[8]);
                    }
                }
                root.isScanningNet = false;
            }
        }
    }
}
