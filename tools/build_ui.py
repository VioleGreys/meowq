#!/usr/bin/env python3
"""Ресурсы интерфейса «Досье и архив» → assets/ui/.

Источники (скачиваются в --src, по умолчанию /tmp/ui_src):
  * ambientCG (CC0): картон Cardboard002, кожа Leather026, износ
    SurfaceImperfections001/013, Scratches003/005, ржавчина Rust009;
  * OpenGameArt: лист «old page» (CC0, horror-game-note-page-background-old-paper-png),
    мятая бумага hjm «wrinkled paper» (CC BY, автор hjm, damaged-papers-four-sorts);
  * OpenClipart (общественное достояние): скрепка 333299;
  * Poly Haven (CC0): 3D-модель «clipboard» — рендер сверху в Godot
    (tools/ui_render; запускается этим скриптом).
Шрифты — assets/fonts (OFL). Иконки — assets/icons/icons.json (CC BY 3.0).

  pip install pillow cairosvg
  python3 tools/build_ui.py [--src /tmp/ui_src] [--godot godot]
"""
import argparse
import io
import json
import os
import random
import subprocess
import urllib.request
import zipfile

import cairosvg
from PIL import Image, ImageChops, ImageDraw, ImageEnhance, ImageFilter, ImageFont, ImageOps

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
OUT = os.path.join(ROOT, "assets", "ui")
UA = "Mozilla/5.0 (X11; Linux x86_64) MeowqAssetBuilder/1.0"
INK = (38, 30, 22)
INK_SOFT = (78, 64, 48)
RED = (168, 32, 28)
BLUE = (40, 60, 140)
F_OSW = os.path.join(ROOT, "assets/fonts/Oswald.ttf")
F_MONO = os.path.join(ROOT, "assets/fonts/IBMPlexMono-Regular.ttf")
F_MONO_B = os.path.join(ROOT, "assets/fonts/IBMPlexMono-SemiBold.ttf")

AMBIENT = ["Cardboard002", "Leather026", "SurfaceImperfections001", "SurfaceImperfections013", "Scratches003",
           "Scratches005", "Rust009"]
OGA = {
    "oldpage.png": "https://opengameart.org/sites/default/files/oldpage.png",
    "wrinkled.png": "https://opengameart.org/sites/default/files/hjm-wrinkled_paper.png",
}
CLIP_URL = "https://openclipart.org/image/800px/333299"

# пункты бокового меню: id, иконка, подпись (порядок как в Hud._build_side)
MENU = [("focus", "focus", "Фокусы"), ("army", "army", "Армия"), ("navy", "fleet", "Флот и авиация"),
        ("production", "factory", "Производство"), ("research", "research", "Наука"),
        ("build", "civ", "Стройка"), ("diplomacy", "diplomacy", "Дипломатия"), ("all", "inf", "Все войска"),
        ("mapmode", "map", "Режим карты"), ("settings", "settings", "Настройки")]
FOLDER_COLORS = [((200, 165, 100), 0.30), ((110, 112, 62), 0.55), ((96, 108, 116), 0.55), ((128, 78, 50), 0.5),
                 ((176, 150, 104), 0.35)]
SRC = "/tmp/ui_src"


# --- загрузка исходников ----------------------------------------------------------------

def fetch(url, path):
    if os.path.exists(path):
        return
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    with urllib.request.urlopen(req, timeout=120) as r:
        data = r.read()
    with open(path, "wb") as f:
        f.write(data)


def download(godot):
    os.makedirs(SRC, exist_ok=True)
    for a in AMBIENT:
        d = os.path.join(SRC, a)
        if not os.path.isdir(d):
            z = os.path.join(SRC, a + ".zip")
            fetch(f"https://ambientcg.com/get?file={a}_1K-JPG.zip", z)
            zipfile.ZipFile(z).extractall(d)
    for name, url in OGA.items():
        fetch(url, os.path.join(SRC, name))
    fetch(CLIP_URL, os.path.join(SRC, "paperclip.png"))
    render = os.path.join(SRC, "clipboard_render.png")
    if not os.path.exists(render):
        api = json.loads(urllib.request.urlopen(urllib.request.Request(
            "https://api.polyhaven.com/files/clipboard", headers={"User-Agent": UA})).read())
        g = api["gltf"]["2k"]["gltf"]
        md = os.path.join(SRC, "clipboard")
        os.makedirs(os.path.join(md, "textures"), exist_ok=True)
        fetch(g["url"], os.path.join(md, "clipboard.gltf"))
        for k, v in g["include"].items():
            fetch(v["url"], os.path.join(md, k))
        subprocess.run(["xvfb-run", "-a", godot, "--rendering-driver", "opengl3", "--path",
                        os.path.join(ROOT, "tools/ui_render"), "--", os.path.join(md, "clipboard.gltf"), render,
                        "90", "0", "1600"], check=True, capture_output=True)


