pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import "../"

// Shared, ref-counted system sampler for desktop widgets (vitals rings, traffic graph).
// Reads /proc and /sys directly through FileView once per second while at least one
// widget is subscribed; nothing is spawned per tick. Sensor paths are discovered once.
// Every value is -1 when its sensor is missing, so faces can hide that element.
Singleton {
    id: root

    property int subscribers: 0
    readonly property bool active: subscribers > 0
    readonly property int historySize: 61

    function subscribe() { subscribers++; }
    function unsubscribe() { subscribers = Math.max(0, subscribers - 1); }

    // 0..1 fractions, -1 = unavailable
    property real cpu: -1
    property real ram: -1
    property real gpu: -1
    property real npu: -1
    property real ramUsedGb: 0
    property real ramTotalGb: 0
    property real tempC: -1

    // bytes per second
    property real netRx: 0
    property real netTx: 0
    property real diskRead: 0
    property real diskWrite: 0
    property var netRxHist: []
    property var netTxHist: []
    property var diskReadHist: []
    property var diskWriteHist: []
    property int sampleCount: 0

    signal sampled()

    // discovered paths
    property bool discovered: false
    property string tempPath: ""
    property string gpuPath: ""
    property string npuPath: ""
    property string gpuFreqPath: ""
    property real gpuMaxMhz: 0
    property real gpuMhz: -1
    property var diskNames: []

    property var _prev: ({})

    onActiveChanged: {
        if (active) {
            if (!discovered) discoverProc.running = true;
            else root.sample();
        } else {
            root._prev = {};
        }
    }

    Process {
        id: discoverProc
        running: false
        command: ["bash", "-c",
            "t=''; for z in /sys/class/thermal/thermal_zone*; do [ \"$(cat $z/type 2>/dev/null)\" = x86_pkg_temp ] && t=$z/temp && break; done;" +
            "if [ -z \"$t\" ]; then for h in /sys/class/hwmon/hwmon*; do case \"$(cat $h/name 2>/dev/null)\" in coretemp|k10temp|zenpower) [ -r $h/temp1_input ] && t=$h/temp1_input && break;; esac; done; fi;" +
            "if [ -z \"$t\" ]; then for z in /sys/class/thermal/thermal_zone*; do case \"$(cat $z/type 2>/dev/null)\" in TCPU|cpu*|acpitz) t=$z/temp; break;; esac; done; fi;" +
            "echo \"temp=$t\";" +
            "g=$(ls /sys/class/drm/card*/device/tile0/gt0/gtidle/idle_residency_ms /sys/class/drm/card*/gt/gt0/rc6_residency_ms /sys/class/drm/card*/power/rc6_residency_ms 2>/dev/null | head -n1); echo \"gpu=$g\";" +
            "gd=${g%/*}; gd=${gd%/*}; if [ -r $gd/freq0/act_freq ]; then echo \"gpufreq=$gd/freq0/act_freq\"; echo \"gpumax=$(cat $gd/freq0/rp0_freq 2>/dev/null || cat $gd/freq0/max_freq)\"; else c=$(ls -d /sys/class/drm/card*/gt_act_freq_mhz 2>/dev/null | head -n1); [ -n \"$c\" ] && echo \"gpufreq=$c\" && echo \"gpumax=$(cat ${c%/*}/gt_RP0_freq_mhz 2>/dev/null)\"; fi;" +
            "n=$(ls /sys/class/accel/accel*/device/npu_busy_time_us 2>/dev/null | head -n1); echo \"npu=$n\";" +
            "d=''; for b in /sys/block/*; do n=${b##*/}; case $n in loop*|ram*|zram*|dm-*|sr*|md*|fd*) continue;; esac; [ -e $b/device ] && d=\"$d $n\"; done; echo \"disks=$d\""
        ]
        stdout: StdioCollector {
            onStreamFinished: {
                let lines = (this.text || "").split("\n");
                for (let i = 0; i < lines.length; i++) {
                    let l = lines[i];
                    let eq = l.indexOf("=");
                    if (eq < 0) continue;
                    let k = l.substring(0, eq);
                    let v = l.substring(eq + 1).trim();
                    if (k === "temp") root.tempPath = v;
                    else if (k === "gpu") root.gpuPath = v;
                    else if (k === "npu") root.npuPath = v;
                    else if (k === "gpufreq") root.gpuFreqPath = v;
                    else if (k === "gpumax") root.gpuMaxMhz = parseFloat(v) || 0;
                    else if (k === "disks") root.diskNames = v.split(/\s+/).filter(s => s !== "");
                }
                root.discovered = true;
                if (root.active) root.sample();
            }
        }
    }

    FileView { id: statFile; path: "/proc/stat"; blockLoading: true; printErrors: false }
    FileView { id: memFile; path: "/proc/meminfo"; blockLoading: true; printErrors: false }
    FileView { id: netFile; path: "/proc/net/dev"; blockLoading: true; printErrors: false }
    FileView { id: diskFile; path: "/proc/diskstats"; blockLoading: true; printErrors: false }
    FileView { id: tempFile; path: root.tempPath; blockLoading: true; printErrors: false }
    FileView { id: gpuFile; path: root.gpuPath; blockLoading: true; printErrors: false }
    FileView { id: gpuFreqFile; path: root.gpuFreqPath; blockLoading: true; printErrors: false }
    FileView { id: npuFile; path: root.npuPath; blockLoading: true; printErrors: false }

    Timer {
        // battery worker: every 2 s while PowerSaver is saving (on battery), 1 s on AC
        interval: PowerSaver.interval(1000, 2000)
        repeat: true
        running: root.active && root.discovered
        onTriggered: root.sample()
    }

    function _read(fv) {
        if (!fv.path || fv.path === "") return "";
        try {
            fv.reload();
            return fv.text() || "";
        } catch (e) {
            return "";
        }
    }

    function _push(arr, v) {
        let a = arr.slice(Math.max(0, arr.length - root.historySize + 1));
        a.push(v);
        return a;
    }

    function sample() {
        let now = Date.now();
        let prev = root._prev;
        let next = { t: now };
        let dt = prev.t ? Math.max(0.05, (now - prev.t) / 1000) : 0;

        // CPU
        let st = _read(statFile);
        if (st) {
            let f = st.substring(0, st.indexOf("\n")).trim().split(/\s+/).slice(1).map(Number);
            if (f.length >= 4) {
                let idle = f[3] + (f[4] || 0);
                let total = 0;
                for (let i = 0; i < Math.min(8, f.length); i++) total += f[i];
                next.cpuIdle = idle;
                next.cpuTotal = total;
                if (prev.cpuTotal !== undefined && total > prev.cpuTotal) {
                    let dTot = total - prev.cpuTotal;
                    root.cpu = Math.max(0, Math.min(1, 1 - (idle - prev.cpuIdle) / dTot));
                } else if (root.cpu < 0) {
                    root.cpu = 0;
                }
            }
        }

        // RAM
        let mem = _read(memFile);
        if (mem) {
            let mt = /MemTotal:\s+(\d+)/.exec(mem);
            let ma = /MemAvailable:\s+(\d+)/.exec(mem);
            if (mt && ma) {
                let tot = Number(mt[1]);
                let used = tot - Number(ma[1]);
                root.ramTotalGb = tot / 1048576;
                root.ramUsedGb = used / 1048576;
                root.ram = tot > 0 ? used / tot : -1;
            }
        }

        // Temperature
        if (root.tempPath !== "") {
            let tv = parseFloat(_read(tempFile));
            root.tempC = isNaN(tv) ? -1 : tv / 1000;
        } else {
            root.tempC = -1;
        }

        // GPU: awake fraction (1 - RC6 residency delta) weighted by the current clock
        // relative to its max — a cheap utilisation proxy that needs no perf access.
        if (root.gpuPath !== "") {
            let gv = parseFloat(_read(gpuFile));
            if (!isNaN(gv)) {
                next.gpuIdle = gv;
                let awake = (prev.gpuIdle !== undefined && dt > 0) ? Math.max(0, Math.min(1, 1 - (gv - prev.gpuIdle) / (dt * 1000))) : 0;
                let load = awake;
                if (root.gpuFreqPath !== "" && root.gpuMaxMhz > 0) {
                    let mhz = parseFloat(_read(gpuFreqFile));
                    root.gpuMhz = isNaN(mhz) ? -1 : mhz;
                    if (!isNaN(mhz)) load = awake * Math.max(0, Math.min(1, mhz / root.gpuMaxMhz));
                }
                root.gpu = load;
            } else {
                root.gpu = -1;
            }
        } else {
            root.gpu = -1;
        }

        // NPU (busy time delta)
        if (root.npuPath !== "") {
            let nv = parseFloat(_read(npuFile));
            if (!isNaN(nv)) {
                next.npuBusy = nv;
                if (prev.npuBusy !== undefined && dt > 0) {
                    root.npu = Math.max(0, Math.min(1, (nv - prev.npuBusy) / (dt * 1e6)));
                } else if (root.npu < 0) {
                    root.npu = 0;
                }
            } else {
                root.npu = -1;
            }
        } else {
            root.npu = -1;
        }

        // Network: physical-looking interfaces only (skip lo, tunnels, bridges)
        let nd = _read(netFile);
        if (nd) {
            let rx = 0, tx = 0;
            let lines = nd.split("\n");
            for (let i = 2; i < lines.length; i++) {
                let l = lines[i];
                let c = l.indexOf(":");
                if (c < 0) continue;
                let name = l.substring(0, c).trim();
                if (!/^(wl|en|eth|ww|usb)/.test(name)) continue;
                let f = l.substring(c + 1).trim().split(/\s+/);
                rx += Number(f[0]) || 0;
                tx += Number(f[8]) || 0;
            }
            next.rx = rx;
            next.tx = tx;
            if (prev.rx !== undefined && dt > 0) {
                root.netRx = Math.max(0, (rx - prev.rx) / dt);
                root.netTx = Math.max(0, (tx - prev.tx) / dt);
            }
        }

        // Disk I/O on whole physical disks
        let ds = _read(diskFile);
        if (ds && root.diskNames.length > 0) {
            let rd = 0, wr = 0;
            let lines = ds.split("\n");
            for (let i = 0; i < lines.length; i++) {
                let f = lines[i].trim().split(/\s+/);
                if (f.length < 10) continue;
                if (root.diskNames.indexOf(f[2]) < 0) continue;
                rd += Number(f[5]) * 512;
                wr += Number(f[9]) * 512;
            }
            next.rd = rd;
            next.wr = wr;
            if (prev.rd !== undefined && dt > 0) {
                root.diskRead = Math.max(0, (rd - prev.rd) / dt);
                root.diskWrite = Math.max(0, (wr - prev.wr) / dt);
            }
        }

        root._prev = next;
        if (prev.t) {
            root.netRxHist = _push(root.netRxHist, root.netRx);
            root.netTxHist = _push(root.netTxHist, root.netTx);
            root.diskReadHist = _push(root.diskReadHist, root.diskRead);
            root.diskWriteHist = _push(root.diskWriteHist, root.diskWrite);
            root.sampleCount++;
            root.sampled();
        }
    }

    function formatRate(bps) {
        if (bps === undefined || isNaN(bps) || bps < 0) return "0 B/s";
        if (bps < 1000) return Math.round(bps) + " B/s";
        if (bps < 1000 * 1000) return (bps / 1000).toFixed(bps < 10000 ? 1 : 0) + " KB/s";
        if (bps < 1000 * 1000 * 1000) return (bps / 1e6).toFixed(bps < 1e7 ? 1 : 0) + " MB/s";
        return (bps / 1e9).toFixed(1) + " GB/s";
    }
}
