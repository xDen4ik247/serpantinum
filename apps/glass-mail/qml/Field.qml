import QtQuick

// One-line input in a soft rounded box (account form, compose header fields).
Rectangle {
    id: f
    property var app
    property alias text: input.text
    property alias input: input
    property string placeholder: ""
    property string label: ""
    property bool password: false
    property bool flat: false               // compose header rows: no box, a hairline underneath
    signal accepted()
    signal edited()
    height: flat ? 40 : 44
    radius: flat ? 0 : 12
    color: flat ? "transparent" : app.th.alpha(app.th.text, input.activeFocus ? 0.12 : 0.07)
    border.width: flat ? 0 : 1
    border.color: app.th.alpha(input.activeFocus ? app.th.accent : "white", input.activeFocus ? 0.7 : 0.08)
    Behavior on color { ColorAnimation { duration: 160 } }
    Rectangle {
        visible: f.flat
        anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
        height: 1
        color: f.app.th.alpha(f.app.th.text, input.activeFocus ? 0.22 : 0.08)
    }
    Text {
        id: lab
        visible: f.label !== ""
        x: f.flat ? 2 : 14
        anchors.verticalCenter: parent.verticalCenter
        text: f.label
        color: f.app.th.sub1
        font.family: f.app.th.font
        font.pixelSize: 14
    }
    TextInput {
        id: input
        anchors { left: lab.visible ? lab.right : parent.left; leftMargin: lab.visible ? 10 : (f.flat ? 2 : 14); right: parent.right; rightMargin: f.flat ? 2 : 14; verticalCenter: parent.verticalCenter }
        color: f.app.th.text
        font.family: f.app.th.font
        font.pixelSize: 14
        selectionColor: f.app.th.alpha(f.app.th.accent, 0.5)
        selectByMouse: true
        clip: true
        echoMode: f.password ? TextInput.Password : TextInput.Normal
        onAccepted: f.accepted()
        onTextEdited: f.edited()
        Text {
            anchors.verticalCenter: parent.verticalCenter
            visible: input.text === "" && !input.preeditText
            text: f.placeholder
            color: f.app.th.sub1
            font: input.font
        }
    }
    HoverHandler { cursorShape: Qt.IBeamCursor }
    TapHandler { onTapped: input.forceActiveFocus() }
}
