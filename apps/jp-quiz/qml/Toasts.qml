import QtQuick

// Level-up / unlock / rank banners that slide in and fade away.
Column {
    id: root
    property var theme
    spacing: 8
    readonly property var glyphs: ({ star: "", trophy: "", unlock: "", book: "" })

    function show(icon, text, color) {
        toastModel.append({ icon: icon, msg: text, tone: color.toString() });
    }
    ListModel { id: toastModel }
    Repeater {
        model: toastModel
        delegate: Item {
            id: t
            width: row.implicitWidth + 40
            height: 44
            anchors.horizontalCenter: parent ? parent.horizontalCenter : undefined
            opacity: 0
            scale: 0.9
            readonly property color toneC: tone
            Glass {
                theme: root.theme
                anchors.fill: parent
                radius: 22
                tintAlpha: 0.88
                tintColor: theme.mix(theme.base, t.toneC, 0.22)
                lit: true
            }
            Row {
                id: row
                anchors.centerIn: parent
                spacing: 10
                Text { text: root.glyphs[icon] || ""; color: t.toneC; font { family: theme.icons; pixelSize: 18 } anchors.verticalCenter: parent.verticalCenter }
                Text { text: msg; color: theme.text; font { family: theme.font; pixelSize: 15; weight: Font.DemiBold } anchors.verticalCenter: parent.verticalCenter }
            }
            SequentialAnimation {
                running: true
                ParallelAnimation {
                    NumberAnimation { target: t; property: "opacity"; to: 1; duration: 220 }
                    NumberAnimation { target: t; property: "scale"; to: 1; duration: 420; easing.type: Easing.OutBack }
                }
                PauseAnimation { duration: 2400 }
                NumberAnimation { target: t; property: "opacity"; to: 0; duration: 500 }
                ScriptAction { script: toastModel.remove(index) }
            }
        }
    }
}
