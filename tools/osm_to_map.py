#!/usr/bin/env python3
"""Converts OpenStreetMap extracts of Bashkortostan into game map data.

Input (Overpass JSON, fetched by tools/osm_fetch.sh into a folder):
  districts.json      admin_level=6 relations (54 districts + 9 city okrugs), out geom
  republic.json       the republic boundary relation, out geom
  places.json         place=city|town|village|hamlet nodes
  roads.json          motorway|trunk|primary ways, out geom
  rivers.json         named major rivers, out geom
  ufa_districts.json  admin_level=9 city districts of Ufa, out geom
  ufa_roads.json      main streets of Ufa, out geom
  poi_*.json          named points of interest in Ufa, out center

Output: data/core/data/map/*.json  (kinds: border, district, region, road, river,
city_district, place). Hand-made regions in data/core/data/map/regions.json are
(tools/map_src/regions_handmade.json) are kept and merged (same name -> keeps the hand-made id, description, location).

Geography is real (© OpenStreetMap contributors, ODbL); gameplay values
(danger, loot) are derived. Coordinates are simplified with Douglas-Peucker.
"""
from __future__ import annotations

import json
import math
import re
import sys
from collections import defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "data" / "core" / "data" / "map"
SRC = ROOT / "tools" / "map_src"  # hand-made nodes and routes merged into the generated data
K = math.cos(math.radians(54.5))  # lon scale at Bashkortostan latitude

TR = dict(zip("абвгдеёжзийклмнопрстуфхцчшщъыьэюя",
              ["a", "b", "v", "g", "d", "e", "e", "zh", "z", "i", "y", "k", "l", "m", "n", "o", "p", "r", "s", "t", "u", "f",
               "kh", "ts", "ch", "sh", "sch", "", "y", "", "e", "yu", "ya"]))


def slug(name: str) -> str:
    s = "".join(TR.get(c, c) for c in name.lower())
    s = re.sub(r"[^a-z0-9]+", "_", s).strip("_")
    return s[:48] or "x"


def load(folder: Path, name: str) -> list:
    p = folder / f"{name}.json"
    return json.loads(p.read_text(encoding="utf-8"))["elements"] if p.exists() else []


# --- geometry ---------------------------------------------------------------------

def dp(points: list, tol: float) -> list:
    """Douglas-Peucker on (lat, lon) with lon scaled by cos(lat)."""
    if len(points) < 3:
        return points
    def d(p, a, b):
        ax, ay, bx, by, px, py = a[1] * K, a[0], b[1] * K, b[0], p[1] * K, p[0]
        dx, dy = bx - ax, by - ay
        if dx == dy == 0:
            return math.hypot(px - ax, py - ay)
        t = max(0, min(1, ((px - ax) * dx + (py - ay) * dy) / (dx * dx + dy * dy)))
        return math.hypot(px - ax - t * dx, py - ay - t * dy)
    keep = [False] * len(points)
    keep[0] = keep[-1] = True
    stack = [(0, len(points) - 1)]
    while stack:
        i, j = stack.pop()
        best, idx = 0.0, -1
        for k in range(i + 1, j):
            dist = d(points[k], points[i], points[j])
            if dist > best:
                best, idx = dist, k
        if best > tol and idx > 0:
            keep[idx] = True
            stack += [(i, idx), (idx, j)]
    return [p for p, k in zip(points, keep) if k]


def rnd(points: list) -> list:
    return [[round(p[0], 4), round(p[1], 4)] for p in points]


def stitch(ways: list[list]) -> list[list]:
    """Joins way polylines that share endpoints into closed rings."""
    ways = [w[:] for w in ways if len(w) >= 2]
    rings = []
    key = lambda p: (round(p[0], 6), round(p[1], 6))
    while ways:
        ring = ways.pop(0)
        changed = True
        while changed and key(ring[0]) != key(ring[-1]):
            changed = False
            for i, w in enumerate(ways):
                if key(w[0]) == key(ring[-1]):
                    ring += w[1:]
                elif key(w[-1]) == key(ring[-1]):
                    ring += w[::-1][1:]
                elif key(w[-1]) == key(ring[0]):
                    ring = w[:-1] + ring
                elif key(w[0]) == key(ring[0]):
                    ring = w[::-1][:-1] + ring
                else:
                    continue
                ways.pop(i)
                changed = True
                break
        rings.append(ring)
    return rings