# --- общие помощники -------------------------------------------------------------------

def font(path, size):
    return ImageFont.truetype(path, size)


def amb(name, kind="Color"):
    im = Image.open(f"{SRC}/{name}/{name}_1K-JPG_{kind}.jpg")
    return im.convert("L") if kind == "Opacity" else im.convert("RGB")


def tiled(im, size, seed=0):
    rnd = random.Random(seed)
    ox, oy = rnd.randint(0, im.width - 1), rnd.randint(0, im.height - 1)
    big = Image.new(im.mode, (size[0] + im.width, size[1] + im.height))
    for y in range(0, big.height, im.height):
        for x in range(0, big.width, im.width):
            big.paste(im, (x, y))
    return big.crop((ox, oy, ox + size[0], oy + size[1]))


def cardboard(size, col, amt, bright=1.0, seed=0):
    out = tiled(amb("Cardboard002"), size, seed)
    out = Image.blend(out, Image.new("RGB", size, col), amt)
    return ImageEnhance.Brightness(out).enhance(bright).convert("RGBA")


def rounded(size, r):
    m = Image.new("L", size, 0)
    ImageDraw.Draw(m).rounded_rectangle((0, 0, size[0] - 1, size[1] - 1), r, fill=255)
    return m


def edge_mask(alpha, width, seed):
    er = alpha.filter(ImageFilter.MinFilter(width | 1))
    band = ImageChops.subtract(alpha, er).filter(ImageFilter.GaussianBlur(width * 0.4))
    n = ImageOps.autocontrast(tiled(amb("SurfaceImperfections001", "Opacity"), alpha.size, seed))
    return ImageChops.multiply(band, n.point(lambda v: min(255, v * 2 + 40)))


def age(img, seed, stains=0.45, scratches=0.6, edge=12, edge_col=(222, 196, 150), dirt_col=(60, 40, 20)):
    w, h = img.size
    a = img.getchannel("A")
    rgb = img.convert("RGB")
    st = ImageChops.add(tiled(amb("SurfaceImperfections001", "Opacity"), (w, h), seed),
                        tiled(amb("SurfaceImperfections013", "Opacity"), (w, h), seed + 1))
    rgb = Image.composite(Image.new("RGB", (w, h), dirt_col), rgb, st.point(lambda v: int(v * stains)))
    sc = ImageOps.autocontrast(ImageChops.lighter(tiled(amb("Scratches003", "Opacity"), (w, h), seed + 2),
                                                  tiled(amb("Scratches005", "Opacity"), (w, h), seed + 3)))
    rgb = Image.composite(Image.new("RGB", (w, h), edge_col), rgb, sc.point(lambda v: int(v * scratches)))
    em = edge_mask(a, edge, seed + 4)
    rgb = Image.composite(Image.new("RGB", (w, h), edge_col), rgb, em.point(lambda v: int(v * 0.85)))
    out = rgb.convert("RGBA")
    out.putalpha(a)
    return out


def torn_corner(img, seed, size=40):
    rnd = random.Random(seed)
    w, h = img.size
    corner = rnd.choice(["tr", "br"])
    pts = []
    for i in range(10):
        t = i / 9
        j = rnd.uniform(-5, 5)
        pts.append((w - size * (1 - t) + j * 0.3, (size * t if corner == "tr" else h - size * t) + j))
    a = img.getchannel("A")
    ImageDraw.Draw(a).polygon(pts + [(w, 0) if corner == "tr" else (w, h)], fill=0)
    ImageDraw.Draw(img).line(pts, fill=(230, 210, 170, 255), width=3)
    img.putalpha(a)
    return img


def sheet(w, h, crumpled=False):
    base = Image.open(os.path.join(SRC, "oldpage.png")).convert("RGBA").resize((w, h), Image.LANCZOS)
    if not crumpled:
        return base
    wr = Image.open(os.path.join(SRC, "wrinkled.png")).convert("L").resize((w, h), Image.LANCZOS)
    wr = ImageOps.autocontrast(wr, cutoff=2).point(lambda v: int(150 + v * 0.42))
    rgb = ImageChops.multiply(base.convert("RGB"), Image.merge("RGB", (wr, wr, wr)))
    out = ImageEnhance.Brightness(rgb, ).enhance(1.12).convert("RGBA")
    out.putalpha(base.getchannel("A"))
    return out


