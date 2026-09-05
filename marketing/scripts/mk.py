"""Designed App Store screenshots for Map Social (1320x2868)."""
from PIL import Image, ImageDraw, ImageFilter, ImageFont
import math, os

W, H = 1320, 2868
FJ = '/System/Library/Fonts/ヒラギノ角ゴシック %s.ttc'
def fja(size, w='W8'): return ImageFont.truetype(FJ % w, size, index=0)
def fen(size, weight='Heavy'):
    f = ImageFont.truetype('/System/Library/Fonts/SFNS.ttf', size)
    f.set_variation_by_name(weight); return f
def font(lang, size, heavy=True):
    return fja(size, 'W8' if heavy else 'W5') if lang == 'ja' else fen(size, 'Heavy' if heavy else 'Medium')

def gradient_bg(top, bottom, glow=None):
    bg = Image.new('RGB', (W, H), top)
    px = bg.load()
    for y in range(H):
        t = y / H
        c = tuple(int(top[i] * (1 - t) + bottom[i] * t) for i in range(3))
        for x in range(W): px[x, y] = c
    if glow:
        (gx, gy, gr, gc, ga) = glow
        layer = Image.new('RGBA', (W, H), (0, 0, 0, 0))
        d = ImageDraw.Draw(layer)
        d.ellipse((gx - gr, gy - gr, gx + gr, gy + gr), fill=gc + (ga,))
        layer = layer.filter(ImageFilter.GaussianBlur(220))
        bg = Image.alpha_composite(bg.convert('RGBA'), layer).convert('RGB')
    return bg.convert('RGBA')

def rounded(im, r):
    m = Image.new('L', im.size, 0)
    ImageDraw.Draw(m).rounded_rectangle((0, 0, im.size[0] - 1, im.size[1] - 1), r, fill=255)
    out = im.convert('RGBA'); out.putalpha(m); return out

def shadow(canvas, box, r, blur=60, alpha=150, off=(0, 40)):
    x0, y0, x1, y1 = box
    layer = Image.new('RGBA', canvas.size, (0, 0, 0, 0))
    ImageDraw.Draw(layer).rounded_rectangle((x0 + off[0], y0 + off[1], x1 + off[0], y1 + off[1]), r, fill=(0, 0, 0, alpha))
    layer = layer.filter(ImageFilter.GaussianBlur(blur))
    canvas.alpha_composite(layer)

