import QtQuick

// Small delayed tooltip that floats above its parent.
Item {
    id: tt
    property var app
    property string text: ""
    property bool shown: false
    property bool below: false
    anchors.horizontalCenter: parent.horizontalCenter
    y: below ? parent.height + 8 : -height - 8
    width: label.implicitWidth + 20
    height: 28
    z: 1000
    visible: opacity > 0
    opacity: 0
    states: State { name: "on"; when: tt.shown && delay.done; PropertyChanges { target: tt; opacity: 1 } }
    transitions: Transition { NumberAnimation { property: "opacity"; duration: 160 } }
    Timer { id: delay; property bool done: false; interval: 550; running: tt.shown; onTriggered: done = true; onRunningChanged: if (!running && !tt.shown) done = false }
    Rectangle {
        anchors.fill: parent
        radius: 8
        color: tt.app.th.alpha(tt.app.th.surface2, 0.96)
        border.color: tt.app.th.alpha("white", 0.08)
    }
    Text {
        id: label
        anchors.centerIn: parent
        text: tt.text
        color: tt.app.th.text
        font.family: tt.app.th.font
        font.pixelSize: 12
        font.weight: Font.Medium
    }
}
