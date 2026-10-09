import QtQuick

// Text that underlines on hover and navigates on click.
Text {
    id: l
    property var app
    readonly property bool hovered: hh.hovered
    signal clicked()
    elide: Text.ElideRight
    font.family: app.th.font
    font.underline: hh.hovered
    color: app.th.sub0
    HoverHandler { id: hh; cursorShape: Qt.PointingHandCursor }
    TapHandler { onTapped: l.clicked() }
}
