# -*- coding: utf-8 -*-
"""docs/preview.gif 생성기 — cmd 창 + 결과 txt 창만 담는 깔끔한 데모 GIF.

다른 화면(바탕화면/익스플로러/작업표시줄/기타 앱)은 절대 그리지 않는다.
실행: python docs/make_preview_gif.py
"""
from PIL import Image, ImageDraw, ImageFont

W, H = 1000, 560
FONT = r"C:\Windows\Fonts\malgun.ttf"
FONT_B = r"C:\Windows\Fonts\malgunbd.ttf"

f_title = ImageFont.truetype(FONT_B, 15)
f_text = ImageFont.truetype(FONT, 14)
f_bold = ImageFont.truetype(FONT_B, 14)
f_small = ImageFont.truetype(FONT, 12)

# 색상
BG_TOP, BG_BOT = (20, 25, 34), (9, 11, 17)
CMD_BG, CMD_BAR = (13, 14, 17), (42, 46, 54)
TXT_BG, TXT_BAR = (252, 252, 253), (235, 237, 241)
WHITE, GRAY, CYAN = (232, 236, 244), (150, 158, 172), (86, 200, 255)
GREEN, YELLOW, RED = (118, 220, 140), (240, 202, 96), (235, 110, 110)
DARK, DGRAY, BLUE = (30, 34, 42), (95, 102, 115), (0, 110, 200)

CMD_LINES = [
    ("Microsoft Windows [Version 10.0.26100.4652]", GRAY),
    ("(c) Microsoft Corporation. All rights reserved.", GRAY),
    ("", GRAY),
    ("C:\\Users\\dal04> powershell -File run-now.ps1", WHITE),
    ("", GRAY),
    ("============================================", CYAN),
    ("  자동 유지보수 점검   ·   v1.12.0", WHITE),
    ("============================================", CYAN),
    ("  총 38가지 기능을 순서대로 실행합니다.", GRAY),
    ("", GRAY),
    ("  ▶ 시스템 상태 확인...", CYAN),
    ("     [OK] 관리자 권한 / 복원 지점 생성", GREEN),
    ("  ▶ 디스크 및 파일 무결성 검사...", CYAN),
    ("     [OK] SFC - 손상된 시스템 파일 없음", GREEN),
    ("     [주의] 이벤트 로그 경고 3건 (정보성)", YELLOW),
    ("  ▶ 바탕화면 결과 정리...", CYAN),
    ("     [OK] 지난 결과 2개 -> 자동점검결과 폴더", GREEN),
    ("", GRAY),
    ("  점검 완료 -> 자동유지보수_20261119_1909.txt", WHITE),
]

TXT_LINES = [
    ("자동 유지보수 결과   2026-11-19 19:09:10", DARK),
    ("버전 v1.12.0    ·    모드: 즉시 점검 (-Force)", DGRAY),
    ("====================================================", DGRAY),
    ("[요약]  전체 38개   |   성공 37   |   주의 1   |   실패 0", BLUE),
    ("   시스템 무결성: 정상", DARK),
    ("   디스크 여유: C: 128.4 GB / 412.0 GB", DARK),
    ("   마지막 점검: 없음 (첫 실행)", DARK),
    ("====================================================", DGRAY),
    ("[시스템]", DARK),
    ("   · OS: Windows 11 Pro 24H2 (26100)", DARK),
    ("   · 관리자 권한: 예 / 복원 지점 생성됨", DARK),
    ("[안전]", DARK),
    ("   · 사용자 파일 자동 삭제: 없음", DARK),
    ("   · 임시/캐시 정리: 보류 (확인 필요)", DARK),
    ("   · 휴지통 30일 이상 12개: 그대로 둠", DARK),
    ("[바탕화면 정리]", DARK),
    ("   · 지난 결과 2개 -> '자동점검결과' 폴더", DARK),
    ("   · 이번 결과 1개만 바탕화면에 유지", DARK),
    ("※ 맨 위 3줄만 보면 됩니다. (전체는 로그 참고)", BLUE),
]


def bg_image():
    img = Image.new("RGB", (W, H))
    px = img.load()
    for y in range(H):
        t = y / (H - 1)
        c = tuple(int(BG_TOP[i] + (BG_BOT[i] - BG_TOP[i]) * t) for i in range(3))
        for x in range(W):
            px[x, y] = c
    return img


def mix(c1, c2, t):
    return tuple(int(c1[i] + (c2[i] - c1[i]) * t) for i in range(3))


