import QtQuick

// One answer option: number badge + text on a glass tile; bounces when right, shakes when wrong.
Item {
    id: b
    property var theme
    property int index_: 0
    property string label: ""
    property bool jp: true
    property bool small: false
    property string state_: "idle"      // idle pressed right reveal wrong dim
    signal clicked()

    readonly property color tone: state_ === "right" || state_ === "reveal" ? theme.good : (state_ === "wrong" ? theme.bad : theme.accent)
    opacity: state_ === "dim" ? 0.42 : 1
    Behavior on opacity { NumberAnimation { duration: 250 } }

    transform: Translate { id: shake; x: 0 }

    Glass {
        theme: b.theme
        anchors.fill: parent
        radius: 16
        tintAlpha: b.state_ === "idle" || b.state_ === "dim" ? 0.30 : 0.42
        tintColor: b.state_ === "idle" || b.state_ === "dim" ? theme.base : theme.mix(theme.base, b.tone, b.state_ === "pressed" ? 0.18 : 0.34)
        lit: hover.hovered || b.state_ === "right" || b.state_ === "reveal"
    }
    Rectangle {
        id: badge
        x: 14
        anchors.verticalCenter: parent.verticalCenter
        width: 28; height: 28; radius: 14
        color: theme.alpha(b.tone, 0.20)
        border.color: theme.alpha(b.tone, 0.5)
        Text {
            anchors.centerIn: parent
            text: b.state_ === "right" || b.state_ === "reveal" ? "" : (b.state_ === "wrong" ? "" : (b.index_ + 1))
            color: b.tone
            font { family: b.state_ === "right" || b.state_ === "reveal" || b.state_ === "wrong" ? theme.icons : theme.font; pixelSize: 14; weight: Font.Bold }
        }
    }
    Text {
        anchors { left: badge.right; leftMargin: 14; right: parent.right; rightMargin: 14; verticalCenter: parent.verticalCenter }
        text: b.label
        color: b.state_ === "wrong" ? theme.bad : (b.state_ === "right" || b.state_ === "reveal" ? theme.good : theme.text)
        elide: Text.ElideRight
        horizontalAlignment: b.small ? Text.AlignLeft : Text.AlignHCenter
        font { family: b.jp ? theme.jp : theme.font; pixelSize: b.small ? 18 : 24; weight: b.state_ === "right" || b.state_ === "reveal" ? Font.Bold : Font.Normal }
    }
    HoverHandler { id: hover }
    TapHandler { onTapped: b.clicked() }

    onState_Changed: {
        if (state_ === "right") bounce.restart();
        else if (state_ === "wrong") wobble.restart();
    }
    SequentialAnimation {
        id: bounce
        NumberAnimation { target: b; property: "scale"; to: 1.06; duration: 120; easing.type: Easing.OutCubic }
        NumberAnimation { target: b; property: "scale"; to: 1.0; duration: 420; easing.type: Easing.OutBack }
    }
    SequentialAnimation {
        id: wobble
        NumberAnimation { target: shake; property: "x"; to: -12; duration: 50 }
        NumberAnimation { target: shake; property: "x"; to: 10; duration: 70 }
        NumberAnimation { target: shake; property: "x"; to: -7; duration: 70 }
        NumberAnimation { target: shake; property: "x"; to: 4; duration: 70 }
        NumberAnimation { target: shake; property: "x"; to: 0; duration: 90; easing.type: Easing.OutCubic }
    }
}
