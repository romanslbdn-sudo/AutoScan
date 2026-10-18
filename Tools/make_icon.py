#!/usr/bin/env python3
"""Малює іконку програми (1024×1024) у Resources/AppIcon.png."""
import math, os
from PIL import Image, ImageDraw, ImageFilter

S = 2048  # малюємо вдвічі більше і зменшуємо — так краї гладкіші
img = Image.new("RGBA", (S, S), (0, 0, 0, 0))

# Тіло іконки за сіткою Apple: 824/1024 від розміру, заокруглення ~22%
inset = int(S * 100 / 1024)
body = (inset, inset, S - inset, S - inset)
radius = int((S - 2 * inset) * 0.225)

# Тінь
shadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
ImageDraw.Draw(shadow).rounded_rectangle((body[0], body[1] + 24, body[2], body[3] + 24), radius, fill=(0, 0, 0, 140))
img.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(28)))

# Фон — темний вертикальний градієнт
bg = Image.new("RGBA", (S, S))
top, bottom = (40, 46, 58), (14, 16, 22)
px = bg.load()
for y in range(S):
    t = y / S
    c = tuple(int(top[i] + (bottom[i] - top[i]) * t) for i in range(3)) + (255,)
    for x in range(S):
        px[x, y] = c
mask = Image.new("L", (S, S), 0)
ImageDraw.Draw(mask).rounded_rectangle(body, radius, fill=255)
img.paste(bg, (0, 0), mask)

d = ImageDraw.Draw(img)
# Тонка світла рамка
d.rounded_rectangle(body, radius, outline=(62, 68, 82, 255), width=6)

cx, cy = S / 2, S * 0.56
R = S * 0.30

def lerp(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))

teal, blue, amber = (64, 209, 194), (107, 158, 255), (255, 186, 69)
start, end = 150, 390  # градуси (за годинниковою стрілкою від осі X)

# Фонова дуга шкали
d.arc((cx - R, cy - R, cx + R, cy + R), start, end, fill=(48, 54, 66, 255), width=int(S * 0.045))
# Кольорова дуга (до положення стрілки)
needle_deg = 330
steps = 220
for i in range(steps):
    a0 = start + (needle_deg - start) * i / steps
    a1 = start + (needle_deg - start) * (i + 1) / steps + 0.6
    col = lerp(teal, blue, i / steps) + (255,)
    d.arc((cx - R, cy - R, cx + R, cy + R), a0, a1, fill=col, width=int(S * 0.045))

# Поділки
for k in range(13):
    ang = math.radians(start + (end - start) * k / 12)
    r1, r2 = R * 0.80, R * (0.70 if k % 3 == 0 else 0.75)
    w = 14 if k % 3 == 0 else 8
    col = (190, 196, 206, 255) if k < 11 else amber + (255,)
    d.line((cx + r1 * math.cos(ang), cy + r1 * math.sin(ang), cx + r2 * math.cos(ang), cy + r2 * math.sin(ang)), fill=col, width=w)

# Стрілка
ang = math.radians(needle_deg)
tip = (cx + R * 0.86 * math.cos(ang), cy + R * 0.86 * math.sin(ang))
perp = ang + math.pi / 2
base_w = S * 0.022
p1 = (cx + base_w * math.cos(perp), cy + base_w * math.sin(perp))
p2 = (cx - base_w * math.cos(perp), cy - base_w * math.sin(perp))
glow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
ImageDraw.Draw(glow).polygon([p1, tip, p2], fill=teal + (200,))
img.alpha_composite(glow.filter(ImageFilter.GaussianBlur(18)))
d = ImageDraw.Draw(img)
d.polygon([p1, tip, p2], fill=(236, 244, 248, 255))
hub = S * 0.045
d.ellipse((cx - hub, cy - hub, cx + hub, cy + hub), fill=(236, 244, 248, 255))
d.ellipse((cx - hub * 0.45, cy - hub * 0.45, cx + hub * 0.45, cy + hub * 0.45), fill=(30, 34, 44, 255))

# Хвиля сигналу внизу
wave = []
y0 = S * 0.78
for i in range(0, 401):
    x = S * 0.30 + S * 0.40 * i / 400
    t = i / 400
    y = y0 - math.sin(t * math.pi * 6) * S * 0.022 * (1 - abs(t - 0.5) * 1.2)
    wave.append((x, y))
d.line(wave, fill=teal + (255,), width=12, joint="curve")

out = os.path.join(os.path.dirname(__file__), "..", "Resources", "AppIcon.png")
os.makedirs(os.path.dirname(out), exist_ok=True)
img.resize((1024, 1024), Image.LANCZOS).save(out)
print("Іконку збережено:", os.path.normpath(out))
