import QtQuick

// A Material Design glyph from the Symbols Nerd Font, by name.
Text {
    id: icon
    property var app
    property string name: ""
    property real size: 20
    readonly property var glyphs: ({
        "play": 0xf040a, "pause": 0xf03e4, "next": 0xf04ad, "prev": 0xf04ae,
        "shuffle": 0xf049d, "shuffle-off": 0xf049e, "repeat": 0xf0456, "repeat-one": 0xf0458,
        "repeat-off": 0xf0457, "heart": 0xf02d1, "heart-outline": 0xf02d5, "heart-off": 0xf02d4,
        "home": 0xf02dc, "home-outline": 0xf06a1, "search": 0xf0349, "library": 0xf1a22,
        "library-fill": 0xf0331, "playlist": 0xf0cb8, "artist": 0xf0803, "album": 0xf0025,
        "note": 0xf0387, "music": 0xf075a, "vol-high": 0xf057e, "vol-mid": 0xf0580, "vol-low": 0xf057f,
        "vol-off": 0xf0581, "queue": 0xf0cb8, "lyrics": 0xf036e, "lyrics-fill": 0xf0370,
        "list": 0xf0279, "dots": 0xf01d8, "close": 0xf0156, "back": 0xf0141, "forward": 0xf0142,
        "clock": 0xf0150, "console": 0xf018d, "smart": 0xf049d, "mix": 0xf0674, "sparkle": 0xf0ae2,
        "history": 0xf02da, "fire": 0xf0238, "radio": 0xf0439, "headphones": 0xf02cb, "drag": 0xf01dd,
        "delete": 0xf09e7, "plus": 0xf0415, "play-circle": 0xf040c, "refresh": 0xf0450, "disc": 0xf05ee,
        "grid": 0xf11d9, "playlist-plus": 0xf0412, "playlist-play": 0xf0411, "playlist-remove": 0xf0413,
        "eq": 0xf0ea2, "chev-down": 0xf0140, "chev-up": 0xf0143, "chev-right": 0xf0142, "account": 0xf0009,
        "warn": 0xf0026, "heavy": 0xf02c4, "rock": 0xf02c4, "alt": 0xf04e0, "rap": 0xf036e,
        "electronic": 0xf147d, "pop": 0xf1056, "chill": 0xf0594, "next-up": 0xf0661, "waveform": 0xf147d,
        "clear": 0xf0413, "skip": 0xf04ad, "cancel": 0xf073a,
        "star": 0xf04ce, "star-outline": 0xf04d2, "vibe": 0xf0674, "compass": 0xf018b, "reggae": 0xf1055,
        "tag": 0xf04f9, "dice": 0xf076e, "info": 0xf02fd
    })
    text: glyphs[name] !== undefined ? String.fromCodePoint(glyphs[name]) : ""
    font.family: app ? app.th.icons : "Symbols Nerd Font Mono"
    font.pixelSize: Math.round(size)
    color: app ? app.th.text : "white"
    horizontalAlignment: Text.AlignHCenter
    verticalAlignment: Text.AlignVCenter
}
