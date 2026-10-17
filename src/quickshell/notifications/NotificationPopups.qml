import QtQuick
import QtQuick.Window
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Wayland
import Quickshell.Hyprland
import Quickshell.Io
import "../"
import "../reusables"

PanelWindow {
    id: popupWindow

    readonly property real sf: Scaler.baseScale

    function s(val) {
        return Math.round(val * popupWindow.sf);
    }

    property bool hasCriticalPopup: {
        for (let i = 0; i < NotificationManager.activePopupsModel.count; i++) {
            let p = NotificationManager.activePopupsModel.get(i);
            if (p && p.urgency === 2) return true;
        }
        return false;
    }

    // a game is open: no popups at all (they would catch the cursor); they still land in the centre
    property bool gameRunning: false
    Process {
        running: true
        command: ["bash", Caching.qsDir + "/watchers/game_watch.sh"]
        stdout: SplitParser {
            onRead: data => popupWindow.gameRunning = data.trim() === "1"
        }
    }

    visible: !popupWindow.gameRunning && (!popupWindow.dndEnabled || popupWindow.hasCriticalPopup) && !NotificationManager.sysPanelOpen && NotificationManager.activePopupsModel.count > 0

    function storeNotif(uid, notif) {
        NotificationManager.liveNotifs[uid] = notif;
    }

    function getNotif(uid) {
        return NotificationManager.liveNotifs[uid] || null;
    }

    function removeNotif(uid) {
        delete NotificationManager.liveNotifs[uid];
        NotificationManager.removePopup(uid);
    }

    property var rawBarSettings: Config.getSetting("bar", {})
    property string barPosition: (rawBarSettings && rawBarSettings.position !== undefined) ? rawBarSettings.position : "top"
    property bool barAutohide: (rawBarSettings && rawBarSettings.autohide !== undefined) ? Boolean(rawBarSettings.autohide) : false

    readonly property bool isFullscreenActive: {
        try {
            if (typeof Hyprland !== "undefined" && Hyprland.focusedWorkspace) {
                return Boolean(Hyprland.focusedWorkspace.hasFullscreen || (Hyprland.activeToplevel && Hyprland.activeToplevel.fullscreen));
            }
        } catch (e) {}
        return false;
    }

    readonly property bool isBarEffectivelyHidden: barAutohide || isFullscreenActive

    property string barStyle: {
        if (!rawBarSettings || rawBarSettings.style === undefined) return "modular";
        let st = rawBarSettings.style;
        if (typeof st === "string") return st;
        if (typeof st === "object") {
            if (st.fill || st.mode === "fill") return "fill";
            if (st.solid || st.mode === "solid") return "solid";
        }
        return "modular";
    }
    property bool isBarFill: barStyle === "fill"
    property int barThickness: s(40) + (isBarFill || isBarEffectivelyHidden ? 0 : s(4))

    property var notifSettings: Config.getSetting("notifications", { "dnd": false, "position": "top right", "horizontalPosition": 95, "verticalPosition": 5 })
    property string position: notifSettings.position !== undefined ? notifSettings.position : "top right"
    property real horizontalPosition: notifSettings.horizontalPosition !== undefined ? notifSettings.horizontalPosition : 95
    property real verticalPosition: notifSettings.verticalPosition !== undefined ? notifSettings.verticalPosition : 5

    property bool isPreset: position !== "custom"

    property bool isTop: position.indexOf("top") !== -1
    property bool isBottom: position.indexOf("bottom") !== -1
    property bool isCenter: position.indexOf("center") !== -1
    property bool isLeft: position.indexOf("left") !== -1
    property bool isRight: position.indexOf("right") !== -1 || (!isLeft && !isCenter)

    WlrLayershell.namespace: "qs-popups"
    WlrLayershell.layer: WlrLayer.Overlay
    // a card's reply field needs the keyboard; take it only while one is open
    property bool replyActive: false
    WlrLayershell.keyboardFocus: replyActive ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.None

    anchors {
        top: true
        bottom: true
        left: isPreset ? (popupWindow.isCenter || popupWindow.isLeft) : true
        right: isPreset ? (popupWindow.isCenter || popupWindow.isRight) : true
    }

    margins {
        top: isPreset ? ((popupWindow.barPosition === "top" && !popupWindow.isBarEffectivelyHidden ? popupWindow.barThickness : 0) + popupWindow.s(12)) : 0
        bottom: isPreset ? ((popupWindow.barPosition === "bottom" && !popupWindow.isBarEffectivelyHidden ? popupWindow.barThickness : 0) + popupWindow.s(12)) : 0
        left: isPreset ? ((popupWindow.barPosition === "left" && popupWindow.isLeft && !popupWindow.isBarEffectivelyHidden ? popupWindow.barThickness : 0) + (popupWindow.isLeft ? popupWindow.s(16) : 0)) : 0
        right: isPreset ? ((popupWindow.barPosition === "right" && popupWindow.isRight && !popupWindow.isBarEffectivelyHidden ? popupWindow.barThickness : 0) + (popupWindow.isRight ? popupWindow.s(16) : 0)) : 0
    }

    exclusionMode: ExclusionMode.Ignore
    focusable: false
    color: "transparent"

    readonly property real cardWidth: glassOn ? s(372) : s(350)
    implicitWidth: cardWidth

    mask: Region {
        item: popupContainer
    }

    // Liquid glass (bar.glass): niri blurs what is behind each card. Window coordinates are
    // computed from the delegates, because an `item:` region would not see the list moving
    // them (slide-in, stacking, swipe). Cards register themselves in glassItems.
    readonly property bool glassOn: Boolean(Config.rawSettings && Config.rawSettings.bar && Config.rawSettings.bar.glass)
    property var glassItems: []
    function glassAdd(d) { glassItems = glassItems.concat([d]); }
    function glassRemove(d) { glassItems = glassItems.filter(x => x !== d); }

    readonly property point glassOrigin: Qt.point(popupContainer.x + popupList.x, popupContainer.y + popupList.y)
    readonly property point glassScroll: Qt.point(popupList.contentX, popupList.contentY)

    BackgroundEffect.blurRegion: glassOn ? glassRegion : null
    Region {
        id: glassRegion
        GlassSlot { win: popupWindow; idx: 0 }
        GlassSlot { win: popupWindow; idx: 1 }
        GlassSlot { win: popupWindow; idx: 2 }
        GlassSlot { win: popupWindow; idx: 3 }
        GlassSlot { win: popupWindow; idx: 4 }
        GlassSlot { win: popupWindow; idx: 5 }
        GlassSlot { win: popupWindow; idx: 6 }
        GlassSlot { win: popupWindow; idx: 7 }
    }

    property bool dndEnabled: {
        let n = Config.getSetting("notifications", { "dnd": false, "position": "top right" });
        return Boolean(n && n.dnd);
    }

    Connections {
        target: Config
        function onSettingsLoaded() {
            let n = Config.getSetting("notifications", { "dnd": false, "position": "top right" });
            popupWindow.dndEnabled = Boolean(n && n.dnd);
            popupWindow.position = (n && n.position !== undefined) ? n.position : "top right";
            popupWindow.horizontalPosition = (n && n.horizontalPosition !== undefined) ? n.horizontalPosition : 95;
            popupWindow.verticalPosition = (n && n.verticalPosition !== undefined) ? n.verticalPosition : 5;
            popupWindow.rawBarSettings = Config.getSetting("bar", {});
            popupWindow.barPosition = (popupWindow.rawBarSettings && popupWindow.rawBarSettings.position !== undefined) ? popupWindow.rawBarSettings.position : "top";
            popupWindow.barAutohide = (popupWindow.rawBarSettings && popupWindow.rawBarSettings.autohide !== undefined) ? Boolean(popupWindow.rawBarSettings.autohide) : false;
        }
    }

    Item {
        id: popupRoot
        anchors.fill: parent
        readonly property var popupWindow: popupWindow

        function s(val) {
            return popupWindow.s(val);
        }

        Item {
            id: popupContainer
            width: popupWindow.cardWidth
            height: popupList.height

            x: popupWindow.isPreset ? (popupWindow.isCenter ? (popupWindow.width - width) / 2 : (popupWindow.isLeft ? 0 : (popupWindow.width - width))) : ((popupWindow.width - width) * (popupWindow.horizontalPosition / 100.0))
            y: popupWindow.isPreset ? (popupWindow.isTop ? 0 : (popupWindow.height - height)) : ((popupWindow.height - height) * (popupWindow.verticalPosition / 100.0))

            ListView {
                id: popupList
                width: parent.width
                height: Math.min(popupWindow.height, contentHeight)
                verticalLayoutDirection: (popupWindow.isPreset ? popupWindow.isBottom : (popupWindow.verticalPosition > 50)) ? ListView.BottomToTop : ListView.TopToBottom
                model: NotificationManager.activePopupsModel
                spacing: popupWindow.glassOn ? popupWindow.s(10) : popupWindow.s(12)
                interactive: false
                clip: false
                boundsBehavior: Flickable.StopAtBounds

                add: Transition {
                    ParallelAnimation {
                        NumberAnimation { property: "opacity"; from: 0.0; to: 1.0; duration: 220; easing.type: Easing.OutCubic }
                        NumberAnimation { property: "scale"; from: popupWindow.glassOn ? 0.9 : 1.0; to: 1.0; duration: 460; easing.type: Easing.OutBack; easing.overshoot: 1.3 }
                        NumberAnimation {
                            property: "x"
                            from: (popupWindow.isPreset ? (popupWindow.isCenter ? 0 : (popupWindow.isLeft ? -1 : 1)) : (popupWindow.horizontalPosition < 33 ? -1 : (popupWindow.horizontalPosition > 66 ? 1 : 0))) * popupWindow.cardWidth * 0.35
                            to: 0
                            duration: 250
                            easing.type: Easing.OutCubic
                        }
                        NumberAnimation {
                            property: "y"
                            from: (popupWindow.isPreset ? (popupWindow.isCenter ? (popupWindow.isBottom ? popupWindow.s(24) : -popupWindow.s(24)) : 0) : ((popupWindow.verticalPosition > 50) ? popupWindow.s(24) : -popupWindow.s(24)))
                            to: 0
                            duration: 250
                            easing.type: Easing.OutCubic
                        }
                    }
                }

                remove: Transition {
                    ParallelAnimation {
                        NumberAnimation { property: "opacity"; to: 0.0; duration: 180; easing.type: Easing.OutCubic }
                        NumberAnimation {
                            property: "x"
                            to: (popupWindow.isPreset ? (popupWindow.isCenter ? 0 : (popupWindow.isLeft ? -1 : 1)) : (popupWindow.horizontalPosition < 33 ? -1 : (popupWindow.horizontalPosition > 66 ? 1 : 0))) * popupWindow.cardWidth * 0.35
                            duration: 200
                            easing.type: Easing.OutCubic
                        }
                    }
                }

                // x and y both: a card displaced mid slide-in would otherwise be left off-grid
                // and overlap its neighbour (the add transition is interrupted at a partial offset)
                displaced: Transition {
                    NumberAnimation { properties: "x,y"; duration: 220; easing.type: Easing.OutCubic }
                }

                removeDisplaced: Transition {
                    NumberAnimation { properties: "x,y"; duration: 220; easing.type: Easing.OutCubic }
                }

                delegate: Item {
                    id: delegateWrapper
                    width: ListView.view.width
                    // the card under the pointer (or being replied to) stays above its neighbours
                    z: isHovered || isExpanded ? 2 : 1

                    property bool isSuppressedByDnd: popupWindow.dndEnabled && model.urgency !== 2

                    readonly property bool glassShown: popupWindow.glassOn && !isSuppressedByDnd && opacity > 0.35 && ListView.view !== null
                        && !!typeLoader.item && typeLoader.item.glass === true
                        && Math.abs(typeLoader.item.dragX) < width * 0.3
                    readonly property real glassDx: typeLoader.item ? typeLoader.item.dragX : 0
                    readonly property real glassDy: typeLoader.item ? typeLoader.item.dragY : 0
                    readonly property real glassRadius: (typeLoader.item && typeLoader.item.cardRadius !== undefined ? typeLoader.item.cardRadius : ThemeBackend.borderRadius) * scale
                    Component.onCompleted: popupWindow.glassAdd(delegateWrapper)
                    Component.onDestruction: popupWindow.glassRemove(delegateWrapper)

                    implicitHeight: isSuppressedByDnd ? 0 : (typeLoader.item ? typeLoader.item.implicitHeight : popupWindow.s(70))
                    height: implicitHeight
                    visible: !isSuppressedByDnd

                    property int popupUid: model.latestUid || model.uid
                    property var realNotif: popupWindow.getNotif(popupUid) || (model.notif ? model.notif : null)
                    property bool isPopupContext: true
                    property var msgModel: model
                    property bool isExpanded: typeLoader.item && typeLoader.item.expanded ? true : false
                    property bool isHovered: typeLoader.item && typeLoader.item.isHovered ? true : false
                    property bool isDragging: typeLoader.item && typeLoader.item.isDragging ? true : false

                    property var actionArray: {
                        try {
                            return model.actionsJson ? JSON.parse(model.actionsJson) : []
                        } catch (e) {
                            return []
                        }
                    }

                    property int effectiveTimeout: {
                        if (model.urgency === 2) return 0;
                        var n = delegateWrapper.realNotif;
                        if (!n) return 5000;
                        var t = typeof n.expireTimeout === "number" ? n.expireTimeout : (typeof n.timeout === "number" ? n.timeout : -1);
                        if (t === 0) return 0;
                        if (t > 0) return t;
                        return 5000;
                    }

                    Connections {
                        target: delegateWrapper.realNotif || null
                        function onClosed() {
                            popupWindow.removeNotif(delegateWrapper.popupUid);
                        }
                    }

                    Timer {
                        id: dismissTimer
                        interval: delegateWrapper.effectiveTimeout > 0 ? delegateWrapper.effectiveTimeout : 5000
                        running: delegateWrapper.effectiveTimeout > 0 && !delegateWrapper.isHovered && !delegateWrapper.isExpanded && !delegateWrapper.isDragging
                        repeat: false
                        onTriggered: popupWindow.removeNotif(delegateWrapper.popupUid)
                    }

                    // a new message merged into this card: keep it on screen a full period again
                    onPopupUidChanged: if (dismissTimer.running) dismissTimer.restart()

                    function removeThisNotif() {
                        popupWindow.removeNotif(delegateWrapper.popupUid);
                    }

                    Loader {
                        id: typeLoader
                        width: parent.width
                        readonly property string src: {
                            let app = (model.appName || "").toLowerCase();
                            if (app === "weather") return "types/Weather.qml";
                            if (app === "screenshot" || app === "screen recorder") return "types/Screenshot.qml";
                            if (popupWindow.glassOn) return "LiquidCard.qml";
                            return "types/Default.qml";
                        }
                        // hand the card its data as initial properties, so it has its final height on
                        // the first frame: ListView does not re-place the cards below one that grows later
                        function load() {
                            setSource(src, { "model": delegateWrapper.msgModel, "root": popupRoot, "delegateWrapper": delegateWrapper });
                        }
                        Component.onCompleted: load()
                        onSrcChanged: load()
                    }
                }
            }
        }
    }

    Connections {
        target: NotificationManager
        function onPopupAdded(uid, notif) {
            popupWindow.storeNotif(uid, notif);
        }
    }
}
