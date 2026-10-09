import QtQuick

// Top bar: rank + rating (with animated delta) · combo/streak · level/XP · daily goal + day streak.
Item {
    id: hud
    property var theme
    property var app

    Glass {
        theme: hud.theme
        anchors.fill: parent
        radius: height / 2
        tintAlpha: 0.30
    }

    Row {
        id: left
        anchors { left: parent.left; leftMargin: 8; verticalCenter: parent.verticalCenter }
        spacing: 12
        Rectangle {
            width: rankText.implicitWidth + 26; height: 34; radius: 17
            color: theme.alpha(theme.accent, 0.20)
            border.color: theme.alpha(theme.accent, 0.45)
            Text {
                id: rankText
                anchors.centerIn: parent
                text: app.rank || "…"
                color: theme.accent
                font { family: theme.font; pixelSize: 16; weight: Font.Bold }
            }
        }
        Column {
            anchors.verticalCenter: parent.verticalCenter
            spacing: -2
            Row {
                spacing: 8
                Text {
                    id: ratingText
                    property real shown: app.rating
                    Behavior on shown { NumberAnimation { duration: 700; easing.type: Easing.OutCubic } }
                    text: Math.round(shown)
                    color: theme.text
                    font { family: theme.font; pixelSize: 20; weight: Font.DemiBold; features: { "tnum": 1 } }
                }
                Text {
                    id: deltaText
                    anchors.baseline: ratingText.baseline
                    text: app.ratingDelta > 0 ? "+" + app.ratingDelta : (app.ratingDelta < 0 ? "" + app.ratingDelta : "")
                    color: app.ratingDelta >= 0 ? theme.good : theme.bad
                    font { family: theme.font; pixelSize: 14; weight: Font.DemiBold }
                    opacity: 0
                    Connections {
                        target: app
                        function onResChanged() { if (app.res) deltaAnim.restart() }
                    }
                    SequentialAnimation {
                        id: deltaAnim
                        NumberAnimation { target: deltaText; property: "opacity"; from: 0; to: 1; duration: 180 }
                        PauseAnimation { duration: 1400 }
                        NumberAnimation { target: deltaText; property: "opacity"; to: 0; duration: 600 }
                    }
                }
            }
            Text {
                text: app.ru() ? "рейтинг" : "rating"
                color: theme.subtext1
                font { family: theme.font; pixelSize: 11; letterSpacing: 0.6 }
            }
        }
    }

    // combo / streak in the middle
    Row {
        anchors.centerIn: parent
        spacing: 10
        opacity: app.streak > 0 ? 1 : 0.45
        Behavior on opacity { NumberAnimation { duration: 300 } }
        Text {
            text: ""
            color: app.streak >= 3 ? theme.gold : theme.subtext1
            font { family: theme.icons; pixelSize: 20 }
            anchors.verticalCenter: parent.verticalCenter
        }
        Text {
            id: streakText
            text: app.streak + (app.ru() ? " подряд" : " streak")
            color: theme.text
            font { family: theme.font; pixelSize: 16; weight: Font.DemiBold }
            anchors.verticalCenter: parent.verticalCenter
        }
        Rectangle {
            id: comboChip
            visible: app.combo > 1
            width: comboText.implicitWidth + 18; height: 26; radius: 13
            anchors.verticalCenter: parent.verticalCenter
            color: theme.alpha(theme.gold, 0.18)
            border.color: theme.alpha(theme.gold, 0.5)
            Text {
                id: comboText
                anchors.centerIn: parent
                text: "×" + app.combo.toFixed(2).replace(/0$/, "").replace(/\.0$/, "")
                color: theme.gold
                font { family: theme.font; pixelSize: 14; weight: Font.Bold }
            }
            Connections {
                target: app
                function onComboChanged() { if (app.combo > 1) comboPop.restart() }
            }
            NumberAnimation { id: comboPop; target: comboChip; property: "scale"; from: 1.45; to: 1; duration: 520; easing.type: Easing.OutBack }
        }
    }

    Row {
        anchors { right: parent.right; rightMargin: 16; verticalCenter: parent.verticalCenter }
        spacing: 18
        // level + xp bar
        Column {
            anchors.verticalCenter: parent.verticalCenter
            spacing: 4
            Text {
                text: (app.ru() ? "Ур. " : "Lv ") + app.level.level + "  ·  " + app.level.xp + " XP"
                color: theme.subtext0
                font { family: theme.font; pixelSize: 13; weight: Font.DemiBold; features: { "tnum": 1 } }
            }
            Rectangle {
                width: 150; height: 6; radius: 3
                color: theme.alpha(theme.text, 0.10)
                Rectangle {
                    height: parent.height; radius: 3
                    width: parent.width * Math.min(1, app.level.into / Math.max(1, app.level.need))
                    color: theme.accent
                    Behavior on width { NumberAnimation { duration: 600; easing.type: Easing.OutQuint } }
                }
            }
        }
        // daily goal ring
        Item {
            width: 38; height: 38
            anchors.verticalCenter: parent.verticalCenter
            Canvas {
                id: ring
                anchors.fill: parent
                property real frac: Math.min(1, app.today.n / Math.max(1, app.today.goal))
                Behavior on frac { NumberAnimation { duration: 600; easing.type: Easing.OutCubic } }
                onFracChanged: requestPaint()
                onPaint: {
                    const ctx = getContext("2d");
                    ctx.reset();
                    ctx.lineWidth = 3.5;
                    ctx.lineCap = "round";
                    ctx.strokeStyle = Qt.rgba(1, 1, 1, 0.12);
                    ctx.beginPath(); ctx.arc(19, 19, 15, 0, Math.PI * 2); ctx.stroke();
                    ctx.strokeStyle = frac >= 1 ? theme.good : theme.accent2;
                    ctx.beginPath(); ctx.arc(19, 19, 15, -Math.PI / 2, -Math.PI / 2 + Math.PI * 2 * Math.max(0.001, frac)); ctx.stroke();
                }
            }
            Text {
                anchors.centerIn: parent
                text: app.today.n
                color: theme.text
                font { family: theme.font; pixelSize: 12; weight: Font.Bold }
            }
        }
        Row {
            spacing: 5
            anchors.verticalCenter: parent.verticalCenter
            Text { text: ""; color: theme.accent2; font { family: theme.icons; pixelSize: 15 } anchors.verticalCenter: parent.verticalCenter }
            Text {
                text: app.today.streak_days + (app.ru() ? " дн." : (app.today.streak_days === 1 ? " day" : " days"))
                color: theme.subtext0
                font { family: theme.font; pixelSize: 13; weight: Font.DemiBold }
                anchors.verticalCenter: parent.verticalCenter
            }
        }
    }
}
