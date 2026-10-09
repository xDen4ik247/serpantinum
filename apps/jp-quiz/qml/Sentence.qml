import QtQuick

// A Japanese sentence laid out unit by unit so it can wrap anywhere,
// with optional furigana, a blank to fill, a highlighted word, or the 並べ替え slot.
Flow {
    id: s
    property var theme
    property var app
    property var segs: []
    property string fill: ""
    property bool fillGood: false
    property string blankHint: ""
    property int blankChars: 3
    property string orderText: ""
    property int pixel: 34
    spacing: 0
    property real implicitW: {
        let w = 0;
        for (let i = 0; i < rep.count; i++) {
            const it = rep.itemAt(i);
            if (it) w += it.width;
        }
        return w + 2;
    }

    function units(segs) {
        const out = [];
        for (const sg of segs || []) {
            if (sg.blank || sg.hl || sg.order || sg.r) out.push(sg);
            else for (const ch of Array.from(sg.t || "")) out.push({ t: ch });
        }
        return out;
    }

    Repeater {
        id: rep
        model: s.units(s.segs)
        delegate: Item {
            id: u
            readonly property var d: modelData
            readonly property bool isBlank: !!d.blank
            readonly property bool isHl: !!d.hl
            readonly property bool isOrder: !!d.order
            readonly property bool showRuby: !!d.r && app.settings.furigana && !isHl
            height: s.pixel * 1.85
            width: {
                if (isBlank) return Math.max(blankFill.implicitWidth + 18, s.blankChars * s.pixel * 0.92 + 18);
                if (isOrder) return Math.max(orderFill.implicitWidth + 18, s.pixel * 3.2);
                return Math.max(main.implicitWidth, showRuby ? ruby.implicitWidth : 0) + (isHl ? 6 : 0);
            }
            Behavior on width { enabled: u.isBlank || u.isOrder; NumberAnimation { duration: 260; easing.type: Easing.OutCubic } }

            Text {
                id: ruby
                visible: u.showRuby
                anchors { horizontalCenter: parent.horizontalCenter; bottom: main.top; bottomMargin: -s.pixel * 0.12 }
                text: u.d.r || ""
                color: theme.alpha(theme.subtext0, 0.85)
                font { family: theme.jp; pixelSize: Math.round(s.pixel * 0.40) }
            }
            Text {
                id: main
                visible: !u.isBlank && !u.isOrder
                anchors { horizontalCenter: parent.horizontalCenter; bottom: parent.bottom; bottomMargin: s.pixel * 0.18 }
                text: u.d.t || ""
                color: u.isHl ? theme.accent : theme.text
                font { family: theme.jp; pixelSize: s.pixel; weight: u.isHl ? Font.Bold : Font.Normal }
            }
            Rectangle {   // underline for the highlighted word
                visible: u.isHl
                anchors { left: main.left; right: main.right; top: main.bottom; topMargin: 1 }
                height: 3; radius: 1.5
                color: theme.alpha(theme.accent, 0.8)
            }
            // blank
            Rectangle {
                visible: u.isBlank
                anchors { left: parent.left; right: parent.right; bottom: parent.bottom; leftMargin: 6; rightMargin: 6; bottomMargin: s.pixel * 0.12 }
                height: s.pixel * 1.18
                radius: 10
                color: s.fill !== "" ? theme.alpha(theme.good, 0.14) : theme.alpha(theme.accent, 0.10)
                border.color: s.fill !== "" ? theme.alpha(theme.good, 0.55) : theme.alpha(theme.accent, 0.45)
                border.width: 1.5
                Behavior on color { ColorAnimation { duration: 250 } }
                Text {
                    id: blankFill
                    anchors.centerIn: parent
                    text: s.fill !== "" ? s.fill : "？"
                    color: s.fill !== "" ? theme.good : theme.alpha(theme.accent, 0.7)
                    font { family: theme.jp; pixelSize: s.pixel; weight: s.fill !== "" ? Font.Bold : Font.Normal }
                    scale: s.fill !== "" ? 1 : 0.8
                    Behavior on scale { NumberAnimation { duration: 420; easing.type: Easing.OutBack } }
                }
            }
            // 並べ替え slot
            Rectangle {
                visible: u.isOrder
                anchors { left: parent.left; right: parent.right; bottom: parent.bottom; leftMargin: 6; rightMargin: 6; bottomMargin: s.pixel * 0.12 }
                height: s.pixel * 1.18
                radius: 10
                color: s.fill !== "" ? theme.alpha(theme.good, 0.14) : theme.alpha(theme.accent, 0.08)
                border.color: s.fill !== "" ? theme.alpha(theme.good, 0.55) : theme.alpha(theme.accent, 0.4)
                border.width: 1.5
                Text {
                    id: orderFill
                    anchors.centerIn: parent
                    text: s.fill !== "" ? s.fill : (s.orderText !== "" ? s.orderText : "・・・")
                    color: s.fill !== "" ? theme.good : (s.orderText !== "" ? theme.text : theme.alpha(theme.accent, 0.6))
                    font { family: theme.jp; pixelSize: s.pixel; weight: s.fill !== "" ? Font.Bold : Font.Normal }
                }
            }
        }
    }
}