def area(ring: list) -> float:
    a = 0.0
    for i in range(len(ring)):
        x1, y1 = ring[i][1] * K, ring[i][0]
        x2, y2 = ring[(i + 1) % len(ring)][1] * K, ring[(i + 1) % len(ring)][0]
        a += x1 * y2 - x2 * y1
    return abs(a) / 2


def centroid(ring: list) -> list:
    return [sum(p[0] for p in ring) / len(ring), sum(p[1] for p in ring) / len(ring)]


def inside(pt, ring) -> bool:
    y, x = pt
    c = False
    j = len(ring) - 1
    for i in range(len(ring)):
        yi, xi = ring[i]
        yj, xj = ring[j]
        if (yi > y) != (yj > y) and x < (xj - xi) * (y - yi) / (yj - yi + 1e-12) + xi:
            c = not c
        j = i
    return c


def _segments_cross(a, b, c, d) -> bool:
    def orient(p, q, r):
        return (q[1] - p[1]) * (r[0] - p[0]) - (q[0] - p[0]) * (r[1] - p[1])
    o1, o2, o3, o4 = orient(a, b, c), orient(a, b, d), orient(c, d, a), orient(c, d, b)
    return (o1 > 0) != (o2 > 0) and (o3 > 0) != (o4 > 0) and o1 * o2 != 0 and o3 * o4 != 0


def is_simple(ring: list) -> bool:
    n = len(ring)
    if n < 3 or len({(p[0], p[1]) for p in ring}) != n:
        return False
    for i in range(n):
        a, b = ring[i], ring[(i + 1) % n]
        for j in range(i + 2, n):
            if i == 0 and j == n - 1:
                continue
            if _segments_cross(a, b, ring[j], ring[(j + 1) % n]):
                return False
    return True


def unpinch(ring: list) -> list:
    """Splits a ring that touches itself (figure-8) and keeps the largest loop."""
    seen = {}
    for i, p in enumerate(ring):
        k = (round(p[0], 7), round(p[1], 7))
        if k in seen:
            j = seen[k]
            a = ring[j:i]
            b = ring[:j] + ring[i:]
            return unpinch(a if area(a) > area(b) else b)
        seen[k] = i
    return ring


def _repair(ring: list) -> list:
    """Fixes a self-intersecting ring with shapely (largest valid part)."""
    try:
        from shapely.geometry import Polygon
        from shapely.validation import make_valid
    except ImportError:
        return ring
    g = make_valid(Polygon([(p[1], p[0]) for p in ring]))
    polys = [g] if g.geom_type == "Polygon" else [x for x in getattr(g, "geoms", []) if x.geom_type == "Polygon"]
    if not polys:
        return ring
    best = max(polys, key=lambda x: x.area)
    return [[y, x] for x, y in list(best.exterior.coords)[:-1]]


def simplify_ring(ring: list, tol: float) -> list:
    """Simplifies a closed ring, keeping it free of self-intersections."""
    if ring and ring[0] == ring[-1]:
        ring = ring[:-1]
    ring = unpinch(ring)
    try:
        from shapely.geometry import Polygon
        from shapely.validation import make_valid
        g = make_valid(Polygon([(p[1] * K, p[0]) for p in ring]))
        polys = [g] if g.geom_type == "Polygon" else [x for x in getattr(g, "geoms", []) if x.geom_type == "Polygon"]
        best = max(polys, key=lambda x: x.area)
        t = tol
        while t > 1e-5:
            sim = best.simplify(t, preserve_topology=True)
            out = []
            for x, y in list(sim.exterior.coords)[:-1]:
                q = [round(y, 4), round(x / K, 4)]
                if not out or out[-1] != q:
                    out.append(q)
            if len(out) >= 3 and Polygon([(q[1] * K, q[0]) for q in out]).is_valid and len({tuple(q) for q in out}) == len(out):
                return out
            t /= 2
    except ImportError:
        pass
    if not is_simple(rnd(ring)):
        ring = _repair(ring)
    t = tol
    while t > 1e-5:
        out = []
        for p in rnd(dp(ring + [ring[0]], t))[:-1]:
            if not out or out[-1] != p:
                out.append(p)
        if is_simple(out):
            return out
        t /= 2
    return rnd(ring)


