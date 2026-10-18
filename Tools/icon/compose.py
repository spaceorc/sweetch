# The app icon: the emblem (Resources/icon/emblem.png, the S and the bars on transparent, made by
# the user) at 78% of the square, centred on a dark navy background lit teal from the top right,
# with a soft glow behind it. Writes Resources/icon/AppIcon-1024.png (the Mac's and the iPhone's).
# Needs numpy and Pillow: python3 Tools/icon/compose.py
import numpy as np
from PIL import Image, ImageFilter
N = 1024
yy, xx = np.mgrid[0:N, 0:N] / N
c0 = np.array([0x01, 0x0F, 0x1C]); c1 = np.array([0x06, 0x5A, 0x66])
t = np.clip((xx + (1 - yy)) / 2, 0, 1) ** 1.6
bg = c0 * (1 - t[..., None]) + c1 * t[..., None]
r = np.hypot(xx - 0.85, yy - 0.05); bg += np.clip(1 - r / 0.9, 0, 1)[..., None] ** 2 * np.array([4, 22, 24])
bg = Image.fromarray(np.clip(bg, 0, 255).astype(np.uint8)).convert('RGBA')
em = Image.open('Resources/icon/emblem.png').convert('RGBA')
em = em.crop(em.getbbox())
s = 0.78 * N / max(em.size)
em = em.resize((round(em.size[0] * s), round(em.size[1] * s)), Image.LANCZOS)
x, y = (N - em.size[0]) // 2, (N - em.size[1]) // 2
glow = Image.new('RGBA', (N, N), (0, 0, 0, 0))
g = Image.new('RGBA', em.size, (40, 220, 230, 0)); g.putalpha(em.getchannel('A').point(lambda v: int(v * 0.35)))
glow.paste(g, (x, y), g); glow = glow.filter(ImageFilter.GaussianBlur(28))
out = Image.alpha_composite(bg, glow); out.paste(em, (x, y), em)
out.convert('RGB').save('Resources/icon/AppIcon-1024.png')
