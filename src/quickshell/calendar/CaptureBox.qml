import QtQuick
import "../"

// Smart capture input + live preview chips (shared by the Mod+Shift+O prompt and
// the agenda panel). Type a rough note ("dentist tmrw 3pm 1h near metro"); the
// chips show what will be created. Click a chip to edit it, hover × to drop it,
// click Task/Event to switch, the flag to cycle priority. Enter commits.
FocusScope {
    id: box

    property real fs: 14                    // base font size
    property bool large: false              // prompt (true) vs panel footer (false)
    property bool busy: Gcal.captureBusy
    property alias input: input
    signal escaped()

    implicitHeight: col.implicitHeight
    readonly property var it: Gcal.preview
    readonly property bool hasPreview: !!it && input.text.trim() !== ""

    function submit() { if (input.text.trim() !== "") Gcal.commitCapture(); }

    Connections {
        target: Gcal
        function onCaptured(ok, message) { if (ok) input.text = ""; }
        function onCaptureTextChanged() { if (Gcal.captureText !== input.text) input.text = Gcal.captureText; }
    }

    Column {
        id: col
        width: box.width
        spacing: box.large ? 10 : 8

        // ── input ──
        Rectangle {
            id: field
            width: parent.width
            height: box.large ? 0 : 40
            visible: !box.large
            radius: 20
            color: Qt.rgba(ThemeBackend.text.r, ThemeBackend.text.g, ThemeBackend.text.b, input.activeFocus ? 0.12 : 0.07)
            border.width: 1
            border.color: input.activeFocus ? Qt.rgba(ThemeBackend.mauve.r, ThemeBackend.mauve.g, ThemeBackend.mauve.b, 0.55) : Qt.rgba(1, 1, 1, 0.08)
            Behavior on color { ColorAnimation { duration: 180 } }
            Behavior on border.color { ColorAnimation { duration: 180 } }
        }
        Item {
            width: parent.width
            height: box.large ? 40 : 0
            visible: box.large
        }

        // ── preview chips ──
        Flow {
            id: chips
            width: parent.width
            spacing: 6
            visible: box.hasPreview
            opacity: box.hasPreview ? 1 : 0
            Behavior on opacity { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }

            // Task / Event switch
            Chip {
                glyph: box.it && box.it.kind === "event" ? 0xF00F0 : 0xF0130
                label: box.it && box.it.kind === "event" ? "Event" : "Task"
                accent: box.it && box.it.kind === "event" ? ThemeBackend.blue : ThemeBackend.green
                strong: true
                removable: false
                onActivated: Gcal.editField("kind", box.it.kind === "event" ? "task" : "event")
            }
            Chip { field: "title"; glyph: 0xF09A9; label: box.it ? box.it.title : ""; removable: false; maxW: chips.width * 0.55 }
            Chip { field: "date"; glyph: 0xF00EE; label: box.it && box.it.date ? (box.it.kind === "task" ? "due " : "") + Gcal.prettyDate(box.it.date) : ""; editText: box.it ? (box.it.date || "") : "" }
            Chip {
                field: "time"; glyph: 0xF0150
                label: box.it && box.it.time ? box.it.time + (box.it.kind === "event" && box.it.duration ? "–" + Gcal.endOf(box.it) : "") : ""
                editText: box.it ? (box.it.time || "") : ""
            }
            Chip { field: "duration"; glyph: 0xF051F; label: box.it && box.it.kind === "event" && box.it.time ? Gcal.prettyDuration(box.it.duration) : "" }
            Chip { field: "location"; glyph: 0xF07D9; label: box.it && box.it.location ? box.it.location : ""; maxW: chips.width * 0.5 }
            Chip { field: "recurrence"; glyph: 0xF0456; label: box.it && box.it.recurrence ? box.it.recurrence.text : "" }
            Chip {
                field: "priority"; glyph: 0xF140B
                label: box.it && box.it.priority ? box.it.priority : ""
                accent: box.it && (box.it.priority === "high" || box.it.priority === "highest") ? ThemeBackend.red : ThemeBackend.peach
                editable: false
                onActivated: {
                    let order = ["high", "medium", "low", ""];
                    Gcal.editField("priority", order[(order.indexOf(box.it.priority || "") + 1) % order.length]);
                }
            }
            Chip { field: "tags"; glyph: 0xF04FC; label: box.it && box.it.tags && box.it.tags.length ? box.it.tags.join(" ") : ""; editText: label }
            Chip { field: "reminder"; glyph: 0xF009C; label: box.it && box.it.reminder ? (box.it.reminder.date !== box.it.date ? Gcal.prettyDate(box.it.reminder.date) + " " : "") + box.it.reminder.time : ""; editText: "" }

            // add a missing field
            Chip {
                id: addChip
                glyph: 0xF0415
                label: ""
                removable: false
                editable: false
                visible: missing.length > 0
                readonly property var missing: {
                    let it = box.it, out = [];
                    if (!it) return out;
                    if (!it.time) out.push(["time", "time"]);
                    if (!it.location) out.push(["location", "place"]);
                    if (!it.recurrence) out.push(["recurrence", "repeat"]);
                    if (!it.priority) out.push(["priority", "priority"]);
                    if (!it.tags || !it.tags.length) out.push(["tags", "tag"]);
                    if (!it.reminder) out.push(["reminder", "remind"]);
                    return out;
                }
                onActivated: addMenu.visible = !addMenu.visible
            }
            Repeater {
                model: addMenu.visible ? addChip.missing : []
                delegate: Chip {
                    required property var modelData
                    glyph: 0
                    label: "+ " + modelData[1]
                    removable: false
                    editable: false
                    subtle: true
                    onActivated: {
                        addMenu.visible = false;
                        if (modelData[0] === "priority") Gcal.editField("priority", "high");
                        else box.startEdit(modelData[0], "");
                    }
                }
            }
            Item { id: addMenu; visible: false; width: 0; height: 0 }
        }

        // ── parser line ──
        Row {
            visible: box.hasPreview || Gcal.llmState === "pending" || Gcal.llmState === "loading"
            spacing: 6
            height: 16
            Text {
                id: spark
                anchors.verticalCenter: parent.verticalCenter
                text: String.fromCodePoint(0xF0674)
                color: box.it && box.it.parser === "llm" ? ThemeBackend.mauve : ThemeBackend.subtext0
                font.family: ThemeBackend.iconFont
                font.pixelSize: 13
                SequentialAnimation on opacity {
                    running: Gcal.llmState === "pending" || Gcal.llmState === "loading"
                    loops: Animation.Infinite
                    NumberAnimation { to: 0.3; duration: 500; easing.type: Easing.InOutSine }
                    NumberAnimation { to: 1; duration: 500; easing.type: Easing.InOutSine }
                    onRunningChanged: if (!running) spark.opacity = 1
                }
            }
            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: {
                    let it = box.it;
                    let who = it && it.parser === "llm" ? "Parsed by local AI" + (it.ms ? " · " + (it.ms / 1000).toFixed(1) + " s" : "") : "Quick rules";
                    if (Gcal.llmState === "pending") who += " · AI is thinking…";
                    else if (Gcal.llmState === "loading") who += " · AI loading…";
                    else if (Gcal.llmState === "offline") who += " · AI offline";
                    else if (Gcal.llmState === "failed") who += " · AI failed";
                    let where = it && it.kind === "event" ? (Gcal.writeEnabled ? "→ Google Calendar" : "→ local calendar + note")
                                                         : "→ " + (Gcal.obsidian.inbox ? Gcal.obsidian.inbox.replace(/\.md$/, "") : "today's note");
                    return who + "   " + where + "   ·   ↵ to add";
                }
                color: ThemeBackend.subtext0
                opacity: 0.75
                font.family: ThemeBackend.fontFamily
                font.pixelSize: 11
            }
        }
    }

    // the text input sits over the field (or on the large prompt's first row)
    TextInput {
        id: input
        x: box.large ? 0 : 40
        y: box.large ? 20 - height / 2 : 20 - height / 2
        width: box.width - x - (box.large ? 0 : 14)
        color: ThemeBackend.text
        selectionColor: Qt.rgba(ThemeBackend.mauve.r, ThemeBackend.mauve.g, ThemeBackend.mauve.b, 0.5)
        font.family: ThemeBackend.fontFamily
        font.pixelSize: box.large ? 19 : 14
        font.weight: box.large ? Font.Medium : Font.Normal
        clip: true
        focus: true
        onTextChanged: Gcal.setCaptureText(text)
        Keys.onReturnPressed: box.submit()
        Keys.onEnterPressed: box.submit()
        Keys.onEscapePressed: { if (text !== "") text = ""; else box.escaped(); }
        Text {
            anchors.fill: parent
            verticalAlignment: Text.AlignVCenter
            visible: input.text === ""
            text: box.large ? "Type anything — “dentist tmrw 3pm near metro”, “сдать курсовую до пятницы”…" : "Add a task or event…"
            color: ThemeBackend.subtext0
            opacity: 0.7
            elide: Text.ElideRight
            font: input.font
        }
    }
    Text {
        visible: !box.large
        x: 13
        y: 20 - height / 2
        text: String.fromCodePoint(box.busy ? 0xF0450 : 0xF0415)
        color: ThemeBackend.mauve
        font.family: ThemeBackend.iconFont
        font.pixelSize: 17
    }

    // inline chip editor
    property string editingField: ""
    function startEdit(f, initial) {
        editingField = f;
        editor.text = initial || "";
        editor.forceActiveFocus();
        editor.selectAll();
    }
    function finishEdit(apply) {
        if (apply && editingField !== "") Gcal.editField(editingField, editor.text);
        editingField = "";
        input.forceActiveFocus();
    }
    Rectangle {
        id: editorBox
        visible: box.editingField !== ""
        z: 10
        x: chips.x
        y: col.y + chips.y + chips.height + 4
        width: Math.min(box.width, 320)
        height: 34
        radius: 17
        color: Qt.rgba(ThemeBackend.base.r, ThemeBackend.base.g, ThemeBackend.base.b, 0.96)
        border.width: 1
        border.color: Qt.rgba(ThemeBackend.mauve.r, ThemeBackend.mauve.g, ThemeBackend.mauve.b, 0.6)
        Text {
            id: edLabel
            x: 12
            anchors.verticalCenter: parent.verticalCenter
            text: box.editingField + ":"
            color: ThemeBackend.mauve
            font.family: ThemeBackend.fontFamily
            font.pixelSize: 12
            font.weight: Font.Bold
        }
        TextInput {
            id: editor
            anchors.left: edLabel.right
            anchors.leftMargin: 8
            anchors.right: parent.right
            anchors.rightMargin: 12
            anchors.verticalCenter: parent.verticalCenter
            color: ThemeBackend.text
            font.family: ThemeBackend.fontFamily
            font.pixelSize: 13
            clip: true
            Keys.onReturnPressed: box.finishEdit(true)
            Keys.onEnterPressed: box.finishEdit(true)
            Keys.onEscapePressed: box.finishEdit(false)
            onActiveFocusChanged: if (!activeFocus && box.editingField !== "") box.finishEdit(false)
        }
    }

    component Chip: Rectangle {
        id: chip
        property string field: ""
        property int glyph: 0
        property string label: ""
        property string editText: label
        property color accent: ThemeBackend.mauve
        property bool strong: false
        property bool subtle: false
        property bool removable: true
        property bool editable: true
        property real maxW: 9999
        signal activated()

        visible: label !== "" || glyph === 0xF0415
        width: Math.min(row.implicitWidth + 18 + (removable ? 14 : 0), maxW)
        height: box.large ? 30 : 26
        radius: height / 2
        color: Qt.rgba(accent.r, accent.g, accent.b, cMa.containsMouse ? (strong ? 0.36 : 0.26) : (strong ? 0.24 : (subtle ? 0.08 : 0.14)))
        border.width: 1
        border.color: Qt.rgba(1, 1, 1, cMa.containsMouse ? 0.22 : 0.08)
        Behavior on color { ColorAnimation { duration: 160 } }
        scale: cMa.pressed ? 0.94 : 1
        Behavior on scale { NumberAnimation { duration: 200; easing.type: Easing.OutQuint } }

        // pop in when a value appears or changes
        property string _last: ""
        onLabelChanged: { if (label !== "" && label !== _last) pop.restart(); _last = label; }
        SequentialAnimation {
            id: pop
            NumberAnimation { target: chip; property: "opacity"; from: 0.35; to: 1; duration: 260; easing.type: Easing.OutCubic }
        }

        Row {
            id: row
            x: 9
            anchors.verticalCenter: parent.verticalCenter
            spacing: 5
            width: Math.min(implicitWidth, chip.maxW - 18 - (chip.removable ? 14 : 0))
            clip: true
            Text {
                visible: chip.glyph !== 0
                anchors.verticalCenter: parent.verticalCenter
                text: chip.glyph ? String.fromCodePoint(chip.glyph) : ""
                color: chip.accent
                font.family: ThemeBackend.iconFont
                font.pixelSize: box.large ? 14 : 13
            }
            Text {
                visible: text !== ""
                anchors.verticalCenter: parent.verticalCenter
                text: chip.label
                color: ThemeBackend.text
                elide: Text.ElideRight
                font.family: ThemeBackend.fontFamily
                font.pixelSize: box.large ? 13 : 12
                font.weight: chip.strong || chip.field === "title" ? Font.Bold : Font.DemiBold
            }
        }
        MouseArea {
            id: cMa
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: {
                if (chip.editable && chip.field !== "") box.startEdit(chip.field, chip.editText);
                else chip.activated();
            }
        }
        Text {
            id: xBtn
            visible: chip.removable && cMa.containsMouse || xMa.containsMouse
            anchors.right: parent.right
            anchors.rightMargin: 6
            anchors.verticalCenter: parent.verticalCenter
            text: String.fromCodePoint(0xF0156)
            color: xMa.containsMouse ? ThemeBackend.red : ThemeBackend.subtext0
            font.family: ThemeBackend.iconFont
            font.pixelSize: 12
            MouseArea { id: xMa; anchors.fill: parent; anchors.margins: -3; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: Gcal.editField(chip.field, "") }
        }
    }
}