def rel_rings(rel: dict, tol: float, min_area: float = 0.0) -> list[list]:
    outer = [[[g["lat"], g["lon"]] for g in m["geometry"]] for m in rel.get("members", [])
             if m["type"] == "way" and m.get("role") in ("outer", "") and m.get("geometry")]
    rings = [r for r in stitch(outer) if len(r) >= 4]
    rings.sort(key=area, reverse=True)
    out = []
    for r in rings:
        if out and area(r) < max(min_area, area(rings[0]) * 0.002):
            continue
        out.append(simplify_ring(r, tol))
    return out


def km(a, b) -> float:
    dlat, dlon = math.radians(b[0] - a[0]), math.radians(b[1] - a[1])
    h = math.sin(dlat / 2) ** 2 + math.cos(math.radians(a[0])) * math.cos(math.radians(b[0])) * math.sin(dlon / 2) ** 2
    return 6371 * 2 * math.atan2(math.sqrt(h), math.sqrt(1 - h))


def pop(tags: dict) -> int:
    digits = "".join(c for c in str(tags.get("population", "")) if c.isdigit())
    return int(digits) if digits else 0


def write(name: str, kind: str, defs: list, note: str = "") -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    data = {"kind": kind, "defs": defs}
    if note:
        data = {"kind": kind, "_source": note, "defs": defs}
    text = json.dumps(data, ensure_ascii=False, separators=(",", ":"))
    (OUT / f"{name}.json").write_text(text, encoding="utf-8")
    print(f"{name}.json: {len(defs)} {kind} defs, {len(text) // 1024} KB")


# --- main ---------------------------------------------------------------------------

