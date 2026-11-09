#!/usr/bin/env python3
"""Добавить фокусы в деревья из компактного описания (tools/focus_extra/*.txt).

Формат файла:
  == TAG
  i|70|Название|Описание|эффекты|условия
  p|35|...
  m|70|...

Ветка: i — промышленность и наука (колонки 0–2), p — политика (3–5),
m — армия, флот, авиация (6–8). Фокус встаёт под нижний фокус самой короткой
колонки своей ветки и требует его (если тот не небывшая развилка и не ждёт
войны/события). Повторный запуск не дублирует: id — тег + номер строки.

Эффекты (через пробел):
  civ2 mil1        заводы       con10 res5 ind8   стройка/наука/выпуск, %
  atk3 def5 org3 spd5 rnf5     бонусы армии, %     mp100   призывники, тыс.
  inf2 arm1 mnt1 cav1 mot1 art1   дивизии          bb1 cr1 dd2 ss2   корабли
  rep:КТО:О_КОМ:±N   trade:КТО:ГДЕ:N   lead:Имя_Фамилия   war:T  lwar:T (ограниченная)
  join:T  pact:T  guar:T  aid:T  peace:T  conc:N  flag:id  tens:N  ev:id
Условия: date:1938-03-12 alive:T dead:T atwar pair:A:B flag:id
"""
import os
import re
import sys

sys.path.insert(0, os.path.dirname(__file__))
from focus_json import load, save

BONUS = {"con": "construction", "res": "research", "ind": "industry", "atk": "attack",
         "def": "defense", "org": "org", "spd": "speed", "rnf": "reinforce"}
DIV = {"inf", "arm", "mnt", "cav", "mot", "art"}
SHIP = {"bb", "cr", "dd", "ss"}
COLS = {"i": (0, 1, 2), "p": (3, 4, 5), "m": (6, 7, 8)}


def effects(s):
    out = []
    for tok in s.split():
        m = re.fullmatch(r"([a-z]+)(-?\d+)", tok)
        if m and m.group(1) in BONUS:
            out.append({"t": "bonus", "key": BONUS[m.group(1)], "v": int(m.group(2)) / 100.0})
        elif m and m.group(1) in ("civ", "mil"):
            out.append({"t": "factories", m.group(1): int(m.group(2))})
        elif m and m.group(1) in DIV:
            out.append({"t": "divisions", "tpl": m.group(1), "n": int(m.group(2))})
        elif m and m.group(1) in SHIP:
            out.append({"t": "ships", "kind": m.group(1), "n": int(m.group(2))})
        elif m and m.group(1) == "mp":
            out.append({"t": "manpower", "v": int(m.group(2))})
        elif m and m.group(1) == "tens":
            out.append({"t": "tension", "v": int(m.group(2))})
        else:
            p = tok.split(":")
            k = p[0]
            if k == "rep":
                out.append({"t": "rep", "by": p[1], "of": p[2], "v": int(p[3])})
            elif k == "trade":
                out.append({"t": "trade", "who": p[1], "target": p[2], "v": int(p[3])})
            elif k == "lead":
                out.append({"t": "leader", "name": p[1].replace("_", " ")})
            elif k in ("war", "lwar"):
                e = {"t": "war", "target": p[1]}
                if k == "lwar":
                    e["limited"] = True
                out.append(e)
            elif k == "join":
                out.append({"t": "join_faction_of", "target": p[1]})
            elif k in ("pact", "guar", "aid", "peace"):
                out.append({"t": {"guar": "guarantee"}.get(k, k), "target": p[1]})
            elif k == "conc":
                out.append({"t": "concede", "v": int(p[1])})
            elif k == "flag":
                out.append({"t": "flag", "id": p[1]})
            elif k == "ev":
                out.append({"t": "event", "id": p[1]})
            else:
                raise ValueError("эффект? " + tok)
    return out


def conds(s):
    out = {}
    for tok in s.split():
        p = tok.split(":")
        if p[0] in ("date", "alive", "dead", "flag"):
            out[p[0]] = p[1]
        elif p[0] == "atwar":
            out["at_war"] = True
        elif p[0] == "pair":
            out["at_war_pair"] = [p[1], p[2]]
        else:
            raise ValueError("условие? " + tok)
    return out


def blocks_chain(fd, tree):
    """Не вешать цепочку под небывшую развилку или фокус, ждущий войны/события."""
    av = fd.get("available", {})
    if any(k in av for k in ("at_war", "at_war_pair", "dead", "flag")):
        return True
    ex = fd.get("exclusive", [])
    if ex:
        ids = [f["id"] for f in tree]
        if any(ids.index(x) < ids.index(fd["id"]) for x in ex if x in ids):
            return True
    return False


def add(tree, tag, n, branch, days, name, desc, eff, cond):
    fid = "%s_x%02d" % (tag.lower(), n)
    if any(f["id"] == fid for f in tree):
        return
    best = None
    for x in COLS[branch]:
        col = [f for f in tree if f["x"] == x]
        h = max((f["y"] for f in col), default=-1) + 1
        if best is None or h < best[1]:
            best = (x, h, col)
    x, y, col = best
    fd = {"id": fid, "name": name, "desc": desc, "days": int(days), "x": x, "y": y}
    for f in sorted(col, key=lambda f: -f["y"]):
        if not blocks_chain(f, tree):
            fd["requires"] = [f["id"]]
            break
    if cond:
        fd["available"] = cond
    fd["effects"] = eff
    tree.append(fd)


def main(paths):
    d = load()
    for path in paths:
        tag = None
        n = 0
        for line in open(path, encoding="utf-8"):
            line = line.rstrip("\n")
            if not line.strip() or line.startswith("#"):
                continue
            if line.startswith("=="):
                tag = line[2:].strip()
                n = 0
                continue
            n += 1
            parts = line.split("|")
            parts += [""] * (6 - len(parts))
            br, days, name, desc, eff, cond = [p.strip() for p in parts[:6]]
            add(d["trees"].setdefault(tag, []), tag, n, br, days, name, desc, effects(eff), conds(cond))
    save(d)
    print({k: len(v) for k, v in d["trees"].items()})


if __name__ == "__main__":
    main(sys.argv[1:])
