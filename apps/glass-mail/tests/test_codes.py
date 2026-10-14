"""Login-code detection on realistic (made-up) mails. python -m unittest tests.test_codes"""
import unittest

from glassmail.codes import find

HAS = [
    ('G-482913 is your Google verification code', 'Use this code to finish setting up 2-Step Verification.', 'G-482913'),
    ('Your verification code', 'Hi,\n\nYour verification code is 731 904. It expires in 10 minutes.\nDidn’t request it? Ignore this email.', '731904'),
    ('Код подтверждения', 'Ваш код подтверждения: 5821\nНикому не сообщайте его.', '5821'),
    ('Яндекс ID: код для входа', 'Код для входа в аккаунт: 384920. Если это были не вы, смените пароль.', '384920'),
    ('Steam Guard', 'Here is the Steam Guard code you need to login to account den2009: F7KQ2', None),
    ('Your Steam Guard code', 'Login code: F7KQ2X\nFrom: Steam Support', 'F7KQ2X'),
    ('Sign in to Telegram', 'Your login code: 62519. Do not give this code to anyone, even if they say they are from Telegram!', '62519'),
    ('Apple Account Code', '482913 is your Apple Account code.\n\nDon’t share it with anyone.', '482913'),
    ('Подтвердите вход', 'Здравствуйте! Для входа в Госуслуги введите код 902 117. Заказ № 4815162342 не связан с этим письмом.', '902117'),
    ('Security alert', 'Enter the one-time passcode 00271843 to continue. Call +1 800 555 0199 if this wasn’t you.', '00271843'),
    ('Your Microsoft account security code', 'Please use the following security code for the Microsoft account d***@gmail.com.\n\nSecurity code: 8812\n\nIf you don\'t recognize the account, click here.', '8812'),
    ('Tu código de verificación', 'Tu código es: 551203', '551203'),
    # Steam's real layout (2026): the code on its own line under "Login Code", letters and digits
    ('Your Steam account: Access from new computer', 'Dear den,\n\nIt looks like you are trying to log in from a new device. Here is the Steam\r\nGuard code you need to access your account:\n\nRequest made from\r\nGermany\r\n\r\nLogin Code\r\nJH4CQ\r\n\n\r\n\r\nIf this wasn\'t you', 'JH4CQ'),
    ('Your Steam account: Access from new computer', 'Request made from\r\nNigeria\r\n\r\nLogin Code\r\nNTR3M\r\n', 'NTR3M'),
    ('Steam Guard code', 'Login Code\r\nFGHKT\r\nIf this wasn\'t you, change your password.', 'FGHKT'),
]
NONE = [
    ('Your order #482913 has shipped', 'Tracking number 1Z999AA10123456784. Total: 2 490 ₽. Thanks for your order!'),
    ('Счёт на оплату', 'Счёт № 2026-1043 на сумму 15 000 руб. до 20 октября 2026 г.'),
    ('Встреча в четверг', 'Ок, четверг в 18:00 подходит. Мой телефон +7 916 555 12 34.'),
    ('Weekly newsletter', 'In 2026 we shipped 1500 features. Use promo code SAVE20 for 20% off.'),
    ('Re: Trip plan', 'The flight is at 0730 on Saturday, gate 12, seat 14C.'),
    ('Your receipt', 'Payment confirmed. Amount 49.99 USD, ref 88442211.'),
    ('New sign in to Steam', 'New sign in to Steam\nAuthorized by: Steam Guard code from your email\nIf the details above look familiar, you can ignore this. STEAM SUPPORT'),
    ('Your verification code', 'Your code is below. GUARD it well, never share it. EARLY access starts today.'),
]


class Codes(unittest.TestCase):
    def test_codes(self):
        for subj, body, want in HAS:
            got = find(subj, body)
            self.assertEqual(got and got['code'], want, (subj, got))

    def test_not_codes(self):
        for subj, body in NONE:
            self.assertIsNone(find(subj, body), subj)


if __name__ == '__main__':
    unittest.main()
