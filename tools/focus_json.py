#!/usr/bin/env python3
"""Запись focuses.json в принятом виде: один фокус — две строки (поля и эффекты).

  from focus_json import load, save
"""
import json
import os

PATH = os.path.join(os.path.dirname(__file__), "..", "data", "world1936", "focuses.json")


def load():
    with open(PATH, encoding="utf-8") as f:
        return json.load(f)


def _focus(fd):
    head = {k: v for k, v in fd.items() if k != "effects"}
    h = json.dumps(head, ensure_ascii=False)[:-1]
    eff = json.dumps(fd.get("effects", []), ensure_ascii=False)
    return "      %s,\n       \"effects\": %s}" % (h, eff)


def save(d):
    out = ["{", "  \"_comment\": %s," % json.dumps(d["_comment"], ensure_ascii=False), "  \"trees\": {"]
    tags = list(d["trees"].keys())
    for ti, tag in enumerate(tags):
        out.append("    %s: [" % json.dumps(tag, ensure_ascii=False))
        fs = d["trees"][tag]
        out.append(",\n".join(_focus(fd) for fd in fs))
        out.append("    ]" + ("," if ti < len(tags) - 1 else ""))
    out.append("  }")
    out.append("}")
    with open(PATH, "w", encoding="utf-8") as f:
        f.write("\n".join(out) + "\n")
