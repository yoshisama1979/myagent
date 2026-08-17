"""Cycle 079 一時スクリプト：system-0731-sp-full.png の「対応できるシステムの種類」領域を切り出して精査する（読み取り→切出保存のみ）。"""
from PIL import Image

SRC = "data/hp-loop/cycles/ycom/shots/system-0731-sp-full.png"
im = Image.open(SRC)
w, h = im.size
print("size:", w, h)

# 疑い領域（表示比から逆算：おおよそ y=7500〜15500）を3分割で保存
for i, (y0, y1) in enumerate([(7000, 10000), (10000, 13000), (13000, 16000)]):
    y1 = min(y1, h)
    im.crop((0, y0, w, y1)).save(f"data/hp-loop/cycles/ycom/shots/system-0731-sp-crop{i}.png")
    print("saved crop", i, (0, y0, w, y1))
