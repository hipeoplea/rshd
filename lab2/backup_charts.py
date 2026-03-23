#!/usr/bin/env python3

from pathlib import Path
import csv


DAYS = 28
INITIAL_MB = 18
NEW_MB = 950
CHANGED_MB = 650
WAL_MB = NEW_MB + CHANGED_MB
BACKUP_EVERY = 7
PRIMARY_RETENTION = 7
RESERVE_RETENTION = 28

ROOT = Path(__file__).resolve().parent
OUT = ROOT / "charts"


def gib(mb):
    return mb / 1024


def full_backup_days():
    return list(range(BACKUP_EVERY, DAYS + 1, BACKUP_EVERY))


def full_backup_sizes():
    return [gib(INITIAL_MB + day * NEW_MB) for day in full_backup_days()]


def reserve_total():
    totals = []
    for day in range(1, DAYS + 1):
        full = sum(INITIAL_MB + b * NEW_MB for b in full_backup_days() if b <= day and day - b < RESERVE_RETENTION)
        wal = WAL_MB * min(day, RESERVE_RETENTION)
        totals.append(gib(full + wal))
    return totals


def primary_total():
    totals = []
    for day in range(1, DAYS + 1):
        full = 0
        for b in full_backup_days():
            if b <= day and day - b < PRIMARY_RETENTION:
                full = INITIAL_MB + b * NEW_MB
        wal = WAL_MB * min(day, PRIMARY_RETENTION)
        totals.append(gib(full + wal))
    return totals


def top_tick(values):
    raw = max(values) * 1.1 if values else 1
    step = 5 if raw > 40 else 2 if raw > 15 else 1
    return step * int(raw / step + 1)


def chart(path, title, xs, ys, color, kind):
    w, h = 1200, 700
    left, right, top, bottom = 110, 40, 70, 90
    pw, ph = w - left - right, h - top - bottom
    x0, y0 = left, top + ph
    ymax = top_tick(ys)
    xticks = xs if len(xs) <= 7 else [1, 7, 14, 21, 28]

    def sx(x):
        if len(xs) == 1:
            return x0 + pw / 2
        return x0 + (x - xs[0]) * pw / (xs[-1] - xs[0])

    def sy(y):
        return y0 - y * ph / ymax

    svg = [
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}" viewBox="0 0 {w} {h}">',
        '<rect width="100%" height="100%" fill="white"/>',
        f'<text x="{w/2}" y="36" text-anchor="middle" font-size="28" font-family="Arial">{title}</text>',
    ]

    for i in range(6):
        yv = ymax * i / 5
        y = sy(yv)
        svg += [
            f'<line x1="{x0}" y1="{y:.1f}" x2="{x0+pw}" y2="{y:.1f}" stroke="#d0d0d0"/>',
            f'<text x="{x0-12}" y="{y+5:.1f}" text-anchor="end" font-size="16" font-family="Arial">{yv:.1f}</text>',
        ]

    for x in xticks:
        px = sx(x)
        svg += [
            f'<line x1="{px:.1f}" y1="{top}" x2="{px:.1f}" y2="{y0}" stroke="#ececec"/>',
            f'<text x="{px:.1f}" y="{y0+24}" text-anchor="middle" font-size="15" font-family="Arial">{x}</text>',
        ]

    svg += [
        f'<line x1="{x0}" y1="{y0}" x2="{x0+pw}" y2="{y0}" stroke="#222" stroke-width="2"/>',
        f'<line x1="{x0}" y1="{top}" x2="{x0}" y2="{y0}" stroke="#222" stroke-width="2"/>',
        f'<text x="{w/2}" y="{h-24}" text-anchor="middle" font-size="20" font-family="Arial">Дни</text>',
        f'<text x="28" y="{h/2}" transform="rotate(-90 28 {h/2})" text-anchor="middle" font-size="20" font-family="Arial">Объем, GiB</text>',
    ]

    if kind == "bar":
        bw = pw / max(len(xs), 1) * 0.6
        for x, y in zip(xs, ys):
            px = sx(x) - bw / 2
            py = sy(y)
            svg.append(f'<rect x="{px:.1f}" y="{py:.1f}" width="{bw:.1f}" height="{y0-py:.1f}" fill="{color}"/>')
    else:
        points = " ".join(f"{sx(x):.1f},{sy(y):.1f}" for x, y in zip(xs, ys))
        svg.append(f'<polyline fill="none" stroke="{color}" stroke-width="4" points="{points}"/>')
        for x, y in zip(xs, ys):
            svg.append(f'<circle cx="{sx(x):.1f}" cy="{sy(y):.1f}" r="4.5" fill="{color}"/>')
        svg.append(
            f'<text x="{sx(xs[-1]) - 100:.1f}" y="{sy(ys[-1]) - 12:.1f}" font-size="16" font-family="Arial">{ys[-1]:.2f} GiB</text>'
        )

    svg.append("</svg>")
    path.write_text("\n".join(svg), encoding="utf-8")


def save_csv():
    backup_x = full_backup_days()
    backup_y_mb = [INITIAL_MB + day * NEW_MB for day in backup_x]
    reserve_y_gib = reserve_total()
    primary_y_gib = primary_total()

    with (OUT / "full_backup_sizes.csv").open("w", newline="", encoding="utf-8") as file:
        writer = csv.writer(file)
        writer.writerow(["day", "size_mb", "size_gib"])
        for day, size_mb in zip(backup_x, backup_y_mb):
            writer.writerow([day, size_mb, round(gib(size_mb), 4)])

    with (OUT / "daily_storage.csv").open("w", newline="", encoding="utf-8") as file:
        writer = csv.writer(file)
        writer.writerow(["day", "reserve_total_gib", "primary_total_gib"])
        for day, reserve_value, primary_value in zip(range(1, DAYS + 1), reserve_y_gib, primary_y_gib):
            writer.writerow([day, round(reserve_value, 4), round(primary_value, 4)])


def main():
    OUT.mkdir(exist_ok=True)

    backup_x = full_backup_days()
    backup_y = full_backup_sizes()
    days = list(range(1, DAYS + 1))

    chart(OUT / "reserve_full_backup_sizes.svg", "Резервный узел: размеры полных копий", backup_x, backup_y, "#2b7bbb", "bar")
    chart(OUT / "reserve_total_storage.svg", "Резервный узел: общий объем хранения", days, reserve_total(), "#1d6f42", "line")
    chart(OUT / "primary_full_backup_sizes.svg", "Основной узел: размеры полных копий", backup_x, backup_y, "#d97706", "bar")
    chart(OUT / "primary_total_storage.svg", "Основной узел: общий объем хранения", days, primary_total(), "#b42318", "line")
    save_csv()

    print(f"Charts written to {OUT}")


if __name__ == "__main__":
    main()
