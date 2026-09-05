"""Edamame set: pale creamy-green ground, deep-green headlines, icon-green accent. 1320x2868."""
from mk import *
import sys

# palette
BG_TOP = (236, 242, 214)   # edamame cream (slightly greener at top)
BG_BOT = (248, 247, 234)   # warm cream
INK = (28, 66, 40)         # deep green headline
INK2 = (86, 110, 84)       # muted green-grey sub copy
ACC = (140, 180, 60)       # icon young green
ACC_DARK = (98, 140, 40)
RED = (226, 44, 52)
CARD = (255, 255, 255)

def ebg(glow_y=1500):
    return gradient_bg(BG_TOP, BG_BOT, glow=(W // 2, glow_y, 720, (176, 208, 110), 150))

def efade(c, y=2350, y_to=None): fade_bottom(c, y, BG_BOT, y_to or H - 40)

def ephone(c, path, width, top, cx=W // 2):
    # lighter shadow than the dark sets (on cream, black shadow at 190 is too heavy)
    shot_im = Image.open(path).convert('RGB')
    h = round(width * shot_im.size[1] / shot_im.size[0])
    bezel, r = 22, 150
    x0 = cx - (width + bezel * 2) // 2
    shadow(c, (x0, top, x0 + width + bezel * 2, top + h + bezel * 2), r + bezel, blur=90, alpha=90, off=(0, 50))
    return phone(c, path, width, top, cx, bezel, r)

def ehead(c, lines, lang, sub=None, y=170, size=156, spacing=1.12, align='left'):
    # huge deep-green headline; sub in muted green
    return headline(c, lines, lang, y, size=size if lang == 'ja' else size - 6, color=INK + (255,),
                    sub=sub, sub_size=56 if lang == 'ja' else 54, sub_color=INK2 + (255,), spacing=spacing, align=align)

def echip(c, xy, text, lang, dot=None, size=40, dark=False):
    bg = (28, 66, 40, 235) if dark else (255, 255, 255, 230)
    fg = (255, 255, 255, 255) if dark else INK + (255,)
    f = font(lang, size); tw = f.getlength(text)
    x, y = xy; pad = 34; hgt = size + 40
    w = int(tw + pad * 2 + (46 if dot else 0))
    shadow(c, (x, y, x + w, y + hgt), hgt // 2, blur=30, alpha=60, off=(0, 14))
    d = ImageDraw.Draw(c)
    d.rounded_rectangle((x, y, x + w, y + hgt), hgt // 2, fill=bg)
    tx = x + pad
    if dot:
        d.ellipse((tx, y + hgt // 2 - 13, tx + 26, y + hgt // 2 + 13), fill=dot)
        tx += 46
    d.text((tx, y + hgt // 2), text, font=f, fill=fg, anchor='lm')
    return w, hgt

def chips_row(c, items, lang, y, x=108, gap=22, size=40):
    for text, dot in items:
        w, _ = echip(c, (x, y), text, lang, dot=dot, size=size)
        x += w + gap

# ---------------- copy ----------------
T = {
 1: {'ja': (['地球が', '動いてる。'], ['いま飛んでいる飛行機、宇宙ステーション、', '街のライブカメラ。世界のいまが地図に。'],
            [('飛行機', ACC_DARK), ('ISS', (60, 110, 200)), ('LIVE', RED), ('いま何人', INK)]),
     'en': (['The Earth', 'is moving.'], ['Planes in the air right now, the ISS,', 'live city cameras. The world as it happens.'],
            [('Planes', ACC_DARK), ('ISS', (60, 110, 200)), ('LIVE', RED), ('Who’s here', INK)]),
     'ru': (['Земля', 'живёт.'], ['Самолёты в небе прямо сейчас, МКС,', 'живые камеры городов. Мир — как он есть.'],
            [('Самолёты', ACC_DARK), ('МКС', (60, 110, 200)), ('LIVE', RED), ('Кто рядом', INK)])},
 2: {'ja': (['世界の', 'ライブ映像。'], ['道頓堀、渋谷、台北、ソウル…', 'ピンをタップすれば、その街のいま。'], ('大阪 道頓堀', '大阪府 · グリコ看板の前', 'いま3人が見ています')),
     'en': (['Live video,', 'worldwide.'], ['Dotonbori, Shibuya, Taipei, Seoul…', 'Tap a pin and see that city right now.'], ('Osaka · Dotonbori', 'Japan · Glico sign', '3 watching now')),
     'ru': (['Живое видео', 'со всего мира.'], ['Дотонбори, Сибуя, Тайбэй, Сеул…', 'Нажмите на пин — и вы там прямо сейчас.'], ('Осака · Дотонбори', 'Япония · Вывеска Glico', 'Сейчас смотрят: 3'))},
 3: {'ja': (['街を3Dで、', '飛行機まで。'], ['羽田に降りてくる機体も、走るバスも、', '本物のデータでそのまま動く。'], None),
     'en': (['3D cities,', 'down to the planes.'], ['Jets landing at Haneda, buses on the road —', 'real data, moving in real time.'], None),
     'ru': (['Города в 3D,', 'вплоть до самолётов.'], ['Самолёты на посадке в Ханэде, автобусы —', 'реальные данные, в реальном времени.'], None)},
 4: {'ja': (['世界中に、', 'カメラ。'], ['ニューヨークからナイロビまで60以上。', '登録なしで、開いた瞬間から。'], ['ニューヨーク', '渋谷', 'ソウル', '台北', 'パリ', 'シドニー']),
     'en': (['Cameras,', 'everywhere.'], ['60+ live cameras, New York to Nairobi.', 'No sign-up. Just open and watch.'], ['New York', 'Shibuya', 'Seoul', 'Taipei', 'Paris', 'Sydney']),
     'ru': (['Камеры', 'по всему миру.'], ['Более 60 камер — от Нью-Йорка до Найроби.', 'Без регистрации. Открыли — и смотрите.'], ['Нью-Йорк', 'Сибуя', 'Сеул', 'Тайбэй', 'Париж', 'Сидней'])},
 5: {'ja': (['いま誰かが、', '地球を散歩中。'], ['同じ地図を見ている人が見える。', '同じ景色を見ながら、話せる。'], [('sora', '台北のカメラ、夜景がきれい'), ('yuzu_tabi', '羽田の上、飛行機すごい数')]),
     'en': (['Someone is', 'out there, too.'], ['See who’s looking at the same map.', 'Talk with people watching the same view.'], [('sora', 'Taipei cam looks gorgeous tonight'), ('yuzu_tabi', 'So many planes over Haneda')]),
     'ru': (['Кто-то тоже', 'гуляет по Земле.'], ['Видно, кто смотрит на ту же карту.', 'Общайтесь с теми, кто видит то же самое.'], [('sora', 'Камера в Тайбэе — красота'), ('yuzu_tabi', 'Над Ханэдой столько самолётов')])},
 6: {'ja': (['登録なし。', '開いたら、', 'もう世界。'], ['アカウントは投稿するときだけ。', '見るだけなら、すぐ。'], None),
     'en': (['No sign-up.', 'Open, and', 'you’re there.'], ['An account only when you post.', 'Watching is instant.'], None),
     'ru': (['Без регистрации.', 'Открыли —', 'и вы там.'], ['Аккаунт нужен только для постов.', 'Смотреть можно сразу.'], None)},
}
S = lambda lang, key: f'src2/{lang}_{key}.png'

def E1(lang):
    hl, sub, chips = T[1][lang]
    c = ebg(1700)
    y = ehead(c, hl, lang, sub)
    chips_row(c, chips, lang, y + 40)
    ephone(c, S(lang, 'globe'), 1060, y + 230)
    efade(c, 2560)
    return c

def E2(lang):
    hl, sub, (cap, capsub, v) = T[2][lang]
    c = ebg(1600)
    y = ehead(c, hl, lang, sub)
    ephone(c, S(lang, 'globe'), 900, y + 120)
    live_card(c, 'frames/dotonbori.jpg', 1120, 1500, W // 2, cap, capsub, lang, viewers=v)
    efade(c, 2480)
    return c

def lens(c, shot_path, src_xy, src_r, cx, cy, R, ring=(255, 255, 255, 255)):
    """Magnifier: circular crop of the raw shot around src_xy (radius src_r), blown up to radius R at (cx, cy)."""
    im = Image.open(shot_path).convert('RGBA')
    sx, sy = src_xy
    crop = im.crop((sx - src_r, sy - src_r, sx + src_r, sy + src_r)).resize((2 * R, 2 * R), Image.LANCZOS)
    m = Image.new('L', (2 * R, 2 * R), 0); ImageDraw.Draw(m).ellipse((0, 0, 2 * R - 1, 2 * R - 1), fill=255)
    crop.putalpha(m)
    layer = Image.new('RGBA', c.size, (0, 0, 0, 0))
    ImageDraw.Draw(layer).ellipse((cx - R - 10, cy - R + 30, cx + R + 10, cy + R + 60), fill=(0, 0, 0, 110))
    c.alpha_composite(layer.filter(ImageFilter.GaussianBlur(50)))
    d = ImageDraw.Draw(c)
    d.ellipse((cx - R - 12, cy - R - 12, cx + R + 12, cy + R + 12), fill=ring)
    c.alpha_composite(crop, (cx - R, cy - R))

def E3(lang):
    hl, sub, _ = T[3][lang]
    c = ebg(1700)
    y = ehead(c, hl, lang, sub)
    pw, top = 1060, y + 120
    box = ephone(c, S(lang, 'haneda'), pw, top)
    # phone content scale: raw 1320 -> pw
    k = pw / 1320.0
    # JAL512 is at ~(187,1640) in the raw capture; lens sits over the lower-left of the phone
    px, py = box[0] + 22 + 187 * k, top + 22 + 1640 * k
    R = 300; cx, cy = 400, min(H - 420, int(py) + 120)
    d = ImageDraw.Draw(c)
    d.line((px, py, cx, cy), fill=(255, 255, 255, 230), width=6)
    d.ellipse((px - 14, py - 14, px + 14, py + 14), fill=(255, 255, 255, 255))
    lens(c, S(lang, "haneda"), (225, 1640), 130, cx, cy, R)
    cap = {'ja': '高度ぶん浮いて、影が落ちる', 'en': 'Lifted by altitude, shadow on the ground', 'ru': 'Высота — в подъёме, тень — на земле'}[lang]
    echip(c, (cx - R + 20, cy + R + 50), cap, lang, dot=ACC_DARK, size=36, dark=True)
    efade(c, 2620, H)
    return c

def E4(lang):
    hl, sub, labels = T[4][lang]
    c = ebg(1800)
    y = ehead(c, hl, lang, sub)
    frames = ['nyc', 'shibuya', 'seoul', 'taipei', 'paris', 'sydney']
    gw, gh = 560, 350; gx0 = (W - (gw * 2 + 40)) // 2; gy = y + 120
    for i, (fr, lb) in enumerate(zip(frames, labels)):
        x = gx0 + (i % 2) * (gw + 40); yy = gy + (i // 2) * (gh + 40)
        mini_card(c, f'frames/{fr}.jpg', gw, (x, yy), lb, lang, r=44)
    ephone(c, S(lang, 'cam'), 760, gy + 3 * (gh + 40) + 20)
    efade(c, 2500)
    return c

def E5(lang):
    hl, sub, msgs = T[5][lang]
    c = ebg(1600)
    y = ehead(c, hl, lang, sub)
    ephone(c, S(lang, 'globe'), 960, y + 120)
    by = 1750
    bubble(c, (90, by), msgs[0][0], msgs[0][1], lang)
    w1, _ = bubble(c, (W - 90 - 800, by + 210), msgs[1][0], msgs[1][1], lang, width=800, bg=(28, 66, 40, 245), fg=(255, 255, 255, 255), name_fg=(170, 200, 150, 255))
    efade(c, 2450)
    return c

def E6(lang):
    hl, sub, _ = T[6][lang]
    c = ebg(1900)
    y = ehead(c, hl, lang, sub, y=260, size=172)
    ephone(c, S(lang, 'cam'), 1000, y + 160)
    efade(c, 2560)
    return c

BUILD = {1: E1, 2: E2, 3: E3, 4: E4, 5: E5, 6: E6}
if __name__ == '__main__':
    nums = [int(a) for a in sys.argv[1].split(',')] if len(sys.argv) > 1 else list(BUILD)
    langs = sys.argv[2].split(',') if len(sys.argv) > 2 else ['ja', 'en', 'ru']
    os.makedirs('e_out', exist_ok=True)
    for n in nums:
        for lang in langs:
            im = BUILD[n](lang).convert('RGB')
            p = f'e_out/E{n}_{lang}.png'; im.save(p); print(p)