def phone(canvas, shot_path, width, top, cx=W // 2, bezel=22, r=150):
    shot = Image.open(shot_path).convert('RGB')
    h = round(width * shot.size[1] / shot.size[0])
    shot = shot.resize((width, h), Image.LANCZOS)
    body_w, body_h = width + bezel * 2, h + bezel * 2
    x0 = cx - body_w // 2; y0 = top
    shadow(canvas, (x0, y0, x0 + body_w, y0 + body_h), r + bezel, blur=80, alpha=190, off=(0, 50))
    body = Image.new('RGBA', (body_w, body_h), (0, 0, 0, 0))
    ImageDraw.Draw(body).rounded_rectangle((0, 0, body_w - 1, body_h - 1), r + bezel, fill=(18, 18, 22, 255), outline=(70, 70, 78, 255), width=3)
    body.alpha_composite(rounded(shot, r), (bezel, bezel))
    canvas.alpha_composite(body, (x0, y0))
    return (x0, y0, x0 + body_w, y0 + body_h)

def live_pill(canvas, xy, lang='ja', text='LIVE', size=44):
    f = fen(size, 'Bold')
    tw = f.getlength(text)
    pad = 26; hgt = size + 30
    x, y = xy
    w = int(tw + pad * 2 + 40)
    d = ImageDraw.Draw(canvas)
    d.rounded_rectangle((x, y, x + w, y + hgt), hgt // 2, fill=(235, 40, 50, 255))
    d.ellipse((x + pad, y + hgt // 2 - 11, x + pad + 22, y + hgt // 2 + 11), fill=(255, 255, 255, 255))
    d.text((x + pad + 40, y + hgt // 2), text, font=f, fill='white', anchor='lm')
    return w, hgt

def live_card(canvas, frame_path, width, top, cx, caption, sub, lang, r=56, viewers=None):
    fr = Image.open(frame_path).convert('RGB')
    # crop to 16:10
    fw, fh = fr.size; th = round(fw * 10 / 16)
    fr = fr.crop((0, (fh - th) // 2, fw, (fh - th) // 2 + th))
    h = round(width * th / fw)
    fr = fr.resize((width, h), Image.LANCZOS)
    cap_h = 150
    card = Image.new('RGBA', (width, h + cap_h), (255, 255, 255, 0))
    ImageDraw.Draw(card).rounded_rectangle((0, 0, width - 1, h + cap_h - 1), r, fill=(255, 255, 255, 255))
    # image with top corners rounded
    img = rounded(fr, r)
    # square off bottom corners by pasting a second time offset (simple: paste over rect)
    card.alpha_composite(img, (0, 0))
    ImageDraw.Draw(card).rectangle((0, h - r, width, h), fill=(0, 0, 0, 0))
    card.alpha_composite(fr.convert('RGBA').crop((0, h - r, width, h)), (0, h - r))
    d = ImageDraw.Draw(card)
    d.text((44, h + 50), caption, font=font(lang, 46), fill=(20, 22, 30, 255), anchor='lm')
    d.text((44, h + 108), sub, font=font(lang, 34, heavy=False), fill=(110, 115, 130, 255), anchor='lm')
    if viewers:
        fv = font(lang, 34, heavy=False); tw = fv.getlength(viewers)
        d.ellipse((width - 44 - tw - 34, h + 50 - 9, width - 44 - tw - 16, h + 50 + 9), fill=(235, 40, 50, 255))
        d.text((width - 44, h + 50), viewers, font=fv, fill=(235, 40, 50, 255), anchor='rm')
    x0 = cx - width // 2
    shadow(canvas, (x0, top, x0 + width, top + h + cap_h), r, blur=70, alpha=200, off=(0, 40))
    canvas.alpha_composite(card, (x0, top))
    live_pill(canvas, (x0 + 40, top + 40))
    return (x0, top, x0 + width, top + h + cap_h)

def headline(canvas, lines, lang, y, size=132, color=(255, 255, 255, 255), sub=None, sub_size=50, sub_color=(190, 198, 230, 255), x=108, spacing=1.18, align='left'):
    d = ImageDraw.Draw(canvas)
    f = font(lang, size)
    while size > 60 and max(f.getlength(ln) for ln in lines) > W - 2 * x:
        size -= 4; f = font(lang, size)
    for ln in lines:
        if align == 'center':
            d.text((W // 2, y), ln, font=f, fill=color, anchor='ma')
        else:
            d.text((x, y), ln, font=f, fill=color, anchor='la')
        y += int(size * spacing)
    if sub:
        y += 26
        fs = font(lang, sub_size, heavy=False)
        for ln in sub:
            if align == 'center':
                d.text((W // 2, y), ln, font=fs, fill=sub_color, anchor='ma')
            else:
                d.text((x, y), ln, font=fs, fill=sub_color, anchor='la')
            y += int(sub_size * 1.5)
    return y

def chip(canvas, xy, text, lang, color=(255, 255, 255, 255), bg=(255, 255, 255, 40), dot=None, size=40):
    f = font(lang, size)
    tw = f.getlength(text)
    x, y = xy; pad = 34; hgt = size + 40
    w = int(tw + pad * 2 + (46 if dot else 0))
    layer = Image.new('RGBA', canvas.size, (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    d.rounded_rectangle((x, y, x + w, y + hgt), hgt // 2, fill=bg, outline=(255, 255, 255, 90), width=2)
    canvas.alpha_composite(layer)
    d = ImageDraw.Draw(canvas)
    tx = x + pad
    if dot:
        d.ellipse((tx, y + hgt // 2 - 13, tx + 26, y + hgt // 2 + 13), fill=dot)
        tx += 46
    d.text((tx, y + hgt // 2), text, font=f, fill=color, anchor='lm')
    return w, hgt

def fade_bottom(canvas, y_from, color, y_to=None):
    """Fade the canvas into `color` from y_from to y_to (hides UI noise at the bottom)."""
    y_to = y_to or H
    layer = Image.new('RGBA', (W, H), (0, 0, 0, 0))
    px = layer.load()
    for y in range(y_from, H):
        a = min(255, int(255 * (y - y_from) / max(1, (y_to - y_from))))
        for x in range(W): px[x, y] = color + (a,)
    canvas.alpha_composite(layer)

def mini_card(canvas, frame_path, width, xy, label, lang, r=36):
    fr = Image.open(frame_path).convert('RGB')
    fw, fh = fr.size; th = round(fw * 10 / 16)
    fr = fr.crop((0, (fh - th) // 2, fw, (fh - th) // 2 + th))
    h = round(width * th / fw)
    fr = fr.resize((width, h), Image.LANCZOS)
    x, y = xy
    shadow(canvas, (x, y, x + width, y + h), r, blur=40, alpha=170, off=(0, 24))
    card = rounded(fr, r)
    # label strip at bottom (dark gradient)
    grad = Image.new('RGBA', (width, h), (0, 0, 0, 0)); gp = grad.load()
    m = card.split()[3].load()
    for yy in range(h):
        a = int(max(0, (yy - h * 0.55) / (h * 0.45)) * 200)
        for xx in range(width): gp[xx, yy] = (0, 0, 0, min(a, m[xx, yy]))
    card.alpha_composite(grad)
    d = ImageDraw.Draw(card)
    d.text((28, h - 30), label, font=font(lang, 34), fill='white', anchor='lm')
    canvas.alpha_composite(card, (x, y))
    live_pill(canvas, (x + 22, y + 22), size=28)

def bubble(canvas, xy, name, text, lang, width=None, bg=(255, 255, 255, 245), fg=(20, 22, 30, 255), name_fg=(120, 125, 145, 255)):
    f = font(lang, 42, heavy=False); fn = font(lang, 30)
    tw = int(f.getlength(text)); width = width or tw + 80
    hgt = 150
    x, y = xy
    shadow(canvas, (x, y, x + width, y + hgt), 40, blur=40, alpha=150, off=(0, 20))
    d = ImageDraw.Draw(canvas)
    d.rounded_rectangle((x, y, x + width, y + hgt), 40, fill=bg)
    d.text((x + 36, y + 42), name, font=fn, fill=name_fg, anchor='lm')
    d.text((x + 36, y + 100), text, font=f, fill=fg, anchor='lm')
    return width, hgt

def brand(canvas, lang, y=H - 120, color=(255, 255, 255, 140)):
    d = ImageDraw.Draw(canvas)
    d.text((W // 2, y), 'Map Social', font=fen(40, 'Semibold'), fill=color, anchor='mm')