ICONS = json.load(open(os.path.join(ROOT, "assets/icons/icons.json")))["icons"]


def icon(name, px, color):
    png = cairosvg.svg2png(bytestring=ICONS[name].encode(), output_width=px, output_height=px)
    im = Image.open(io.BytesIO(png)).convert("RGBA")
    col = Image.new("RGBA", im.size, color + (255,))
    col.putalpha(im.getchannel("A"))
    return col


def grunge(size, seed=1):
    g = ImageOps.autocontrast(ImageOps.grayscale(tiled(amb("SurfaceImperfections013"), size, seed)))
    noise = Image.effect_noise(size, 50).filter(ImageFilter.GaussianBlur(0.6))
    m = ImageChops.add(ImageOps.invert(g), noise, scale=2.0)
    return m.point(lambda v: 255 if v > 60 else int(v * 3))


def stamp(text, w, h, color, seed):
    im = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    d.rounded_rectangle((3, 3, w - 4, h - 4), 8, outline=color + (255,), width=5)
    d.rounded_rectangle((11, 11, w - 12, h - 12), 5, outline=color + (255,), width=2)
    f = font(F_OSW, int(h * 0.48))
    while d.textlength(text, font=f) > w - 34:
        f = font(F_OSW, f.size - 2)
    tw = d.textlength(text, font=f)
    d.text(((w - tw) / 2, h * 0.17), text, font=f, fill=color + (255,))
    im.putalpha(ImageChops.multiply(im.getchannel("A"), grunge((w, h), seed)).point(lambda v: int(v * 0.88)))
    return im


def save(img, name):
    p = os.path.join(OUT, name)
    if name.endswith(".jpg"):
        img.convert("RGB").save(p, quality=86, optimize=True)
    else:
        img.save(p, optimize=True)
    print("  ", name, img.size)


# --- элементы -------------------------------------------------------------------------

def build_clipboard():
    im = Image.open(os.path.join(SRC, "clipboard_render.png")).convert("RGBA")
    im = im.crop(im.getbbox())
    h = 980
    w = int(im.width * h / im.height)
    im = im.resize((w, h), Image.LANCZOS)
    g = ImageOps.grayscale(im)
    top = Image.new("L", im.size, 0)
    ImageDraw.Draw(top).rectangle((0, 0, w, int(h * 0.17)), fill=255)
    clip_a = ImageChops.multiply(g.point(lambda v: 255 if v < 95 else 0), top)
    clip_a = ImageChops.multiply(clip_a.filter(ImageFilter.MaxFilter(5)).filter(ImageFilter.GaussianBlur(1)),
                                 im.getchannel("A"))
    a = im.getchannel("A")
    gg = ImageOps.autocontrast(ImageOps.grayscale(im.convert("RGB")), cutoff=1)
    wood = ImageOps.colorize(gg, black=(34, 22, 12), mid=(92, 62, 36), white=(150, 112, 70))
    out = Image.composite(im.convert("RGB"), wood, clip_a).convert("RGBA")
    out.putalpha(a)
    out = age(out, 5, stains=0.55, scratches=0.55, edge=16, edge_col=(176, 140, 96), dirt_col=(25, 15, 8))
    rust = tiled(amb("Rust009"), out.size, 12)
    rm = ImageChops.multiply(clip_a, tiled(amb("SurfaceImperfections001", "Opacity"), out.size, 13)
                             .point(lambda v: 255 if v > 110 else int(v * 1.2)))
    out = Image.composite(rust.convert("RGBA"), out, rm.point(lambda v: int(v * 0.75)))
    out.putalpha(a)
    clip = out.copy()
    clip.putalpha(clip_a)
    save(out, "clipboard.png")
    save(clip, "clipboard_clip.png")


