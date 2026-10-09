import QtQuick
import QtQuick.Layouts
import "../../../reusables"
import "../../../"

Item {
    id: pillsFaceRoot
    property var widget: null

    readonly property bool glass: !!(widget && widget.module && widget.module.glass)
    readonly property real dotGap: widget ? widget.s(widget.isCompact ? 7 : 8) : 8
    readonly property real activeW: widget ? widget.s(widget.isCompact ? 34 : 36) : 36
    readonly property real inactiveW: widget ? widget.s(widget.isCompact ? 16 : 18) : 18
    readonly property real dotH: widget ? widget.s(widget.isCompact ? 16 : 18) : 18

    // Each slot carries its trailing gap, so slots can grow/shrink to zero smoothly
    // (workspaces appearing/disappearing never jump); the last gap is trimmed here.
    implicitWidth: Math.max(0, wsLayout.implicitWidth - dotGap)
    implicitHeight: dotH

    Rectangle {
        id: activeHighlight
        z: 3
        radius: widget ? widget.s(widget.isCompact ? 7 : 8) : 8
        color: (widget && widget.isCompact) ? Qt.lighter(ThemeBackend.mauve, 1.05) : ThemeBackend.mauve

        property int prevIdx: 0
        property int curIdx: widget ? widget.activeIndex : -1

        onCurIdxChanged: {
            if (curIdx >= 0 && prevIdx >= 0) {
                if (curIdx > prevIdx) {
                    leftAnim.duration = 400;
                    rightAnim.duration = 300;
                } else if (curIdx < prevIdx) {
                    leftAnim.duration = 300;
                    rightAnim.duration = 400;
                }
            }
            if (curIdx >= 0) {
                prevIdx = curIdx;
            }
        }

        function getX(index, activeIndex) {
            if (index < 0 || !widget) return 0;
            let xPos = 0;
            for (let i = 0; i < index; i++) {
                if (typeof widget.isShown === "function" && !widget.isShown(i))
                    continue;
                xPos += (i === activeIndex ? pillsFaceRoot.activeW : pillsFaceRoot.inactiveW) + pillsFaceRoot.dotGap;
            }
            return xPos;
        }

        property real targetLeft: {
            if (widget) {
                widget.hideEmptyWorkspaces;
                widget.activeIndex;
                widget.workspaceCount;
                widget.niriOccupiedMap;
                widget.swayOccupiedMap;
            }
            return (curIdx >= 0 && widget) ? getX(curIdx, curIdx) : 0;
        }
        property real targetRight: (curIdx >= 0 && widget) ? targetLeft + pillsFaceRoot.activeW : 0
        property real actualLeft: targetLeft
        property real actualRight: targetRight

        Behavior on actualLeft { NumberAnimation { id: leftAnim; duration: 380; easing.type: Easing.OutQuint } }
        Behavior on actualRight { NumberAnimation { id: rightAnim; duration: 380; easing.type: Easing.OutQuint } }

        x: wsLayout.x + actualLeft
        y: wsLayout.y + (wsLayout.height - height) / 2
        width: actualRight - actualLeft
        height: pillsFaceRoot.dotH
        opacity: (widget && widget.workspaceCount > 0 && widget.activeIndex >= 0) ? 1.0 : 0.0
        Behavior on opacity { NumberAnimation { duration: 180 } }
    }

    Row {
        id: wsLayout
        z: 2
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        spacing: 0

        Repeater {
            model: widget ? widget.workspaceCount : 0

            delegate: Item {
                id: wsPill
                required property int index

                property bool isOccupied: widget ? widget.isOccupied(index) : false
                property bool isActive: widget ? (index === widget.activeIndex) : false
                property bool initAnimTrigger: false
                property bool shown: widget && typeof widget.isShown === "function" ? widget.isShown(index) : true
                // a slot added after startup grows in from zero width
                property bool grown: false

                readonly property real dotW: isActive ? pillsFaceRoot.activeW : pillsFaceRoot.inactiveW

                width: (shown && grown) ? (dotW + pillsFaceRoot.dotGap) : 0
                height: pillsFaceRoot.dotH
                anchors.verticalCenter: parent.verticalCenter
                visible: width > 0.5

                Behavior on width { NumberAnimation { duration: 400; easing.type: Easing.OutQuint } }

                Rectangle {
                    id: wsVisualShape
                    x: 0
                    anchors.verticalCenter: parent.verticalCenter
                    width: wsPill.dotW
                    height: pillsFaceRoot.dotH
                    radius: widget ? widget.s(widget.isCompact ? 8 : 10) : 10
                    color: wsPill.isActive ? "transparent"
                        : (pillsFaceRoot.glass
                            ? (wsPill.isOccupied ? Qt.alpha(ThemeBackend.text, 0.42) : Qt.alpha(ThemeBackend.text, 0.14))
                            : (wsPill.isOccupied ? ThemeBackend.surface2 : ((widget && widget.isCompact) ? ThemeBackend.surface1 : ThemeBackend.surface0)))
                    border.width: 0

                    Behavior on width { NumberAnimation { duration: 400; easing.type: Easing.OutQuint } }
                    Behavior on color { ColorAnimation { duration: 250 } }

                    scale: wsPillMouse.pressed ? 0.88 : (wsPillMouse.containsMouse ? 1.08 : 1.0)
                    Behavior on scale { NumberAnimation { duration: 250; easing.type: Easing.OutQuint } }

                    MouseArea {
                        id: wsPillMouse
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        anchors.fill: parent
                        onClicked: {
                            if (widget) widget.focusWorkspace(wsPill.index);
                        }
                    }
                }

                opacity: (initAnimTrigger && shown) ? 1.0 : 0.0
                transform: Translate {
                    y: wsPill.initAnimTrigger ? 0 : (widget ? widget.s(15) : 15)
                    Behavior on y { NumberAnimation { duration: 650; easing.type: Easing.OutQuint } }
                }

                Component.onCompleted: {
                    if (widget && widget.barWindow && !widget.barWindow.startupCascadeFinished) {
                        grown = true;
                        animTimer.interval = index * 50 + 100;
                        if (widget.moduleActive) animTimer.start();
                    } else {
                        initAnimTrigger = true;
                        Qt.callLater(() => { wsPill.grown = true; });
                    }
                }

                Timer {
                    id: animTimer
                    running: false
                    repeat: false
                    onTriggered: wsPill.initAnimTrigger = true
                }

                Behavior on opacity { NumberAnimation { duration: 300; easing.type: Easing.OutCubic } }
            }
        }
    }
}
