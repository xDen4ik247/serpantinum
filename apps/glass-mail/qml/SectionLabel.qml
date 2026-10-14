import QtQuick

Text {
    property var app
    x: 12
    height: 28
    verticalAlignment: Text.AlignVCenter
    color: app.th.sub1
    font.family: app.th.font
    font.pixelSize: 12
    font.weight: Font.DemiBold
    font.letterSpacing: 0.6
    font.capitalization: Font.AllUppercase
}
