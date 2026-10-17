import QtQuick
import QtQuick.Particles

// Question + feedback view.
Item {
    id: root
    property var theme
    property var app
    property var shell
    readonly property var q: app.q
    readonly property var ui: q ? q.ui : null
    readonly property var res: app.res
    readonly property bool answered: app.state === "feedback"
    readonly property bool longChoices: q && (q.kind === "meaning" || q.kind === "produce" || q.kind === "odd" || q.kind === "anki_mean")
    // a due card from the user's own Anki decks (setting anki_reviews); the answer goes back to Anki
    readonly property bool isAnki: !!(q && q.mode === "anki")
    readonly property bool meaningKind: !!q && (q.kind === "meaning" || q.kind === "anki_mean")
    readonly property bool ru: app.ru()

    readonly property var prompts: ({
        particle: ["Which particle fits?", "Какая частица подходит?"],
        conj: ["Choose the correct form", "Выберите правильную форму"],
        gmean: ["Which ending matches the translation?", "Какое окончание подходит по смыслу?"],
        voice: ["Active, passive, causative or potential?", "Какой залог подходит?"],
        form: ["Pick the form that matches the meaning", "Выберите форму по смыслу"],
        order: ["Put the pieces in order", "Расставьте части по порядку"],
        odd: ["Which sentence has a mistake?", "В каком предложении ошибка?"],
        kread: ["How is the highlighted word read here?", "Как здесь читается выделенное слово?"],
        kwrite: ["Which kanji spelling is right here?", "Как это пишется кандзи?"],
        vocab: ["Which word fits?", "Какое слово подходит?"],
        meaning: ["What does this mean?", "Что это значит?"],
        produce: ["How do you say this in Japanese?", "Как сказать это по-японски?"],
        anki_read: ["How is the highlighted word read?", "Как читается выделенное слово?"],
        anki_mean: ["What does the highlighted word mean?", "Что значит выделенное слово?"]
    })

    function translation() {
        if (!ui) return "";
        return (ru && ui.ru) ? ui.ru : (ui.en || "");
    }
    function choiceTexts() {
        if (!ui || !ui.choices) return [];
        if (q.kind === "meaning" && ru && ui.choices_ru) return ui.choices_ru;
        return ui.choices;
    }
    function correctIndex() { return res && typeof res.answer === "number" ? res.answer : -1 }

    // Responsive layout: the window is a normal tiled niri app now, so it can be anything from a
    // half-width column to the full screen. Spare height is shared between a taller card (bigger
    // sentence) and a top offset, so the card + answers sit balanced instead of glued to the top.
    readonly property int baseCardH: longChoices ? 236 : 300
    // after answering only the right answer (and your wrong pick) stay; the room goes to the word glosses
    readonly property int shownChoices: !answered ? choiceTexts().length : ((app.chosen >= 0 && app.chosen !== correctIndex()) ? 2 : 1)
    readonly property int answersH: !q ? 144 : (q.kind === "order" ? 150
                                      : (longChoices ? 4 * 62 - 12 : 2 * 78 - 12))
    readonly property var words: res && res.words ? res.words : []
    readonly property int fbH: 104
    readonly property int spareH: Math.max(0, height - baseCardH - 16 - answersH - fbH - 24)
    readonly property int growH: Math.min(180, Math.round(spareH * 0.45))
    readonly property int topPad: Math.min(110, Math.round((spareH - growH) * 0.3))

    // ------------------------------------------------------------------ card
    Glass {
        id: card
        theme: root.theme
        anchors { top: parent.top; topMargin: root.topPad; left: parent.left; right: parent.right }
        height: root.baseCardH + root.growH
        radius: 20
        tintAlpha: 0.28
        lit: root.answered
        Behavior on height { NumberAnimation { duration: 350; easing.type: Easing.OutQuint } }

        // header: type · level · skill · badges · matchmaking
        Row {
            id: header
            anchors { left: parent.left; top: parent.top; margins: 18 }
            spacing: 8
            Chip { theme: root.theme; text: root.q ? app.tr(root.q.kind_name) : ""; tint: theme.accent }
            Chip { theme: root.theme; visible: !root.isAnki; text: root.q ? "N" + root.q.level : ""; tint: theme.accent2 }
            Chip { theme: root.theme; visible: root.isAnki; text: (root.isAnki && root.ui && root.ui.deck) || ""; tint: theme.gold }
            Chip { theme: root.theme; visible: root.q && root.q.new; text: root.ru ? "НОВОЕ" : "NEW"; tint: theme.good }
            Chip { theme: root.theme; visible: root.q && (root.q.why === "due" || root.q.why === "relearn"); text: root.ru ? "ПОВТОР" : "REVIEW"; tint: theme.gold }
            Chip { theme: root.theme; visible: !!(root.q && root.q.focus); text: root.ru ? "ТРЕНИРОВКА" : "DRILL"; tint: theme.accent2 }
            Chip { theme: root.theme; visible: root.q && root.q.mode === "placement"; text: root.ru ? "ОПРЕДЕЛЕНИЕ УРОВНЯ" : "PLACEMENT"; tint: theme.gold }
            Text {
                anchors.verticalCenter: parent.verticalCenter
                // the skill name could give the answer away, so it only appears after answering
                text: !root.q ? "" : (root.answered && root.res && root.res.skill
                      ? app.tr(root.res.skill.label) + (root.res.skill.rating ? "  ·  " + root.res.skill.rating : "")
                      : app.tr(root.q.cat_name))
                color: theme.subtext1
                elide: Text.ElideRight
                width: Math.min(implicitWidth, card.width - header.x - 330)
                font { family: theme.font; pixelSize: 13 }
            }
        }
        Item {
            id: match
            anchors { right: parent.right; top: parent.top; margins: 18 }
            width: 210; height: 30
            visible: !!root.q && !root.isAnki
            Text {
                id: matchText
                anchors { right: parent.right; top: parent.top }
                text: root.q ? ((root.ru ? "шанс " : "match ") + Math.round(root.q.p * 100) + "%") : ""
                color: theme.text
                font { family: theme.font; pixelSize: 13; weight: Font.DemiBold }
            }
            Text {
                anchors { right: parent.right; top: matchText.bottom; topMargin: 1 }
                text: root.q ? ((root.ru ? "вы " : "you ") + root.q.your + "  ·  " + (root.ru ? "вопрос " : "item ") + root.q.item_rating) : ""
                color: theme.subtext1
                font { family: theme.font; pixelSize: 11; features: { "tnum": 1 } }
            }
        }

        // thinking-time bar: generous, pauses while stats/grammar are open; running out only trims the XP
        Rectangle {
            id: timeTrack
            anchors { left: parent.left; right: timeLabel.left; top: header.bottom; leftMargin: 18; rightMargin: 10; topMargin: 12 }
            height: 3; radius: 1.5
            color: theme.alpha(theme.text, 0.07)
            Rectangle {
                id: timeBar
                property real frac: 1
                height: parent.height; radius: 1.5
                color: frac > 0.2 ? theme.alpha(theme.gold, 0.85) : theme.alpha(theme.bad, 0.9)
                width: parent.width * frac
                Behavior on width { NumberAnimation { duration: 240; easing.type: Easing.Linear } }
            }
        }
        Text {
            id: timeLabel
            anchors { right: parent.right; rightMargin: 18; verticalCenter: timeTrack.verticalCenter }
            property int left_: 0
            text: !root.q ? "" : (left_ > 0 ? Math.floor(left_ / 60) + ":" + ("0" + left_ % 60).slice(-2)
                                             : (root.ru ? "без спешки" : "no rush"))
            color: left_ > 0 && timeBar.frac > 0.2 ? theme.subtext1 : theme.alpha(theme.bad, 0.9)
            font { family: theme.font; pixelSize: 11; features: { "tnum": 1 } }
        }
        Timer {
            interval: 200
            repeat: true
            running: root.q && (app.state === "question" || app.state === "waiting")
            triggeredOnStart: true
            onTriggered: {
                const budget = root.q.budget * 1000;
                const left = Math.max(0, budget - app.elapsed());
                timeBar.frac = budget > 0 ? left / budget : 0;
                timeLabel.left_ = Math.ceil(left / 1000);
            }
        }
        Connections {
            target: app
            function onQChanged() { if (app.q) { timeBar.frac = 1; timeLabel.left_ = app.q.budget; } }
        }

        // prompt
        Text {
            id: prompt
            anchors { top: timeTrack.bottom; topMargin: 14; horizontalCenter: parent.horizontalCenter }
            text: {
                if (!root.q) return "";
                const p = root.prompts[root.q.kind];
                let s = p ? (root.ru ? p[1] : p[0]) : "";
                if (root.q.kind === "conj" && root.ui.dict) s += "  ·  " + root.ui.dict;
                return s;
            }
            color: theme.subtext0
            font { family: theme.font; pixelSize: 15; weight: Font.Medium }
        }

        // the sentence (or the English prompt for "produce")
        Item {
            id: stage
            anchors { top: prompt.bottom; left: parent.left; right: parent.right; bottom: transl.top; margins: 22; topMargin: 6; bottomMargin: 6 }
            Sentence {
                id: sentence
                theme: root.theme
                app: root.app
                anchors.centerIn: parent
                width: Math.min(parent.width, implicitW)
                visible: root.q && root.q.kind !== "produce" && root.q.kind !== "odd"
                segs: {
                    if (!root.ui) return [];
                    if (root.q.kind === "order") return root.ui.prefix.concat([{ order: true }]).concat(root.ui.suffix);
                    return root.ui.sent || [];
                }
                fill: root.answered ? (root.q.kind === "order" ? (root.res.answer || []).join("") : (root.choiceTexts()[root.correctIndex()] || "")) : ""
                fillGood: root.answered
                blankHint: root.q && root.q.kind === "conj" ? "" : ""
                blankChars: {
                    if (!root.ui || !root.ui.choices) return 3;
                    let m = 2;
                    for (const c of root.ui.choices) m = Math.max(m, c.length);
                    return m;
                }
                orderText: root.q && root.q.kind === "order" ? app.orderPicked.map(i => root.ui.tiles[i]).join("") : ""
                pixel: {
                    const n = root.ui && root.ui.full ? root.ui.full.length : 12;
                    const base = n <= 16 ? 36 : (n <= 24 ? 31 : 27);
                    return base + (root.growH > 120 ? 6 : (root.growH > 60 ? 3 : 0));
                }
            }
            Text {
                anchors.centerIn: parent
                width: parent.width
                visible: root.q && root.q.kind === "produce"
                text: root.translation()
                wrapMode: Text.WordWrap
                horizontalAlignment: Text.AlignHCenter
                color: theme.text
                font { family: theme.font; pixelSize: 26; weight: Font.Medium }
            }
            Text {
                anchors.centerIn: parent
                visible: root.q && root.q.kind === "odd"
                text: root.ru ? "Одно предложение содержит ошибку спряжения." : "One sentence has a conjugation mistake."
                color: theme.subtext1
                font { family: theme.font; pixelSize: 17 }
            }
        }

        Text {
            id: transl
            anchors { bottom: parent.bottom; left: parent.left; right: parent.right; margins: 20; bottomMargin: 16 }
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
            maximumLineCount: 2
            elide: Text.ElideRight
            visible: root.q && !root.meaningKind && root.q.kind !== "produce" && root.q.kind !== "odd"
            text: root.translation()
            color: theme.alpha(theme.subtext0, 0.92)
            font { family: theme.font; pixelSize: 16; italic: true }
        }
    }

    // ------------------------------------------------------------------ choices
    Grid {
        id: choices
        anchors { top: card.bottom; topMargin: 16; horizontalCenter: parent.horizontalCenter }
        visible: root.q && root.q.kind !== "order"
        columns: root.longChoices ? 1 : 2
        spacing: 12
        Repeater {
            model: root.choiceTexts()
            delegate: ChoiceButton {
                theme: root.theme
                visible: !root.answered || state_ !== "dim"
                width: root.longChoices ? root.width : (root.width - 12) / 2
                height: root.longChoices ? 50 : 66
                index_: index
                label: modelData
                jp: root.q && !root.meaningKind
                small: root.longChoices
                state_: {
                    if (!root.answered) return (app.chosen === index && app.state === "waiting") ? "pressed" : "idle";
                    if (index === root.correctIndex()) return app.chosen === index ? "right" : "reveal";
                    if (index === app.chosen) return "wrong";
                    return "dim";
                }
                onClicked: app.answer(index)
            }
        }
    }

    // ------------------------------------------------------------------ order tiles
    Flow {
        id: tiles
        anchors { top: card.bottom; topMargin: 22; horizontalCenter: parent.horizontalCenter }
        width: Math.min(root.width, implicitW)
        property real implicitW: {
            let w = 0;
            for (let i = 0; i < tileRep.count; i++) w += tileRep.itemAt(i) ? tileRep.itemAt(i).width + 12 : 0;
            return w;
        }
        visible: root.q && root.q.kind === "order"
        spacing: 12
        Repeater {
            id: tileRep
            model: root.q && root.ui && root.q.kind === "order" ? root.ui.tiles : []
            delegate: Item {
                width: tileText.implicitWidth + 64
                height: 62
                readonly property bool used: app.orderPicked.indexOf(index) >= 0
                opacity: used ? 0.28 : 1
                scale: used ? 0.92 : 1
                Behavior on opacity { NumberAnimation { duration: 200 } }
                Behavior on scale { NumberAnimation { duration: 260; easing.type: Easing.OutBack } }
                Glass { theme: root.theme; anchors.fill: parent; radius: 16; tintAlpha: 0.30 }
                Rectangle {
                    x: 12; anchors.verticalCenter: parent.verticalCenter
                    width: 24; height: 24; radius: 12
                    color: theme.alpha(theme.accent, 0.22)
                    Text { anchors.centerIn: parent; text: index + 1; color: theme.accent; font { family: theme.font; pixelSize: 13; weight: Font.Bold } }
                }
                Text {
                    id: tileText
                    x: 46; anchors.verticalCenter: parent.verticalCenter
                    text: modelData
                    color: theme.text
                    font { family: theme.jp; pixelSize: 24 }
                }
                MouseArea { anchors.fill: parent; onClicked: app.pickTile(index) }
            }
        }
    }

    // ------------------------------------------------------------------ feedback
    Item {
        id: feedback
        anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
        // grows into the space the folded-away choices leave behind
        readonly property int visibleChoicesH: !root.q ? 0 : (root.q.kind === "order" ? 70 : (root.longChoices ? root.shownChoices * 62 - 12 : 66))
        readonly property int glossRoom: Math.max(0, root.answersH - visibleChoicesH - 14)
        height: root.fbH + (root.words.length && glossRoom > 30 ? Math.min(glossFlow.implicitHeight + 8, glossRoom) : 0)
        Behavior on height { NumberAnimation { duration: 300; easing.type: Easing.OutQuint } }
        opacity: root.answered ? 1 : 0
        visible: opacity > 0
        transform: Translate { y: root.answered ? 0 : 24; Behavior on y { NumberAnimation { duration: 420; easing.type: Easing.OutQuint } } }
        Behavior on opacity { NumberAnimation { duration: 260; easing.type: Easing.OutCubic } }
        Glass {
            theme: root.theme
            anchors.fill: parent
            radius: 18
            tintAlpha: 0.30
            tintColor: root.res ? theme.mix(theme.base, root.res.correct ? theme.good : theme.bad, 0.16) : theme.base
        }
        Text {
            id: fbIcon
            anchors { left: parent.left; leftMargin: 20; top: parent.top; topMargin: 34 }
            text: root.res && root.res.correct ? "" : ""
            color: root.res && root.res.correct ? theme.good : theme.bad
            font { family: theme.icons; pixelSize: 30 }
        }
        Column {
            id: fbText
            anchors { left: fbIcon.right; leftMargin: 18; right: ankiBtn.left; rightMargin: 14; top: parent.top; topMargin: 18 }
            spacing: 5
            Text {
                width: parent.width
                text: {
                    if (!root.res) return "";
                    if (root.res.correct) {
                        let s = (root.ru ? "Верно!" : "Correct!") + "  +" + root.res.points + " XP";
                        if (root.res.combo > 1) s += "  ·  ×" + root.res.combo + " combo";
                        if (root.res.overtime) s += root.ru ? "  ·  дольше лимита (−40% XP)" : "  ·  over the time (−40% XP)";
                        return s;
                    }
                    return root.res.skipped ? (root.ru ? "Пропущено" : "Skipped") : (root.ru ? "Не совсем" : "Not quite");
                }
                color: root.res && root.res.correct ? theme.good : theme.bad
                font { family: theme.font; pixelSize: 16; weight: Font.Bold }
            }
            Text {
                width: parent.width
                text: root.res ? (root.ru && root.res.explain_ru ? root.res.explain_ru : root.res.explain) : ""
                visible: text !== ""
                color: theme.text
                wrapMode: Text.WordWrap
                maximumLineCount: 2
                elide: Text.ElideRight
                font { family: theme.font; pixelSize: 14 }
            }
            Text {
                width: parent.width
                text: {
                    if (!root.res) return "";
                    const full = root.res.fixed || root.res.full || "";
                    const tr = (root.ru && root.res.ru) ? root.res.ru : (root.res.en || "");
                    if (root.q && root.q.kind === "anki_mean") return tr ? full + "   —   " + tr : full;
                    return root.q && (root.q.kind === "meaning" || root.q.kind === "produce") ? full + "   —   " + tr : full;
                }
                visible: text !== ""
                color: theme.subtext0
                elide: Text.ElideRight
                font { family: theme.jp; pixelSize: 15 }
            }
        }

        // add to Anki — right or wrong (A; during the next question A adds the one you just passed).
        // On an Anki review it shows what went back to Anki instead: Pass / Fail / waiting for Anki.
        Rectangle {
            id: ankiBtn
            anchors { right: parent.right; rightMargin: 16; top: parent.top; topMargin: 16 }
            readonly property var review: root.res && root.res.anki ? root.res.anki : null
            readonly property bool done: !!(root.res && root.res.in_anki) && !(review && review.status !== "sent")
            readonly property color tint: !review ? (done ? theme.good : theme.accent)
                                        : (review.status === "sent" ? (review.ease === 3 ? theme.good : theme.bad) : theme.gold)
            width: ankiRow.implicitWidth + 22; height: 32; radius: 16
            color: (done || review) ? theme.alpha(tint, 0.16) : (ankiMouse.containsMouse ? theme.alpha(theme.accent, 0.26) : theme.alpha(theme.accent, 0.14))
            border.color: theme.alpha(tint, (done || review) ? 0.45 : 0.40)
            Row {
                id: ankiRow
                anchors.centerIn: parent
                spacing: 6
                Text { text: ankiBtn.done ? "" : ""; color: ankiBtn.tint; font { family: theme.icons; pixelSize: 13 } anchors.verticalCenter: parent.verticalCenter }
                Text {
                    text: {
                        const r = ankiBtn.review;
                        if (r) {
                            if (r.status === "skipped") return root.ru ? "Anki · без оценки" : "Anki · not graded";
                            if (r.status === "queued") return root.ru ? "Anki · ждёт Anki" : "Anki · waiting for Anki";
                            return r.ease === 3 ? (root.ru ? "Anki · зачёт" : "Anki · Pass") : (root.ru ? "Anki · незачёт" : "Anki · Fail");
                        }
                        return ankiBtn.done ? (root.ru ? "в Anki" : "in Anki") : (root.ru ? "A · в Anki" : "A · Anki");
                    }
                    color: ankiBtn.tint
                    font { family: theme.font; pixelSize: 12; weight: Font.DemiBold }
                    anchors.verticalCenter: parent.verticalCenter
                }
            }
            MouseArea { id: ankiMouse; anchors.fill: parent; enabled: !ankiBtn.review; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: app.ankiAdd() }
        }

        // dictionary glosses of the sentence's words, each in the sense it has in *this* sentence (JMdict)
        Flow {
            id: glossFlow
            anchors { left: parent.left; right: parent.right; top: parent.top; topMargin: root.fbH - 8; leftMargin: 20; rightMargin: 20 }
            height: Math.max(0, feedback.height - root.fbH)
            clip: true
            spacing: 6
            visible: root.words.length > 0
            Repeater {
                model: root.words
                delegate: Rectangle {
                    id: chipW
                    readonly property bool expr: !!modelData.x
                    readonly property string meaning: (root.ru && modelData.gr) ? modelData.gr : modelData.g
                    width: Math.min(glossFlow.width, wHead.implicitWidth + wMean.implicitWidth + 24)
                    height: 26; radius: 9
                    color: theme.alpha(expr ? theme.accent2 : theme.text, expr ? 0.14 : 0.06)
                    border.color: theme.alpha(expr ? theme.accent2 : theme.text, expr ? 0.35 : 0.10)
                    Text {
                        id: wHead
                        x: 9; anchors.verticalCenter: parent.verticalCenter
                        text: modelData.w + (modelData.r ? "【" + modelData.r + "】" : "")
                        color: theme.text
                        font { family: theme.jp; pixelSize: 13 }
                    }
                    Text {
                        id: wMean
                        anchors { left: wHead.right; leftMargin: 6; verticalCenter: parent.verticalCenter }
                        width: Math.max(0, Math.min(implicitWidth, chipW.width - wHead.implicitWidth - 24))
                        text: chipW.meaning
                        elide: Text.ElideRight
                        color: theme.subtext0
                        font { family: theme.font; pixelSize: 12 }
                    }
                }
            }
        }
    }

    // ------------------------------------------------------------------ juice: particles + floating points
    ParticleSystem { id: sparks; anchors.fill: parent }
    ImageParticle {
        system: sparks
        source: "qrc:///particleresources/glowdot.png"
        color: theme.gold
        colorVariation: 0.25
        alpha: 0.9
        entryEffect: ImageParticle.Scale
    }
    Emitter {
        id: burst
        system: sparks
        enabled: false
        lifeSpan: 700
        lifeSpanVariation: 250
        size: 14
        sizeVariation: 8
        endSize: 2
        velocity: AngleDirection { angleVariation: 360; magnitude: 260; magnitudeVariation: 140 }
        acceleration: PointDirection { y: 380 }
        width: 40; height: 20
    }
    Text {
        id: floatPts
        opacity: 0
        color: theme.gold
        font { family: theme.font; pixelSize: 26; weight: Font.Black }
        style: Text.Raised
        styleColor: Qt.rgba(0, 0, 0, 0.35)
    }
    ParallelAnimation {
        id: floatAnim
        NumberAnimation { target: floatPts; property: "y"; from: floatPts.y; to: floatPts.y - 70; duration: 1000; easing.type: Easing.OutCubic }
        SequentialAnimation {
            NumberAnimation { target: floatPts; property: "opacity"; from: 0; to: 1; duration: 140 }
            PauseAnimation { duration: 450 }
            NumberAnimation { target: floatPts; property: "opacity"; to: 0; duration: 400 }
        }
        NumberAnimation { target: floatPts; property: "scale"; from: 1.5; to: 1; duration: 500; easing.type: Easing.OutBack }
    }
    Connections {
        target: app
        function onResChanged() {
            if (!app.res || !app.res.correct) return;
            let cx = root.width / 2, cy = card.y + card.height + 60;
            if (app.q && app.q.kind !== "order" && app.chosen >= 0 && choices.children[app.chosen]) {
                const b = choices.children[app.chosen];
                const p = b.mapToItem(root, b.width / 2, b.height / 2);
                cx = p.x; cy = p.y;
            }
            burst.x = cx - 20; burst.y = cy - 10;
            burst.burst(app.res.combo > 1.4 ? 70 : 42);
            floatPts.text = "+" + app.res.points;
            floatPts.x = cx - floatPts.implicitWidth / 2;
            floatPts.y = cy - 46;
            floatAnim.restart();
        }
    }

    // ------------------------------------------------------------------ inline components
    component Chip: Rectangle {
        id: chip
        property var theme
        property string text
        property color tint
        width: chipText.implicitWidth + 18
        height: 24
        radius: 12
        color: theme.alpha(tint, 0.16)
        border.color: theme.alpha(tint, 0.38)
        Text {
            id: chipText
            anchors.centerIn: parent
            text: chip.text
            color: chip.tint
            font { family: chip.theme.font; pixelSize: 11; weight: Font.Bold; letterSpacing: 0.5 }
        }
    }
}