def main(src: Path) -> int:
    note = "© OpenStreetMap contributors, ODbL. Generated by tools/osm_to_map.py"
    handmade = json.loads((SRC / "regions_handmade.json").read_text(encoding="utf-8"))["defs"]

    # republic border
    rep = load(src, "republic")
    border = rel_rings(rep[0], 0.01)[0] if rep else []
    write("border", "border", [{"id": "bashkortostan", "name": "Республика Башкортостан", "points": border}], note)

    # districts
    districts = []
    for rel in load(src, "districts"):
        name = rel["tags"].get("name", "")
        rings = rel_rings(rel, 0.004)
        if not rings:
            continue
        is_city = name.startswith("городской округ") or name.startswith("ЗАТО")
        short = name.replace("городской округ ", "").replace("ЗАТО ", "")
        center = None
        for m in rel.get("members", []):
            if m["type"] == "node" and m.get("role") in ("label", "admin_centre"):
                center = [m["lat"], m["lon"]]
                if m["role"] == "label":
                    break
        if center is None or not inside(center, rings[0]):
            center = centroid(rings[0])
        districts.append({"id": ("go_" if is_city else "r_") + slug(short.replace(" район", "")), "name": short if is_city else name,
                          "kind": "city" if is_city else "district", "center": [round(center[0], 4), round(center[1], 4)],
                          "polygons": rings, "osm_id": rel["id"]})
    districts.sort(key=lambda d: d["name"])

    def district_of(pt) -> str:
        best = ""
        # city okrugs are enclaves inside districts: test them first
        for d in sorted(districts, key=lambda d: d["kind"] != "city"):
            if any(inside(pt, r) for r in d["polygons"]):
                return d["id"]
        # fall back to nearest center (points on the border)
        dmin = 1e9
        for d in districts:
            dd = km(pt, d["center"])
            if dd < dmin:
                dmin, best = dd, d["id"]
        return best

    # settlements -> travel nodes ("region")
    places = load(src, "places")
    admin_centres = {(round(m["lat"], 3), round(m["lon"], 3)) for rel in load(src, "districts") for m in rel.get("members", []) if m.get("role") == "admin_centre"}
    by_name = {h["name"]: h for h in handmade}
    nodes = {}
    for h in handmade:
        h = dict(h)
        h["district"] = district_of([h["lat"], h["lon"]])
        nodes[h["id"]] = h
    candidates = []
    for e in places:
        t = e["tags"]
        name = t.get("name")
        kind = t.get("place")
        if not name or kind == "hamlet":
            continue
        p = pop(t)
        is_centre = (round(e["lat"], 3), round(e["lon"], 3)) in admin_centres
        if kind in ("city", "town") or p >= 500 or is_centre:
            candidates.append((e, p, is_centre))
    per_district = defaultdict(int)
    used_ids = set(nodes)
    for e, p, is_centre in sorted(candidates, key=lambda c: -c[1]):
        t = e["tags"]
        name = t["name"]
        if name in by_name and km([e["lat"], e["lon"]], [by_name[name]["lat"], by_name[name]["lon"]]) < 15:
            h = nodes[by_name[name]["id"]]
            h["population"] = h.get("population") or p
            h["district_centre"] = h.get("district_centre", False) or is_centre
            continue
        kind = {"city": "city", "town": "town"}.get(t["place"], "village")
        base = slug(name)
        nid = base
        n = 2
        while nid in used_ids:
            nid = f"{base}_{n}"
            n += 1
        used_ids.add(nid)
        did = district_of([e["lat"], e["lon"]])
        per_district[did] += 1
        danger = round(min(0.95, 0.12 + math.log10(max(p, 50)) * 0.12 + (0.1 if kind != "village" else 0.0)), 2)
        nodes[nid] = {"id": nid, "name": name, "kind": kind, "lat": round(e["lat"], 4), "lon": round(e["lon"], 4),
                      "population": p, "danger": danger, "district": did, "district_centre": is_centre,
                      "loot_table": {"city": "region_city", "town": "region_town"}.get(kind, "region_village")}

    # every rural district gets at least 5 settlements to explore
    taken = {(n["name"], round(n["lat"], 2)) for n in nodes.values()}
    for d in districts:
        if d["kind"] != "district":
            continue
        have = sum(1 for n in nodes.values() if n["district"] == d["id"])
        if have >= 5:
            continue
        extra = []
        for e in places:
            t = e["tags"]
            if t.get("place") not in ("village", "town") or not t.get("name") or (t["name"], round(e["lat"], 2)) in taken:
                continue
            if any(inside([e["lat"], e["lon"]], r) for r in d["polygons"]):
                extra.append((pop(t), e))
        for p, e in sorted(extra, key=lambda x: -x[0])[: 5 - have]:
            t = e["tags"]
            nid = slug(t["name"])
            n = 2
            while nid in used_ids:
                nid = f"{slug(t['name'])}_{n}"
                n += 1
            used_ids.add(nid)
            taken.add((t["name"], round(e["lat"], 2)))
            nodes[nid] = {"id": nid, "name": t["name"], "kind": "village", "lat": round(e["lat"], 4), "lon": round(e["lon"], 4),
                          "population": p, "danger": round(0.12 + math.log10(max(p, 50)) * 0.12, 2), "district": d["id"],
                          "district_centre": False, "loot_table": "region_village"}

    # links: k nearest neighbours within range (plus the hand-made road graph at runtime)
    ids = list(nodes)
    for a in ids:
        pa = [nodes[a]["lat"], nodes[a]["lon"]]
        near = sorted((km(pa, [nodes[b]["lat"], nodes[b]["lon"]]), b) for b in ids if b != a)
        links = [b for dist, b in near[:5] if dist <= 40] or [near[0][1]]
        nodes[a]["links"] = links
    for a in ids:  # symmetric
        for b in nodes[a]["links"]:
            if a not in nodes[b]["links"]:
                nodes[b]["links"].append(a)
    # district centres: city okrugs centre on their city
    for d in districts:
        d["nodes"] = sum(1 for n in nodes.values() if n["district"] in (d["id"], "core:" + d["id"]))
    # references are written fully qualified so packages can extend the map
    for n in nodes.values():
        n["district"] = "core:" + n["district"]
        n["links"] = ["core:" + x for x in n["links"]]
    write("regions", "region", sorted(nodes.values(), key=lambda n: n["id"]))
    write("districts", "district", districts, note)

    # roads
    roads = []
    groups = defaultdict(list)
    for w in load(src, "roads"):
        hw = w["tags"].get("highway", "")
        cls = "federal" if hw in ("motorway", "trunk") else "regional"
        groups[(w["tags"].get("ref", w["tags"].get("name", str(w["id"]))), cls)].append([[g["lat"], g["lon"]] for g in w.get("geometry", [])])
    for (ref, cls), ways in groups.items():
        for i, line in enumerate(stitch_lines(ways)):
            pts = rnd(dp(line, 0.0015))
            if len(pts) >= 2 and not (len(pts) == 2 and km(pts[0], pts[1]) < 1.0):
                roads.append({"id": f"osm_{slug(ref)}_{cls[0]}{i}", "name": ref, "class": cls, "points": pts})
    # keep the hand-made named routes for their "nodes" (travel graph) but don't draw them twice
    hand_roads = json.loads((SRC / "roads_handmade.json").read_text(encoding="utf-8"))["defs"]
    for r in hand_roads:
        if r.get("nodes") and not r["id"].startswith("osm_"):
            r = dict(r)
            r["hidden"] = True
            roads.append(r)
    write("roads", "road", roads, note)

    # rivers (merge ways by name)
    by_river = defaultdict(list)
    for w in load(src, "rivers"):
        by_river[w["tags"]["name"]].append([[g["lat"], g["lon"]] for g in w.get("geometry", [])])
    width = {"Белая": 3.0, "Кама": 3.0, "Уфа": 2.5, "Урал": 2.2, "Сакмара": 1.8, "Дёма": 1.8, "Ик": 1.6, "Юрюзань": 1.6, "Ай": 1.6}
    rivers = []
    for name, ways in by_river.items():
        for i, line in enumerate(stitch_lines(ways)):
            line = rnd(dp(line, 0.002))
            if len(line) >= 2:
                rivers.append({"id": f"{slug(name)}_{i}", "name": name, "width": width.get(name, 1.2), "points": line})
    write("rivers", "river", rivers, note)

    # Ufa: city districts, streets, points of interest
    ufa_d = []
    for rel in load(src, "ufa_districts"):
        if rel["tags"].get("admin_level") != "9":
            continue
        rings = rel_rings(rel, 0.0008)
        if rings:
            c = centroid(rings[0])
            ufa_d.append({"id": "ufa_" + slug(rel["tags"]["name"].replace(" район", "")), "name": rel["tags"]["name"], "city": "ufa",
                          "center": [round(c[0], 4), round(c[1], 4)], "polygons": rings})
    write("ufa_districts", "city_district", ufa_d, note)
    streets = []
    sgroups = defaultdict(list)
    for w in load(src, "ufa_roads"):
        cls = "street" if w["tags"].get("highway") == "secondary" else "avenue"
        sgroups[(w["tags"].get("name", str(w["id"])), cls)].append([[g["lat"], g["lon"]] for g in w.get("geometry", [])])
    for (name, cls), ways in sgroups.items():
        for i, line in enumerate(stitch_lines(ways)):
            pts = rnd(dp(line, 0.0004))
            if len(pts) >= 2:
                streets.append({"id": f"ufa_{slug(name)}_{i}", "name": name, "class": cls, "city": "ufa", "points": pts})
    write("ufa_streets", "road", streets, note)

    def ufa_district_of(pt) -> str:
        for d in ufa_d:
            if any(inside(pt, r) for r in d["polygons"]):
                return d["id"]
        return ""

    places_out = []
    seen = set()
    type_of = [
        ("amenity", "hospital", "hospital"), ("amenity", "police", "police"), ("amenity", "fire_station", "fire_station"),
        ("amenity", "university", "university"), ("amenity", "college", "college"), ("amenity", "marketplace", "market"),
        ("amenity", "prison", "prison"), ("amenity", "bus_station", "bus_station"), ("amenity", "townhall", "townhall"),
        ("amenity", "school", "school"), ("amenity", "fuel", "fuel"), ("shop", "mall", "mall"), ("shop", "supermarket", "supermarket"),
        ("railway", "station", "station"), ("leisure", "stadium", "stadium"), ("leisure", "park", "park"),
        ("power", "plant", "power_plant"), ("man_made", "works", "industrial"), ("landuse", "industrial", "industrial"),
    ]
    quota = {"school": 3, "supermarket": 3, "fuel": 2, "park": 2, "industrial": 3, "hospital": 3, "police": 2,
             "college": 2, "university": 2, "mall": 2, "market": 2, "station": 2, "stadium": 1, "fire_station": 1,
             "bus_station": 1, "townhall": 1, "prison": 1, "power_plant": 1, "military": 1}
    count = defaultdict(int)
    elements = []
    for f in sorted(src.glob("poi_*.json")):
        try:
            elements += json.loads(f.read_text(encoding="utf-8"))["elements"]
        except (ValueError, KeyError):
            print(f"skip broken {f.name}")
    for e in elements:
        t = e.get("tags", {})
        name = t.get("name", "").strip()
        lat = e.get("lat", e.get("center", {}).get("lat"))
        lon = e.get("lon", e.get("center", {}).get("lon"))
        if not name or lat is None:
            continue
        ptype = "military" if "military" in t else next((pt for k, v, pt in type_of if t.get(k) == v), "")
        if not ptype:
            continue
        did = ufa_district_of([lat, lon])
        if not did:
            continue
        key = (name.lower(), did)
        if key in seen or count[(did, ptype)] >= quota.get(ptype, 2):
            continue
        seen.add(key)
        count[(did, ptype)] += 1
        base = f"ufa_{ptype}_{slug(name)}"[:56]
        pid, n = base, 2
        while any(p["id"] == pid for p in places_out):
            pid, n = f"{base}_{n}", n + 1
        places_out.append({"id": pid, "name": name[:60], "type": ptype, "city": "ufa", "city_district": "core:" + did,
                           "lat": round(lat, 5), "lon": round(lon, 5)})
    # residential yards along named streets: 3 per city district
    yards = defaultdict(int)
    for st in sorted(streets, key=lambda x: -len(x["points"])):
        name = st["name"]
        if not name or name.isdigit() or name.startswith("ufa"):
            continue
        mid = st["points"][len(st["points"]) // 2]
        did = ufa_district_of(mid)
        if not did or yards[did] >= 3 or any(p["name"].endswith(name) for p in places_out):
            continue
        yards[did] += 1
        places_out.append({"id": f"ufa_yard_{slug(name)}"[:56], "name": f"Дворы: {name}", "type": "residential", "city": "ufa",
                           "city_district": "core:" + did, "lat": round(mid[0] + 0.0015, 5), "lon": round(mid[1] + 0.0015, 5)})
    # the hand-made starting courtyard
    places_out.append({"id": "ufa_chernikovka_yard", "name": "Двор на Первомайской (Черниковка)", "type": "residential", "city": "ufa",
                       "city_district": "core:" + (ufa_district_of([54.8075, 56.1050]) or (ufa_d[0]["id"] if ufa_d else "")),
                       "lat": 54.8075, "lon": 56.1050, "location": "ufa_chernikovka", "start": True})
    write("ufa_places", "place", places_out, note)
    return 0


def stitch_lines(ways: list[list]) -> list[list]:
    """Joins polylines that share endpoints (open rivers)."""
    lines = [w for w in ways if len(w) >= 2]
    key = lambda p: (round(p[0], 6), round(p[1], 6))
    out = []
    while lines:
        cur = lines.pop(0)
        changed = True
        while changed:
            changed = False
            for i, w in enumerate(lines):
                if key(w[0]) == key(cur[-1]):
                    cur += w[1:]
                elif key(w[-1]) == key(cur[0]):
                    cur = w[:-1] + cur
                elif key(w[-1]) == key(cur[-1]):
                    cur += w[::-1][1:]
                elif key(w[0]) == key(cur[0]):
                    cur = w[::-1][:-1] + cur
                else:
                    continue
                lines.pop(i)
                changed = True
                break
        out.append(cur)
    return out


if __name__ == "__main__":
    sys.exit(main(Path(sys.argv[1] if len(sys.argv) > 1 else "osm")))
