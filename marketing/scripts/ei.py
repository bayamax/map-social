"""iPad Pro 12.9/13 (2064x2752) edamame set: 2 shots per language."""
import mk, sys, os
mk.W, mk.H = 2064, 2752
import e
e.W, e.H = mk.W, mk.H
from e import *
from PIL import Image, ImageDraw
W, H = mk.W, mk.H

def ipad(c, shot_path, width, top, cx=None, bezel=36, r=110):
    cx = cx or W // 2
    shot = Image.open(shot_path).convert('RGB')
    h = round(width * shot.size[1] / shot.size[0])
    shot = shot.resize((width, h), Image.LANCZOS)
    bw, bh = width + bezel * 2, h + bezel * 2
    x0 = cx - bw // 2
    shadow(c, (x0, top, x0 + bw, top + bh), r + bezel, blur=100, alpha=90, off=(0, 50))
    body = Image.new('RGBA', (bw, bh), (0, 0, 0, 0))
    ImageDraw.Draw(body).rounded_rectangle((0, 0, bw - 1, bh - 1), r + bezel, fill=(18, 18, 22, 255), outline=(70, 70, 78, 255), width=3)
    body.alpha_composite(rounded(shot, r), (bezel, bezel))
    c.alpha_composite(body, (x0, top))
    return (x0, top, x0 + bw, top + bh)

def P1(lang):
    hl, sub, chips = T[1][lang]
    c = gradient_bg(BG_TOP, BG_BOT, glow=(W // 2, 1700, 900, (176, 208, 110), 150))
    y = headline(c, hl, lang, 150, size=190 if lang == 'ja' else 180, color=INK + (255,), sub=sub, sub_size=62, sub_color=INK2 + (255,), spacing=1.1, x=140, align='center')
    # chips centered
    f = font(lang, 44); total = sum(int(f.getlength(t) + 68 + 46) for t, _ in chips) + 26 * (len(chips) - 1)
    chips_row(c, chips, lang, y + 40, x=(W - total) // 2, gap=26, size=44)
    ipad(c, f'src2/ipad_{lang}_globe.png', 1700, y + 250)
    fade_bottom(c, H - 320, BG_BOT, H - 30)
    return c

def P2(lang):
    hl, sub, (cap, capsub, v) = T[2][lang]
    c = gradient_bg(BG_TOP, BG_BOT, glow=(W // 2, 1600, 900, (176, 208, 110), 150))
    y = headline(c, hl, lang, 150, size=190 if lang == 'ja' else 180, color=INK + (255,), sub=sub, sub_size=62, sub_color=INK2 + (255,), spacing=1.1, x=140, align='center')
    ipad(c, f'src2/ipad_{lang}_globe.png', 1700, y + 140)
    live_card(c, 'frames/dotonbori.jpg', 1400, 1560, W // 2, cap, capsub, lang, viewers=v)
    fade_bottom(c, H - 320, BG_BOT, H - 30)
    return c

if __name__ == '__main__':
    langs = sys.argv[1].split(',') if len(sys.argv) > 1 else ['ja', 'en', 'ru']
    os.makedirs('e_out', exist_ok=True)
    for lang in langs:
        for n, fn in [(1, P1), (2, P2)]:
            p = f'e_out/P{n}_{lang}.png'; fn(lang).convert('RGB').save(p); print(p)
