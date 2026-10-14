import QtQuick

// A Material Design glyph from the Symbols Nerd Font, by name.
Text {
    id: icon
    property var app
    property string name: ""
    property real size: 20
    readonly property var glyphs: ({
        "mail": 0xf01ee, "mail-outline": 0xf01f0, "mail-open": 0xf05ef, "mail-unread": 0xf0b92,
        "mails": 0xf0ee8, "inbox": 0xf0687, "inbox-down": 0xf02fb, "inboxes": 0xf0ba8, "mailbox": 0xf0d8c,
        "send": 0xf048a, "send-outline": 0xf1165, "send-clock": 0xf1164, "pencil": 0xf03eb, "pencil-outline": 0xf0cb6,
        "archive": 0xf125a, "archive-outline": 0xf120e, "delete": 0xf09e7, "trash": 0xf0a7a,
        "star": 0xf04ce, "star-outline": 0xf04d2, "reply": 0xf045a, "reply-all": 0xf045b, "forward": 0xf0496,
        "spam": 0xf0ce6, "clip": 0xf03e2, "search": 0xf0349, "refresh": 0xf0450, "cog": 0xf0493,
        "account": 0xf0009, "accounts": 0xf000f, "plus": 0xf0415, "close": 0xf0156, "dots": 0xf01d8, "dots-v": 0xf01d9,
        "folder": 0xf0256, "image": 0xf02e9, "image-outline": 0xf0976, "image-off": 0xf11d1,
        "pdf": 0xf0226, "doc": 0xf103e, "sheet": 0xf102d, "slides": 0xf1035, "archive-file": 0xf0ffa,
        "file": 0xf0224, "file-text": 0xf09ee, "calendar": 0xf0b67, "audio": 0xf0f74, "video": 0xf0bdc,
        "check": 0xf012c, "check-all": 0xf012d, "undo": 0xf054c, "open": 0xf03cc, "code": 0xf0174,
        "eye": 0xf06d0, "eye-off": 0xf06d1, "back": 0xf004d, "login": 0xf0342, "logout": 0xf0343,
        "bell": 0xf009c, "offline": 0xf0164, "warn": 0xf002a, "chev-down": 0xf0140, "chev-right": 0xf0142,
        "chev-left": 0xf0141, "chev-up": 0xf0143, "download": 0xf01da, "save": 0xf0818, "link": 0xf0339,
        "quote": 0xf027e, "label": 0xf0316, "cancel": 0xf073a, "keyboard": 0xf097b, "web": 0xf059f,
        "drafts": 0xf0cb6, "sent": 0xf1165, "junk": 0xf0ce6, "all": 0xf0ee8, "flagged": 0xf04d2,
        "unsubscribe": 0xf1662, "night": 0xf0594,
        "sparkle": 0xf0674, "magic": 0xf0068, "key": 0xf030b, "translate": 0xf05ca, "stop": 0xf04db,
        "calendar-plus": 0xf00f3, "people": 0xf0b58, "updates": 0xf009f, "news": 0xf1004, "ask": 0xf0eaf,
        "copy": 0xf018f, "check-circle": 0xf05e1, "todo": 0xf0756, "robot": 0xf167a, "bolt": 0xf140c
    })
    text: glyphs[name] !== undefined ? String.fromCodePoint(glyphs[name]) : ""
    font.family: app ? app.th.icons : "Symbols Nerd Font Mono"
    font.pixelSize: Math.round(size)
    color: app ? app.th.text : "white"
    horizontalAlignment: Text.AlignHCenter
    verticalAlignment: Text.AlignVCenter
}
