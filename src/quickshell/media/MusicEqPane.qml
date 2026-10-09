import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import "../"
import "../reusables"

// Ten-band equalizer for the music panel (EasyEffects through media/equalizer.sh, the same
// backend as the original panel). Dragging a band stages it ("Apply" commits it); presets
// apply at once. Nothing is started until a change is made.
Item {
    id: root

    property bool active: visible
    property color accentColor: ThemeBackend.mauve
    property color chipColor: Qt.alpha(ThemeBackend.text, 0.08)
    property color chipHoverColor: Qt.alpha(ThemeBackend.text, 0.16)

    function s(val) { return Scaler.s(val); }

    readonly property var bands: ["31", "63", "125", "250", "500", "1k", "2k", "4k", "8k", "16k"]
    readonly property var presetNames: ["Flat", "Bass", "Treble", "Vocal", "Pop", "Rock", "Jazz", "Classic"]
    readonly property var presetValues: ({
        "Flat": [0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
        "Bass": [5, 7, 5, 2, 1, 0, 0, 0, 1, 2],
        "Treble": [-2, -1, 0, 1, 2, 3, 4, 5, 6, 6],
        "Vocal": [-2, -1, 1, 3, 5, 5, 4, 2, 1, 0],
        "Pop": [2, 4, 2, 0, 1, 2, 4, 2, 1, 2],
        "Rock": [5, 4, 2, -1, -2, -1, 2, 4, 5, 6],
        "Jazz": [3, 3, 1, 1, 1, 1, 2, 1, 2, 3],
        "Classic": [0, 1, 2, 2, 2, 2, 1, 2, 3, 4]
    })

    property var eqData: ({ "b1": 0, "b2": 0, "b3": 0, "b4": 0, "b5": 0, "b6": 0, "b7": 0, "b8": 0, "b9": 0, "b10": 0, "preset": "Flat", "pending": false })
    property real lastLocalEdit: 0

    function band(i) {
        let v = Number(eqData["b" + i]);
        return isNaN(v) ? 0 : v;
    }

    function run(args) {
        Quickshell.execDetached(["bash", Caching.qsDir + "/media/equalizer.sh"].concat(args));
    }

    function setBand(i, v) {
        let d = Object.assign({}, eqData);
        d["b" + i] = v;
        d.preset = "Custom";
        d.pending = true;
        eqData = d;
        lastLocalEdit = Date.now();
        run(["set_band", String(i), String(v)]);
    }

    function applyPending() {
        let d = Object.assign({}, eqData);
        d.pending = false;
        eqData = d;
        lastLocalEdit = Date.now();
        run(["apply"]);
    }

    function applyPreset(name) {
        let vals = presetValues[name];
        if (!vals) return;
        let d = Object.assign({}, eqData);
        for (let i = 0; i < 10; i++) d["b" + (i + 1)] = vals[i];
        d.preset = name;
        d.pending = false;
        eqData = d;
        lastLocalEdit = Date.now();
        run(["preset", name]);
    }

    Process {
        id: readProc
        command: ["bash", Caching.qsDir + "/media/equalizer.sh", "get"]
        stdout: StdioCollector {
            onStreamFinished: {
                if (Date.now() - root.lastLocalEdit < 2500) return;
                try {
                    let d = JSON.parse(this.text.trim());
                    if (d && typeof d === "object") root.eqData = d;
                } catch (e) {}
            }
        }
    }
    onActiveChanged: if (active && !readProc.running) readProc.running = true
    Component.onCompleted: if (active) readProc.running = true

    ColumnLayout {
        anchors.fill: parent
        spacing: root.s(12)

        RowLayout {
            Layout.fillWidth: true
            spacing: root.s(8)

            Text {
                text: "Equalizer"
                font.family: ThemeBackend.fontFamily
                font.pixelSize: root.s(15)
                font.weight: Font.Bold
                color: ThemeBackend.text
            }
            Text {
                Layout.fillWidth: true
                text: root.eqData.preset || ""
                font.family: ThemeBackend.fontFamily
                font.pixelSize: root.s(12)
                font.weight: Font.DemiBold
                color: Qt.alpha(ThemeBackend.text, 0.5)
                elide: Text.ElideRight
            }
            Rectangle {
                id: applyBtn
                visible: !!root.eqData.pending
                Layout.preferredHeight: root.s(26)
                Layout.preferredWidth: applyLabel.implicitWidth + root.s(24)
                radius: height / 2
                color: applyMouse.containsMouse ? Qt.lighter(root.accentColor, 1.1) : root.accentColor
                Text {
                    id: applyLabel
                    anchors.centerIn: parent
                    text: "Apply"
                    font.family: ThemeBackend.fontFamily
                    font.pixelSize: root.s(12)
                    font.weight: Font.Bold
                    color: ThemeBackend.base
                }
                MouseArea {
                    id: applyMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.applyPending()
                }
            }
        }

        // Bands: a centre line at 0 dB, the fill grows up or down from it.
        Item {
            Layout.fillWidth: true
            Layout.fillHeight: true

            Rectangle {
                x: 0
                width: parent.width
                y: bandRow.y + root.s(6) + (bandRow.height - root.s(30)) / 2
                height: 1
                color: Qt.alpha(ThemeBackend.text, 0.10)
            }

            Row {
                id: bandRow
                anchors.fill: parent

                Repeater {
                    model: root.bands
                    delegate: Item {
                        id: bandItem
                        required property string modelData
                        required property int index
                        readonly property int bandNo: index + 1
                        width: bandRow.width / root.bands.length
                        height: bandRow.height

                        property real dragVal: 0
                        readonly property bool dragging: bandMouse.pressed
                        readonly property real shown: dragging ? dragVal : root.band(bandNo)

                        Item {
                            id: rail
                            anchors.horizontalCenter: parent.horizontalCenter
                            y: root.s(6)
                            width: root.s(8)
                            height: parent.height - root.s(30)

                            readonly property real mid: height / 2
                            readonly property real knobY: mid - (bandItem.shown / 12) * (height / 2)

                            Rectangle {
                                anchors.fill: parent
                                radius: width / 2
                                color: Qt.alpha(ThemeBackend.text, bandMouse.containsMouse || bandItem.dragging ? 0.14 : 0.08)
                                Behavior on color { ColorAnimation { duration: 180 } }
                            }
                            Rectangle {
                                x: 0
                                width: parent.width
                                radius: width / 2
                                y: Math.min(rail.mid, rail.knobY)
                                height: Math.max(width, Math.abs(rail.knobY - rail.mid))
                                color: root.accentColor
                                opacity: bandItem.shown === 0 ? 0.0 : 0.9
                                Behavior on y { enabled: !bandItem.dragging; NumberAnimation { duration: 320; easing.type: Easing.OutCubic } }
                                Behavior on height { enabled: !bandItem.dragging; NumberAnimation { duration: 320; easing.type: Easing.OutCubic } }
                                Behavior on opacity { NumberAnimation { duration: 200 } }
                            }
                            Rectangle {
                                width: root.s(16)
                                height: width
                                radius: width / 2
                                anchors.horizontalCenter: parent.horizontalCenter
                                y: rail.knobY - height / 2
                                color: ThemeBackend.text
                                scale: bandItem.dragging ? 1.18 : (bandMouse.containsMouse ? 1.06 : 1.0)
                                Behavior on y { enabled: !bandItem.dragging; NumberAnimation { duration: 320; easing.type: Easing.OutCubic } }
                                Behavior on scale { NumberAnimation { duration: 200; easing.type: Easing.OutBack } }
                            }
                        }

                        Text {
                            anchors.horizontalCenter: parent.horizontalCenter
                            anchors.bottom: parent.bottom
                            text: bandItem.dragging ? ((bandItem.dragVal > 0 ? "+" : "") + bandItem.dragVal) : bandItem.modelData
                            font.family: ThemeBackend.fontFamily
                            font.pixelSize: root.s(10)
                            font.weight: Font.DemiBold
                            color: bandItem.dragging ? ThemeBackend.text : Qt.alpha(ThemeBackend.text, 0.5)
                        }

                        MouseArea {
                            id: bandMouse
                            anchors.fill: parent
                            hoverEnabled: true
                            preventStealing: true
                            cursorShape: Qt.PointingHandCursor
                            function valueAt(y) {
                                let ry = y - rail.y;
                                let v = Math.round((rail.mid - ry) / (rail.height / 2) * 12);
                                return Math.max(-12, Math.min(12, v));
                            }
                            onPressed: (m) => { bandItem.dragVal = valueAt(m.y); }
                            onPositionChanged: (m) => { if (pressed) bandItem.dragVal = valueAt(m.y); }
                            onReleased: (m) => {
                                let v = valueAt(m.y);
                                if (v !== root.band(bandItem.bandNo)) root.setBand(bandItem.bandNo, v);
                            }
                        }
                    }
                }
            }
        }

        GridLayout {
            Layout.fillWidth: true
            columns: 4
            rowSpacing: root.s(6)
            columnSpacing: root.s(6)

            Repeater {
                model: root.presetNames
                delegate: Rectangle {
                    id: presetBtn
                    required property string modelData
                    readonly property bool current: root.eqData.preset === modelData
                    Layout.fillWidth: true
                    Layout.preferredHeight: root.s(28)
                    radius: height / 2
                    color: current ? root.accentColor : (presetMouse.containsMouse ? root.chipHoverColor : root.chipColor)
                    Behavior on color { ColorAnimation { duration: 200 } }
                    Text {
                        anchors.centerIn: parent
                        text: presetBtn.modelData
                        font.family: ThemeBackend.fontFamily
                        font.pixelSize: root.s(11.5)
                        font.weight: Font.DemiBold
                        color: presetBtn.current ? ThemeBackend.base : Qt.alpha(ThemeBackend.text, 0.8)
                    }
                    MouseArea {
                        id: presetMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.applyPreset(presetBtn.modelData)
                    }
                }
            }
        }
    }
}
