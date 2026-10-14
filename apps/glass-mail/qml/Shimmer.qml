import QtQuick

// The "AI is thinking" sparkle: a gently pulsing, turning glyph.
Icon {
    id: sh
    name: "sparkle"
    size: Math.min(width, height)
    color: app ? app.th.accent : "white"
    SequentialAnimation on opacity {
        loops: Animation.Infinite
        running: sh.visible
        NumberAnimation { from: 1; to: 0.35; duration: 700; easing.type: Easing.InOutSine }
        NumberAnimation { from: 0.35; to: 1; duration: 700; easing.type: Easing.InOutSine }
    }
    RotationAnimator on rotation { running: sh.visible; from: 0; to: 360; loops: Animation.Infinite; duration: 4000 }
}
