import QtQuick
import QtQuick.Effects
import Quickshell
import Quickshell.Services.Mpris
import "../../../reusables"
import "../../../media"
import "../../../"

// Desktop music widget ("full" variant): cover, title/artist, a slim seek bar and the
// transport, on a soft blur of the cover. The cover column hides on very small sizes.
Item {
    id: root
    anchors.fill: parent

    property real minWidth: 150
    property real minHeight: 64
    property real maxWidth: 800
    property real maxHeight: 300
    property real minAspect: 2.4
    property real maxAspect: 3.2

    property real dynMargin: Math.max(6, Math.min(22, root.height * 0.12))
    property real dynSpacing: Math.max(4, Math.min(18, root.height * 0.09))
    property real btnSize: Math.max(18, Math.min(52, root.height * 0.25))
    property real iconSize: Math.round(btnSize * 0.36)
    property real titleSize: Math.max(10, Math.min(24, root.height * 0.145))
    property real subSize: Math.max(8, Math.min(16, root.height * 0.105))

    property bool showArt: true
    property bool showTime: true
    property bool showArtist: true
    property bool showBars: true

    property bool isVisVisible: visible && showBars
    property bool isSubscribed: false

    onIsVisVisibleChanged: updateSubscription()

    function updateSubscription() {
        if (isVisVisible && !isSubscribed) {
            isSubscribed = true;
            Cava.registerConsumer();
        } else if (!isVisVisible && isSubscribed) {
            isSubscribed = false;
            Cava.unregisterConsumer();
        }
    }

    function updateVisibility() {
        if (height >= 65 && width >= 180) showArt = true;
        else if (height <= 58 || width <= 170) showArt = false;

        if (height >= 85) showTime = true;
        else if (height <= 76) showTime = false;

        if (height >= 65) showArtist = true;
        else if (height <= 58) showArtist = false;

        if (height >= 55) showBars = true;
        else if (height <= 48) showBars = false;
    }

    Component.onCompleted: {
        updateVisibility();
        updateSubscription();
    }

    Component.onDestruction: {
        if (isSubscribed) {
            isSubscribed = false;
            Cava.unregisterConsumer();
        }
    }

    onHeightChanged: updateVisibility()
    onWidthChanged: updateVisibility()

    property var player: MprisController.activePlayer
    property bool isMediaActive: player !== null && player.playbackState !== MprisPlaybackState.Stopped && player.trackTitle !== ""
    readonly property bool isPlaying: isMediaActive && (player.playbackState === MprisPlaybackState.Playing || player.isPlaying)
    readonly property string artSource: {
        let u = MprisController.artUrl;
        if (!isMediaActive || !u) return "";
        return (u.startsWith("file://") || u.startsWith("http")) ? u : "file://" + u;
    }

    property int barCount: 40
    property real barSpacing: Math.max(2, Math.floor(width * 0.008))
    property real qWidth: Math.round(width / 20) * 20
    property int activeBars: Math.min(barCount, Math.max(4, Math.floor(qWidth / (5 + barSpacing))))

    function formatTime(sec) {
        sec = Math.max(0, Math.floor(sec || 0));
        let m = Math.floor(sec / 60), s = sec % 60;
        return m + ":" + (s < 10 ? "0" : "") + s;
    }

    readonly property color chip: Qt.alpha(ThemeBackend.text, 0.09)
    readonly property color chipHover: Qt.alpha(ThemeBackend.text, 0.18)

    Rectangle {
        id: bgContainer
        anchors.fill: parent
        color: ThemeBackend.surface0
        radius: ThemeBackend.borderRadius

        Item {
            id: bgMask
            anchors.fill: parent
            visible: false
            layer.enabled: true
            Rectangle { anchors.fill: parent; radius: bgContainer.radius; color: "black" }
        }

        // Soft blur of the cover + the quiet visualizer, both clipped to the card.
        Item {
            anchors.fill: parent
            layer.enabled: true
            layer.effect: MultiEffect {
                maskEnabled: true
                maskSource: bgMask
                maskThresholdMin: 0.5
                maskSpreadAtMin: 1.0
            }

            Image {
                anchors.fill: parent
                anchors.margins: -Scaler.s(30)
                source: root.artSource
                sourceSize: Qt.size(140, 140)
                fillMode: Image.PreserveAspectCrop
                asynchronous: true
                opacity: status === Image.Ready && source != "" ? 1 : 0
                Behavior on opacity { NumberAnimation { duration: 600; easing.type: Easing.InOutQuad } }
                layer.enabled: true
                layer.effect: MultiEffect {
                    blurEnabled: true
                    blur: 1.0
                    blurMax: 56
                    saturation: 0.2
                    autoPaddingEnabled: false
                }
            }
            Rectangle {
                anchors.fill: parent
                gradient: Gradient {
                    orientation: Gradient.Horizontal
                    GradientStop { position: 0.0; color: Qt.alpha(ThemeBackend.base, 0.45) }
                    GradientStop { position: 1.0; color: Qt.alpha(ThemeBackend.base, 0.72) }
                }
            }

            Visualizer {
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                height: Math.max(20, parent.height * 0.55)
                visible: root.showBars
                active: root.isSubscribed
                count: root.activeBars
                spacing: root.barSpacing
                rise: 0.5
                fall: 0.5
                maxLength: height * 0.85 * 0.55
                opacityBase: 0.06
                opacityRange: 0.10 * 0.55
            }
        }

        Rectangle {
            anchors.fill: parent
            radius: bgContainer.radius
            color: "transparent"
            border.width: 1
            border.color: Qt.alpha("#ffffff", 0.07)
        }

        Item {
            anchors.fill: parent
            anchors.margins: root.dynMargin

            Item {
                id: artRect
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                width: root.showArt ? Math.min(200, root.height - root.dynMargin * 2) : 0
                height: width
                visible: root.showArt
                readonly property real radius: Math.max(8, width * 0.12)

                RectangularShadow {
                    anchors.fill: parent
                    radius: artRect.radius
                    blur: Math.max(8, artRect.width * 0.2)
                    offset.y: Math.max(2, artRect.width * 0.06)
                    color: Qt.rgba(0, 0, 0, 0.45)
                    opacity: artImg.status === Image.Ready && root.isMediaActive ? 1 : 0
                }

                Rectangle {
                    anchors.fill: parent
                    radius: artRect.radius
                    color: root.chip
                    Text {
                        anchors.centerIn: parent
                        text: "󰝚"
                        font.family: ThemeBackend.iconFont
                        font.pixelSize: parent.width * 0.34
                        color: Qt.alpha(ThemeBackend.text, 0.35)
                        visible: !root.isMediaActive || artImg.status !== Image.Ready
                    }
                }

                Item {
                    id: artMask
                    anchors.fill: parent
                    visible: false
                    layer.enabled: true
                    Rectangle { anchors.fill: parent; radius: artRect.radius; color: "black"; antialiasing: true }
                }

                Image {
                    id: artImg
                    anchors.fill: parent
                    source: root.artSource
                    fillMode: Image.PreserveAspectCrop
                    asynchronous: true
                    mipmap: true
                    visible: false
                }
                MultiEffect {
                    anchors.fill: parent
                    source: artImg
                    maskEnabled: true
                    maskSource: artMask
                    maskThresholdMin: 0.5
                    maskSpreadAtMin: 1.0
                    opacity: (root.isMediaActive && artImg.status === Image.Ready) ? 1.0 : 0.0
                    Behavior on opacity { NumberAnimation { duration: 300 } }
                }
            }

            Item {
                id: detailsColumn
                anchors.left: root.showArt ? artRect.right : parent.left
                anchors.leftMargin: root.showArt ? root.dynSpacing * 1.2 : 0
                anchors.right: parent.right
                anchors.top: root.showArt ? artRect.top : parent.top
                anchors.bottom: root.showArt ? artRect.bottom : parent.bottom

                Item {
                    id: titleClip
                    anchors.top: parent.top
                    anchors.left: parent.left
                    anchors.right: parent.right
                    height: titleTextMain.implicitHeight
                    clip: true

                    property int marqueeSpacing: 30
                    property real scrollProgress: 0.0

                    Item {
                        id: marqueeContainer
                        height: parent.height
                        x: titleTextMain.implicitWidth > titleClip.width ? -titleClip.scrollProgress * (titleTextMain.implicitWidth + titleClip.marqueeSpacing) : 0

                        Row {
                            spacing: titleClip.marqueeSpacing
                            Text {
                                id: titleTextMain
                                text: root.isMediaActive ? (MprisController.trackTitle || "Unknown Track") : I18n.t("music.nothing_playing")
                                font.family: ThemeBackend.fontFamily
                                font.weight: Font.Bold
                                font.pixelSize: root.titleSize
                                color: ThemeBackend.text
                                onTextChanged: titleClip.scrollProgress = 0.0
                            }
                            Text {
                                text: titleTextMain.text
                                font.family: ThemeBackend.fontFamily
                                font.weight: Font.Bold
                                font.pixelSize: root.titleSize
                                color: ThemeBackend.text
                                visible: titleTextMain.implicitWidth > titleClip.width
                            }
                        }
                    }

                    SequentialAnimation {
                        loops: Animation.Infinite
                        running: titleTextMain.implicitWidth > titleClip.width && root.isPlaying && root.visible

                        PauseAnimation { duration: 3000 }
                        NumberAnimation {
                            target: titleClip
                            property: "scrollProgress"
                            from: 0.0
                            to: 1.0
                            duration: (titleTextMain.implicitWidth + titleClip.marqueeSpacing) * 30
                        }
                        PropertyAction { target: titleClip; property: "scrollProgress"; value: 0.0 }
                    }
                }

                Text {
                    id: artistText
                    anchors.top: titleClip.bottom
                    anchors.topMargin: Math.max(1, root.dynSpacing * 0.15)
                    anchors.left: parent.left
                    anchors.right: parent.right
                    text: root.isMediaActive ? (MprisController.trackArtist || "Unknown Artist") : ""
                    font.family: ThemeBackend.fontFamily
                    font.weight: Font.DemiBold
                    font.pixelSize: root.subSize
                    color: Qt.lighter(ThemeBackend.mauve, 1.05)
                    elide: Text.ElideRight
                    visible: root.isMediaActive && root.showArtist
                }

                Row {
                    id: controlsRow
                    anchors.bottom: parent.bottom
                    anchors.left: parent.left
                    spacing: Math.max(2, root.dynSpacing * 0.5)

                    IconButton {
                        width: root.btnSize
                        height: root.btnSize
                        cornerRadius: Math.round(root.btnSize / 2)
                        buttonIcon: "󰒮"
                        iconFontSize: root.iconSize
                        accentColor: isHoveredOrHighlighted ? root.chipHover : root.chip
                        textColor: ThemeBackend.text
                        enabled: root.player !== null && root.player.canGoPrevious
                        onClicked: root.player.previous()
                    }
                    IconButton {
                        width: root.btnSize
                        height: root.btnSize
                        cornerRadius: Math.round(root.btnSize / 2)
                        buttonIcon: root.isPlaying ? "󰏤" : "󰐊"
                        iconFontSize: root.iconSize
                        accentColor: isHoveredOrHighlighted ? Qt.lighter(ThemeBackend.mauve, 1.08) : ThemeBackend.mauve
                        textColor: ThemeBackend.base
                        enabled: root.player !== null && root.player.canTogglePlaying
                        onClicked: root.player.togglePlaying()
                    }
                    IconButton {
                        width: root.btnSize
                        height: root.btnSize
                        cornerRadius: Math.round(root.btnSize / 2)
                        buttonIcon: "󰒭"
                        iconFontSize: root.iconSize
                        accentColor: isHoveredOrHighlighted ? root.chipHover : root.chip
                        textColor: ThemeBackend.text
                        enabled: root.player !== null && root.player.canGoNext
                        onClicked: root.player.next()
                    }
                }

                Item {
                    id: middleArea
                    anchors.top: artistText.visible ? artistText.bottom : titleClip.bottom
                    anchors.bottom: controlsRow.top
                    anchors.left: parent.left
                    anchors.right: parent.right

                    Row {
                        id: seekRow
                        anchors.verticalCenter: parent.verticalCenter
                        width: parent.width
                        spacing: Math.max(4, root.dynSpacing * 0.5)
                        visible: root.showTime && root.isMediaActive

                        Text {
                            id: elapsedText
                            anchors.verticalCenter: parent.verticalCenter
                            text: root.formatTime(progBar.shownValue)
                            font.family: ThemeBackend.fontFamily
                            font.weight: Font.DemiBold
                            font.features: { "tnum": 1 }
                            font.pixelSize: Math.max(7, root.subSize * 0.82)
                            color: Qt.alpha(ThemeBackend.text, 0.6)
                        }

                        MusicSeekBar {
                            id: progBar
                            anchors.verticalCenter: parent.verticalCenter
                            width: Math.max(0, seekRow.width - elapsedText.width - lengthText.width - seekRow.spacing * 2)
                            height: Math.max(12, Math.round(root.subSize * 1.1))
                            from: 0
                            to: (root.player && root.player.length > 0) ? root.player.length : 1
                            value: MprisController.livePosition
                            interactive: root.player !== null && root.player.canSeek
                            trackHeight: Math.max(2, Math.round(root.height * 0.025))
                            hoverTrackHeight: Math.max(3, Math.round(root.height * 0.04))
                            knobSize: Math.max(8, Math.round(root.height * 0.09))
                            fillColor: root.isPlaying ? ThemeBackend.mauve : Qt.alpha(ThemeBackend.text, 0.6)
                            onCommitted: (v) => { if (root.player && root.player.canSeek) root.player.position = v; }
                        }

                        Text {
                            id: lengthText
                            anchors.verticalCenter: parent.verticalCenter
                            text: root.player ? root.formatTime(root.player.length) : "0:00"
                            font.family: ThemeBackend.fontFamily
                            font.weight: Font.DemiBold
                            font.features: { "tnum": 1 }
                            font.pixelSize: Math.max(7, root.subSize * 0.82)
                            color: Qt.alpha(ThemeBackend.text, 0.6)
                        }
                    }
                }
            }
        }
    }
}