def build_sheets():
    save(sheet(600, 830), "sheet.png")
    save(sheet(600, 830, True), "sheet_crumpled.png")
    # карточка-кнопка (растягивается по 9 частям) и нажатая — темнее, с чернильной галочкой
    c = sheet(320, 64)
    d = ImageDraw.Draw(c)
    d.rectangle((0, 0, 319, 63), outline=INK_SOFT + (200,), width=2)
    save(c, "card.png")
    cp = ImageEnhance.Brightness(c.convert("RGB")).enhance(0.86).convert("RGBA")
    ImageDraw.Draw(cp).rectangle((0, 0, 319, 63), outline=INK + (255,), width=3)
    save(cp, "card_pressed.png")
    # учётная карточка с линовкой (нижняя панель)
    ic = sheet(560, 240)
    d = ImageDraw.Draw(ic)
    d.line((0, 46, 560, 46), fill=(190, 70, 60, 200), width=2)
    for yy in range(76, 236, 30):
        d.line((10, yy, 550, yy), fill=(120, 140, 170, 80), width=1)
    save(age(ic, 33, 0.25, 0.25, 6, (250, 240, 220), (90, 70, 45)), "index_card.png")
    # заглушка без фото: рамка с уголками и штамп
    ph = sheet(240, 320)
    d = ImageDraw.Draw(ph)
    d.rectangle((14, 14, 225, 305), outline=INK_SOFT + (160,), width=2)
    for x, y in ((14, 14), (225, 14), (14, 305), (225, 305)):
        sx = 1 if x < 100 else -1
        sy = 1 if y < 100 else -1
        d.polygon([(x, y), (x + 34 * sx, y), (x, y + 34 * sy)], fill=(40, 30, 22, 230))
    st = stamp("ФОТО НЕТ", 200, 70, RED, 41).rotate(18, expand=True, resample=Image.BICUBIC)
    ph.alpha_composite(st, ((240 - st.width) // 2, (320 - st.height) // 2))
    save(ph, "nophoto.png")


def build_spines():
    w, h = 470, 84
    for i, (mid, ic, label) in enumerate(MENU):
        seed = 100 + i * 7
        col, amt = FOLDER_COLORS[i % len(FOLDER_COLORS)]
        f = cardboard((w, h), col, amt, 0.92, seed)
        d = ImageDraw.Draw(f)
        d.line((w - 116, 0, w - 116, h), fill=(140, 40, 32, 200), width=4)
        f.putalpha(rounded((w, h), 5))
        f = age(f, seed, 0.4, 0.5, 10, (214, 188, 140), (50, 34, 18))
        lw, lh = 84, h - 20
        lab = sheet(lw, lh)
        ImageDraw.Draw(lab).rectangle((0, 0, lw - 1, lh - 1), outline=INK_SOFT, width=2)
        ip = min(lw, lh) - 22
        lab.alpha_composite(icon(ic, ip, (46, 36, 26)), ((lw - ip) // 2, (lh - ip) // 2))
        lab = torn_corner(age(lab, seed + 1, 0.3, 0.3, 6, (250, 240, 220), (90, 70, 45)), seed + 2, 18)
        f.alpha_composite(lab, (w - lw - 10, 10))
        fl = font(F_MONO_B, 18)
        tw = int(d.textlength(label.upper(), font=fl)) + 22
        strip = sheet(tw, 30)
        ImageDraw.Draw(strip).text((11, 3), label.upper(), font=fl, fill=(40, 30, 20))
        strip = age(strip, seed + 3, 0.25, 0.25, 5, (250, 240, 220), (90, 70, 45))
        f.alpha_composite(strip, (w - 130 - tw, (h - 30) // 2))
        if i % 3 == 0:
            f = torn_corner(f, seed + 5, 26)
        save(f, f"spine_{mid}.png")


def build_dossier():
    """створки картонной папки-дела: левая (обложка изнутри, завязки) и правая"""
    W, H = 760, 980
    for k, name in enumerate(["dossier_left.png", "dossier_right.png"]):
        p = cardboard((W, H), (186, 150, 96), 0.35, 0.9 if k == 0 else 0.96, 70 + k)
        p.putalpha(rounded((W, H), 8))
        p = age(p, 9 + k * 11, 0.5, 0.5, 14, (222, 196, 150), (52, 36, 18))
        d = ImageDraw.Draw(p)
        # сгиб — у внутреннего края створки
        xs = range(W - 10, W) if k == 0 else range(0, 10)
        for i, x in enumerate(xs):
            t = i / 9 if k == 0 else 1 - i / 9
            d.line((x, 0, x, H), fill=(30, 20, 10, int(110 * t)))
        # завязки у внешнего края
        x0 = 6 if k == 0 else W - 6
        dirn = -1 if k == 0 else 1
        for yy in (H * 0.42, H * 0.58):
            d.line((x0, yy, x0 - dirn * 90, yy + 18), fill=(236, 226, 204, 255), width=9)
            d.line((x0, yy, x0 - dirn * 90, yy + 18), fill=(188, 176, 148, 255), width=3)
        save(p, name)
    # цельный разворот (как в макете): две створки встык, сгиб посередине, завязки
    SW, SH = 1520, 980
    sp = Image.new("RGBA", (SW, SH), (0, 0, 0, 0))
    for k in range(2):
        half = cardboard((SW // 2, SH), (186, 150, 96), 0.35, 0.9 if k == 0 else 0.96, 70 + k)
        # скруглены только внешние углы: створки сходятся встык без щели
        m = Image.new("L", (SW // 2, SH), 0)
        ImageDraw.Draw(m).rounded_rectangle((0, 0, SW // 2 - 1, SH - 1), 8, fill=255,
                                            corners=(k == 0, k == 1, k == 1, k == 0))
        half.putalpha(m)
        half = age(half, 9 + k * 11, 0.5, 0.5, 14, (222, 196, 150), (52, 36, 18))
        sp.alpha_composite(half, (k * SW // 2, 0))
    # сгиб — отдельным слоем поверх (раньше линии затирали прозрачность)
    hx = SW // 2
    fold = Image.new("RGBA", (SW, SH), (0, 0, 0, 0))
    fd = ImageDraw.Draw(fold)
    for i in range(16):
        fd.line((hx - 8 + i, 0, hx - 8 + i, SH), fill=(30, 20, 10, int(100 * (1 - abs(i - 8) / 8))))
    fd.line((hx + 2, 0, hx + 2, SH), fill=(240, 220, 180, 70), width=2)
    sp.alpha_composite(fold)
    d = ImageDraw.Draw(sp)
    for x0, dirn in ((6, -1), (SW - 6, 1)):
        for yy in (SH * 0.42, SH * 0.58):
            d.line((x0, yy, x0 - dirn * 90, yy + 18), fill=(236, 226, 204, 255), width=9)
            d.line((x0, yy, x0 - dirn * 90, yy + 18), fill=(188, 176, 148, 255), width=3)
    save(sp, "dossier_spread.png")
    # наклейка «ДЕЛО №» — текст пишет игра
    lab = sheet(520, 200)
    d = ImageDraw.Draw(lab)
    d.line((26, 150, 494, 150), fill=INK_SOFT + (180,), width=1)
    save(age(lab, 41, 0.3, 0.3, 8, (250, 240, 220), (90, 70, 45)), "dossier_label.png")


def build_misc():
    lea = tiled(amb("Leather026"), (512, 512), 3)
    lea = ImageEnhance.Brightness(Image.blend(lea, Image.new("RGB", lea.size, (60, 40, 25)), 0.35)).enhance(1.25)
    save(lea, "leather.jpg")
    # бирка скорости и бумажная лента
    t = cardboard((56, 52), (200, 165, 100), 0.3, 1.0, 5)
    t.putalpha(rounded((56, 52), 5))
    t = age(t, 51, 0.3, 0.4, 5, (230, 205, 160), (60, 40, 20))
    save(t, "tag.png")
    ton = t.copy()
    ImageDraw.Draw(ton).ellipse((6, 4, 50, 48), outline=RED + (230,), width=3)
    save(ton, "tag_on.png")
    save(sheet(400, 44), "strip.png")
    # квадратик для галочки на кнопках-вариантах (как в макете)
    cb = Image.new("RGBA", (40, 40), (0, 0, 0, 0))
    ImageDraw.Draw(cb).rectangle((4, 4, 35, 35), outline=INK + (255,), width=4)
    save(cb, "checkbox.png")
    clip = Image.open(os.path.join(SRC, "paperclip.png")).convert("RGBA")
    clip = clip.resize((int(clip.width * 140 / clip.height), 140), Image.LANCZOS)
    save(clip, "paperclip.png")
    for name, text, col, seed in [("secret", "СЕКРЕТНО", RED, 3), ("top_secret", "СОВ. СЕКРЕТНО", RED, 17),
                                  ("approved", "ПРИНЯТО", BLUE, 5), ("rejected", "ОТКЛОНЕНО", RED, 7),
                                  ("threat", "УГРОЗА", RED, 21), ("archive", "АРХИВ", BLUE, 9)]:
        save(stamp(text, 300, 96, col, seed), f"stamp_{name}.png")


def main():
    global SRC
    ap = argparse.ArgumentParser()
    ap.add_argument("--src", default=SRC)
    ap.add_argument("--godot", default="godot")
    a = ap.parse_args()
    SRC = a.src
    download(a.godot)
    os.makedirs(OUT, exist_ok=True)
    build_clipboard()
    build_sheets()
    build_spines()
    build_dossier()
    build_misc()
    print("готово:", OUT)


if __name__ == "__main__":
    main()
