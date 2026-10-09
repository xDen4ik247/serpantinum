import QtQuick
import Quickshell
import Quickshell.Services.UPower
import "../../"
import "../../../"

// Non-visual helper shared by the vitals faces: subscribes to WidgetSensors while visible
// and exposes a list of metrics. Metrics whose sensor is missing are flagged unavailable.
Item {
    id: data
    visible: false

    property bool active: true
    property bool showCpu: true
    property bool showGpu: true
    property bool showNpu: true
    property bool showRam: true
    property bool showTemp: true
    property bool showBattery: true

    property bool subscribed: false
    function updateSubscription() {
        if (active && !subscribed) { WidgetSensors.subscribe(); subscribed = true; }
        else if (!active && subscribed) { WidgetSensors.unsubscribe(); subscribed = false; }
    }
    onActiveChanged: updateSubscription()
    Component.onCompleted: updateSubscription()
    Component.onDestruction: if (subscribed) WidgetSensors.unsubscribe()

    function mix(a, b, t) {
        t = Math.max(0, Math.min(1, t));
        return Qt.rgba(a.r + (b.r - a.r) * t, a.g + (b.g - a.g) * t, a.b + (b.b - a.b) * t, 1);
    }
    // Shift towards the error colour as a load gets critical.
    function loadColor(base, v) {
        return v > 0.8 ? mix(base, ThemeBackend.red, (v - 0.8) / 0.15) : base;
    }

    readonly property bool hasBattery: UPower.displayDevice.ready && UPower.displayDevice.isLaptopBattery
    readonly property real batFrac: hasBattery ? Math.max(0, Math.min(1, UPower.displayDevice.percentage)) : -1
    readonly property bool charging: hasBattery && (UPower.displayDevice.state === UPowerDeviceState.Charging
        || UPower.displayDevice.state === UPowerDeviceState.FullyCharged
        || UPower.displayDevice.state === UPowerDeviceState.PendingCharge)

    readonly property var metrics: {
        let s = WidgetSensors;
        let out = [];
        let pct = v => String(Math.round(Math.max(0, v) * 100));

        out.push({ key: "cpu", label: "CPU", icon: String.fromCodePoint(0xF0EE0),
            available: showCpu && s.cpu >= 0, value: Math.max(0, s.cpu), text: pct(s.cpu), unit: "%",
            detail: pct(s.cpu) + "%", accent: loadColor(ThemeBackend.mauve, s.cpu) });

        out.push({ key: "gpu", label: "GPU", icon: String.fromCodePoint(0xF08AE),
            available: showGpu && s.gpu >= 0, value: Math.max(0, s.gpu), text: pct(s.gpu), unit: "%",
            detail: s.gpuMhz === 0 ? "Idle" : s.gpuMhz > 0 ? (s.gpuMhz >= 1000 ? (s.gpuMhz / 1000).toFixed(2) + " GHz" : Math.round(s.gpuMhz) + " MHz") : pct(s.gpu) + "%",
            accent: loadColor(ThemeBackend.peach, s.gpu) });

        out.push({ key: "npu", label: "NPU", icon: String.fromCodePoint(0xF09D1),
            available: showNpu && s.npu >= 0, value: Math.max(0, s.npu), text: pct(s.npu), unit: "%",
            detail: pct(s.npu) + "%", accent: ThemeBackend.teal });

        out.push({ key: "ram", label: "RAM", icon: String.fromCodePoint(0xF035B),
            available: showRam && s.ram >= 0, value: Math.max(0, s.ram), text: pct(s.ram), unit: "%",
            detail: s.ramUsedGb.toFixed(1) + " / " + Math.round(s.ramTotalGb) + " GB",
            accent: loadColor(mix(ThemeBackend.mauve, ThemeBackend.peach, 0.5), s.ram) });

        let t = s.tempC;
        let tf = Math.max(0, Math.min(1, (t - 30) / 70));
        out.push({ key: "temp", label: "TEMP", icon: String.fromCodePoint(0xF050F),
            available: showTemp && t >= 0, value: tf, text: t >= 0 ? Math.round(t) + "°" : "–", unit: "",
            detail: (t >= 0 ? Math.round(t) : "–") + " °C",
            accent: t >= 80 ? mix(ThemeBackend.peach, ThemeBackend.red, (t - 80) / 12) : (t >= 60 ? mix(ThemeBackend.teal, ThemeBackend.peach, (t - 60) / 20) : ThemeBackend.teal) });

        out.push({ key: "bat", label: charging ? "AC" : "BAT", icon: String.fromCodePoint(charging ? 0xF140B : 0xF0079),
            available: showBattery && hasBattery, value: Math.max(0, batFrac), text: pct(batFrac), unit: "%",
            detail: (charging ? "Charging · " : "") + pct(batFrac) + "%",
            accent: (!charging && batFrac <= 0.2) ? ThemeBackend.red : (charging ? ThemeBackend.mauve : ThemeBackend.green) });

        return out;
    }

    readonly property var visibleMetrics: metrics.filter(m => m.available)
}
