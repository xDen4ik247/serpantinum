import QtQuick

// Pill search box (Ctrl+F). Esc clears, then hands focus back to the window.
Rectangle {
    id: sf
    property var app
    height: 44
    radius: 22
    color: app.th.alpha(app.th.text, input.activeFocus ? 0.13 : (hover.hovered ? 0.10 : 0.075))
    border.width: input.activeFocus ? 1.5 : 1
    border.color: app.th.alpha(input.activeFocus ? app.th.text : "white", input.activeFocus ? 0.55 : 0.08)
    Behavior on color { ColorAnimation { duration: 160 } }
    HoverHandler { id: hover; cursorShape: Qt.IBeamCursor }

    Icon { id: ic; app: sf.app; name: "search"; size: 22; color: sf.app.th.sub0; x: 14; anchors.verticalCenter: parent.verticalCenter }
    TextInput {
        id: input
        anchors { left: ic.right; leftMargin: 10; right: clear.left; rightMargin: 6; verticalCenter: parent.verticalCenter }
        color: sf.app.th.text
        font.family: sf.app.th.font
        font.pixelSize: 15
        selectionColor: sf.app.th.alpha(sf.app.th.accent, 0.5)
        clip: true
        text: sf.app.searchText
        onTextEdited: sf.app.search(text)
        Keys.onEscapePressed: { if (text !== "") { text = ""; sf.app.search(""); } else sf.app.rootItem.forceActiveFocus(); }
        Keys.onDownPressed: sf.app.rootItem.forceActiveFocus()
        Text {
            anchors.verticalCenter: parent.verticalCenter
            visible: input.text === ""
            text: "What do you want to play?"
            color: sf.app.th.sub1
            font: input.font
        }
    }
    IconButton {
        id: clear
        app: sf.app; icon: "close"; size: 30; iconSize: 18
        anchors { right: parent.right; rightMargin: 8; verticalCenter: parent.verticalCenter }
        visible: input.text !== ""
        onClicked: { input.text = ""; sf.app.search(""); input.forceActiveFocus(); }
    }
    MouseArea { anchors.fill: input; onPressed: m => { input.forceActiveFocus(); m.accepted = false; } }
    Connections {
        target: sf.app
        function onFocusSearch() { Qt.callLater(() => { input.forceActiveFocus(); input.selectAll(); }) }
    }
    onVisibleChanged: if (visible && sf.app.nav.page === "search") Qt.callLater(() => input.forceActiveFocus())
}