def window(img, title, dark=True):
    d = ImageDraw.Draw(img)
    x0, y0, x1, y1 = 130, 40, 870, 520
    bar = CMD_BAR if dark else TXT_BAR
    body = CMD_BG if dark else TXT_BG
    edge = (78, 84, 94) if dark else (185, 190, 200)

    d.rounded_rectangle((x0 + 8, y0 + 9, x1 + 8, y1 + 9), radius=10, fill=(4, 5, 8))
    d.rounded_rectangle((x0, y0, x1, y1), radius=10, fill=body, outline=edge, width=1)
    d.rounded_rectangle((x0, y0, x1, y0 + 38), radius=10, fill=bar)
    d.rectangle((x0, y0 + 28, x1, y0 + 38), fill=bar)
    d.text((x0 + 16, y0 + 10), title, font=f_title, fill=WHITE if dark else DARK)
    for i, col in enumerate(((226, 96, 96), (232, 190, 88), (96, 196, 112))):
        cx = x1 - 26 - i * 24
        d.ellipse((cx - 5, y0 + 14, cx + 5, y0 + 24), fill=col)
    d.line((x0, y0 + 38, x1, y0 + 38), fill=edge, width=1)
    return x0, y0, x1, y1


def reveal(draw, lines, prog, x, y, lh, font, back, bold_first=False, highlight=0):
    exact = max(0.0, min(1.0, prog)) * len(lines)
    full, frac = int(exact), exact - int(exact)
    for i in range(full):
        f = f_bold if (bold_first and i == 0) else font
        draw.text((x, y + i * lh), lines[i][0], font=f, fill=lines[i][1])
    if full < len(lines) and frac > 0:
        col = mix(back, lines[full][1], frac)
        draw.text((x, y + full * lh), lines[full][0], font=font, fill=col)
    if highlight and full > highlight:
        draw.rounded_rectangle(
            (x - 10, y - 5, x + 560, y + highlight * lh - 3),
            radius=6, fill=(228, 239, 252), outline=(186, 212, 244), width=1,
        )
        draw.rectangle((x - 10, y - 5, x - 6, y + highlight * lh - 3), fill=BLUE)
        for i in range(highlight):
            f = f_bold if i == 0 else font
            draw.text((x, y + i * lh), lines[i][0], font=f, fill=lines[i][1])
    return full


def cmd_frame(i, total):
    img = bg_image()
    x0, y0, x1, y1 = window(img, "관리자: Windows PowerShell   -   자동 유지보수 점검", dark=True)
    d = ImageDraw.Draw(img)
    reveal(d, CMD_LINES, i / (total * 0.72), x0 + 24, y0 + 54, 20, f_text, CMD_BG)

    # 진행 바 (다른 창 없이 이 창 안에서만 진행)
    p = max(0.0, min(1.0, (i - total * 0.12) / (total * 0.55)))
    bx0, by, bx1 = x0 + 24, y1 - 30, x1 - 24
    d.rounded_rectangle((bx0, by, bx1, by + 9), radius=4, outline=(70, 76, 86), width=1)
    if p > 0:
        d.rounded_rectangle((bx0 + 1, by + 1, bx0 + 1 + (bx1 - bx0 - 2) * p, by + 8),
                            radius=3, fill=GREEN)

    # 깜빡이는 커서
    if (i // 5) % 2 == 0:
        shown = int(min(1.0, i / (total * 0.72)) * len(CMD_LINES))
        if shown:
            cx = x0 + 24 + int(d.textlength(CMD_LINES[shown - 1][0], font=f_text)) + 3
            cy = y0 + 54 + (shown - 1) * 20
            d.rectangle((cx, cy + 2, cx + 7, cy + 16), fill=WHITE)
    return img


def txt_frame(i, total):
    img = bg_image()
    x0, y0, x1, y1 = window(img, "자동유지보수_20261119_1909.txt - 메모장", dark=False)
    d = ImageDraw.Draw(img)
    reveal(d, TXT_LINES, i / (total * 0.72), x0 + 24, y0 + 56, 19, f_text, TXT_BG,
           bold_first=True, highlight=3)
    return img


def main():
    cmd_n, txt_n, fade_n = 78, 66, 9
    frames = [cmd_frame(i, cmd_n) for i in range(cmd_n)]
    frames += [Image.blend(frames[-1], txt_frame(0, txt_n), (k + 1) / (fade_n + 1))
               for k in range(fade_n)]
    frames += [txt_frame(i, txt_n) for i in range(txt_n)]
    frames += [Image.blend(frames[-1], frames[0], (k + 1) / (fade_n + 1))
               for k in range(fade_n)]

    # 한 팔레트로 통일해 GIF 크기/깜빡임 최소화
    sample = Image.new("RGB", (W, H * 4))
    for j, idx in enumerate((0, cmd_n // 2, cmd_n - 1, cmd_n + fade_n + txt_n // 2)):
        sample.paste(frames[idx], (0, H * j))
    pal_img = sample.quantize(colors=256, method=Image.Quantize.MEDIANCUT)
    frames = [f.quantize(palette=pal_img, dither=Image.Dither.NONE) for f in frames]

    out = r"I:\code\docs\preview.gif"
    frames[0].save(
        out, save_all=True, append_images=frames[1:], duration=80,
        loop=0, optimize=True, disposal=2,
    )
    print("saved:", out, "frames:", len(frames))


if __name__ == "__main__":
    main()
