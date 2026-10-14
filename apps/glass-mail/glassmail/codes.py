"""Login / verification codes in mail ("Your code is 482913"), found without AI.

Every number-like token (4–8 digits, "123 456", "123-456", G-123456, 6–8 letter+digit codes) gets a
score: near a code word (code, verification, one-time, код, подтверждения…) it rises, things that
look like money, dates, years, phone numbers, order / tracking numbers fall. The best candidate
above the threshold wins. Only mail that *talks about* codes is considered at all.
"""
import re

# a message has to mention a code at all (subject or text)
TOPIC = re.compile(
    r'(verif|one[- ]?time|otp|passcode|pass code|security code|login code|sign[- ]?in|log[- ]?in|2fa|two[- ]factor|'
    r'authenticat|confirm|access code|\bcode\b|\bpin\b|token|'
    r'код|подтвержд|вход|одноразов|пароль|авториз|верификац|'
    r'código|codice|bestätigung|bestaetigung|anmelde|\bcodice\b|コード|認証|確認)', re.I)
NEAR = re.compile(
    r'(code|kod|pin|otp|passcode|password|verification|verify|confirm|one[- ]time|security|login|sign[- ]in|'
    r'код|пароль|подтвержд|вход|введите|enter|use|is|:)', re.I)
STRONG = re.compile(r'(code|kod|otp|passcode|pin|код|c[óo]digo|codice|コード)', re.I)
BAD_BEFORE = re.compile(
    r'(order|заказ|invoice|счёт|счет|tracking|трек|ticket|билет|booking|бронир|account|аккаунт|номер|№|#|id|ref|'
    r'phone|тел|call|\+|\$|€|£|₽|руб|usd|eur|rub|price|total|amount|сумм|итого|balance|баланс)\W{0,3}$', re.I)
BAD_AFTER = re.compile(r'^\W{0,2}(₽|руб|rub|usd|eur|\$|€|%|px|mb|gb|kb|km|кг|kg|мин|min|sec|сек|г\.|year|год)', re.I)
PROMO = re.compile(r'(promo|coupon|discount|voucher|gift|скидк|промокод|купон|подар)', re.I)
MONTHS = re.compile(r'(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec|янв|фев|мар|апр|мая|июн|июл|авг|сен|окт|ноя|дек)', re.I)

TOKEN = re.compile(
    r'(?<![\w/.:#@-])('
    r'[A-Z]{1,3}-\d{4,8}'                    # G-123456, TG-12345
    r'|\d{3}[ -]\d{3}'                       # 123 456, 123-456
    r'|\d{4,8}'                              # 4–8 digits
    r'|(?=[A-Z0-9]{6,8}\b)(?=[A-Z0-9]*\d)(?=[A-Z0-9]*[A-Z])[A-Z0-9]{6,8}'   # AB12CD34
    r')(?![\w/@]|\.\d|,\d|:\d)')


def find(subject, text):
    """-> {'code': '482913', 'score': n} or None"""
    subject = subject or ''
    text = (text or '')[:6000]
    if not TOPIC.search(subject) and not TOPIC.search(text[:3000]):
        return None
    best = None
    for src, base in ((subject, 2), (text, 0)):
        for m in TOKEN.finditer(src):
            tok = m.group(1)
            s = score(src, m.start(1), m.end(1), tok) + base
            if best is None or s > best[0]:
                best = (s, tok)
    if best and best[0] >= 5:
        code = best[1]
        if re.fullmatch(r'\d{3}[ -]\d{3}', code):
            code = code[:3] + code[4:]
        return {'code': code, 'score': best[0]}
    return None


def score(src, a, b, tok):
    before = src[max(0, a - 60):a]
    after = src[b:b + 30]
    near_before = src[max(0, a - 25):a]
    s = 0
    digits = re.sub(r'\D', '', tok)
    if tok.isdigit():
        n = len(tok)
        s += {4: 1, 5: 2, 6: 3, 7: 2, 8: 2}.get(n, 0)
        if n == 4 and 1900 <= int(tok) <= 2100:
            s -= 4                                    # a year
    elif re.fullmatch(r'\d{3}[ -]\d{3}', tok):
        s += 3
    elif re.fullmatch(r'[A-Z]{1,3}-\d{4,8}', tok):
        s += 4
    else:
        s += 1                                        # letter+digit codes: need strong context
        if not STRONG.search(before[-40:]):
            s -= 4
    if STRONG.search(before):
        s += 4
    elif NEAR.search(near_before):
        s += 1
    if re.search(r'(code|код|пароль|pin|otp|c[óo]digo|codice)\s*(is|es|ist|è|:|—|-|–)?\s*:?\s*$', before, re.I):
        s += 3                                        # "Your code is 123456" / "Код: 123456"
    if re.match(r'^\s*(is your|это ваш|— ваш|is the|ist dein|es tu)', after, re.I):
        s += 4                                        # "123456 is your code"
    if BAD_BEFORE.search(before[-25:]):
        # "Код для входа в аккаунт: 384920": a code word earlier in the same sentence wins
        clause = re.split(r'[.!?\n]', before)[-1]
        s -= 2 if STRONG.search(clause) else 6
    if PROMO.search(before):
        s -= 8                                        # promo / coupon codes aren't login codes
    if BAD_AFTER.search(after):
        s -= 6
    if MONTHS.search(src[max(0, a - 12):b + 12]):
        s -= 3                                        # 12 Oct 2026, 2026 г.
    if re.search(r'\+\d[\d ()-]{6,}$', before[-20:]) or re.match(r'^[\d ()-]{4,}', after):
        s -= 6                                        # inside a phone number
    if len(set(digits)) == 1 and len(digits) >= 4:
        s -= 2                                        # 0000, 1111 placeholders
    return s
