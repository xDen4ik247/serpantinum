import QtQuick

// Full-card screens: welcome (placement intro), grammar intro cards, placement result, loading.
Item {
    id: root
    property var theme
    property var app
    readonly property bool ru: app.ru()
    readonly property var c: app.card

    Glass {
        id: panel
        theme: root.theme
        anchors.centerIn: parent
        width: Math.min(parent.width, 760)
        height: Math.min(parent.height, content.implicitHeight + 72)
        radius: 22
        tintAlpha: 0.30
        visible: app.state !== "loading"
        scale: visible ? 1 : 0.96
        Behavior on scale { NumberAnimation { duration: 420; easing.type: Easing.OutQuint } }

        Column {
            id: content
            anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter; margins: 40 }
            spacing: 14

            // ---------- welcome
            Text {
                visible: app.state === "welcome"
                width: parent.width
                text: "日本語クイズ"
                horizontalAlignment: Text.AlignHCenter
                color: theme.text
                font { family: theme.jp; pixelSize: 44; weight: Font.Bold }
            }
            Text {
                visible: app.state === "welcome"
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.WordWrap
                text: root.ru
                    ? "Частицы, грамматика, предложения и кандзи в контексте — бесконечно и под ваш уровень.\nСначала 12 быстрых вопросов, чтобы найти ваш уровень (N5 → N3)."
                    : "Particles, grammar, sentences and kanji in context — endless, and matched to your level.\nFirst, 12 quick questions find your level (N5 → N3)."
                color: theme.subtext0
                font { family: theme.font; pixelSize: 17 }
                lineHeight: 1.25
            }

            // ---------- grammar intro
            Row {
                visible: app.state === "intro" && root.c && root.c.type === "intro"
                anchors.horizontalCenter: parent.horizontalCenter
                spacing: 10
                Text { text: ""; color: theme.accent2; font { family: theme.icons; pixelSize: 20 } anchors.verticalCenter: parent.verticalCenter }
                Text {
                    text: (root.ru ? "Новая грамматика · N" : "New grammar · N") + (root.c && root.c.level ? root.c.level : "")
                    color: theme.accent2
                    font { family: theme.font; pixelSize: 15; weight: Font.Bold; letterSpacing: 0.6 }
                    anchors.verticalCenter: parent.verticalCenter
                }
            }
            Text {
                visible: app.state === "intro" && root.c && root.c.type === "intro"
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                text: root.c && root.c.name ? root.c.name : ""
                color: theme.text
                font { family: theme.jp; pixelSize: 40; weight: Font.Bold }
            }
            Text {
                visible: app.state === "intro" && root.c && root.c.type === "intro"
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                text: root.c ? (root.ru ? root.c.ru : root.c.en) || "" : ""
                color: theme.accent
                font { family: theme.font; pixelSize: 20; weight: Font.DemiBold }
            }
            Text {
                visible: app.state === "intro" && root.c && root.c.type === "intro"
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.WordWrap
                text: root.c ? (root.ru ? root.c.explain_ru : root.c.explain_en) || "" : ""
                color: theme.subtext0
                font { family: theme.font; pixelSize: 16 }
                lineHeight: 1.2
            }
            Rectangle {
                visible: app.state === "intro" && !!root.c && !!root.c.example
                width: parent.width
                height: exCol.implicitHeight + 24
                radius: 14
                color: theme.alpha(theme.text, 0.05)
                border.color: theme.alpha(theme.text, 0.10)
                Column {
                    id: exCol
                    anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter; margins: 16 }
                    spacing: 4
                    Text {
                        width: parent.width; horizontalAlignment: Text.AlignHCenter; wrapMode: Text.WordWrap
                        text: root.c && root.c.example ? root.c.example.ja : ""
                        color: theme.text
                        font { family: theme.jp; pixelSize: 22 }
                    }
                    Text {
                        width: parent.width; horizontalAlignment: Text.AlignHCenter; wrapMode: Text.WordWrap
                        text: root.c && root.c.example ? ((root.ru && root.c.example.ru) ? root.c.example.ru : root.c.example.en) : ""
                        color: theme.subtext1
                        font { family: theme.font; pixelSize: 14; italic: true }
                    }
                }
            }

            // ---------- placement result
            Text {
                visible: app.state === "intro" && root.c && root.c.type === "placement"
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                text: root.ru ? "Ваш уровень" : "Your level"
                color: theme.subtext0
                font { family: theme.font; pixelSize: 17; weight: Font.Medium }
            }
            Text {
                visible: app.state === "intro" && root.c && root.c.type === "placement"
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                text: root.c && root.c.rank ? root.c.rank + "  ·  " + root.c.rating : ""
                color: theme.accent
                font { family: theme.font; pixelSize: 46; weight: Font.Bold }
            }
            Column {
                visible: app.state === "intro" && root.c && root.c.type === "placement"
                width: parent.width
                spacing: 8
                Repeater {
                    model: root.c && root.c.cats ? root.c.cats : []
                    delegate: Row {
                        spacing: 12
                        anchors.horizontalCenter: parent.horizontalCenter
                        Text { width: 120; text: app.tr(modelData.name); color: theme.subtext0; horizontalAlignment: Text.AlignRight; font { family: theme.font; pixelSize: 14 } }
                        Rectangle {
                            width: 300; height: 8; radius: 4; anchors.verticalCenter: parent.verticalCenter
                            color: theme.alpha(theme.text, 0.08)
                            Rectangle {
                                height: 8; radius: 4
                                width: parent.width * Math.max(0.03, Math.min(1, (modelData.rating - 1150) / 900))
                                color: theme.accent
                            }
                        }
                        Text { text: modelData.rating; color: theme.text; font { family: theme.font; pixelSize: 14; weight: Font.DemiBold } }
                    }
                }
            }

            Text {
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                text: root.ru ? "Enter — продолжить" : "Press Enter to continue"
                color: theme.alpha(theme.accent, 0.9)
                font { family: theme.font; pixelSize: 14; weight: Font.DemiBold }
                topPadding: 8
                SequentialAnimation on opacity {
                    loops: Animation.Infinite
                    running: app.state === "welcome" || app.state === "intro"
                    NumberAnimation { to: 0.45; duration: 900; easing.type: Easing.InOutSine }
                    NumberAnimation { to: 1.0; duration: 900; easing.type: Easing.InOutSine }
                }
            }
        }
    }

    // loading dots
    Row {
        anchors.centerIn: parent
        spacing: 10
        visible: app.state === "loading"
        Repeater {
            model: 3
            delegate: Rectangle {
                width: 10; height: 10; radius: 5
                color: theme.accent
                SequentialAnimation on opacity {
                    loops: Animation.Infinite
                    PauseAnimation { duration: index * 140 }
                    NumberAnimation { to: 0.2; duration: 420 }
                    NumberAnimation { to: 1; duration: 420 }
                }
            }
        }
    }
}
