#!/usr/bin/env bash
# Downloads OpenStreetMap extracts of Bashkortostan used by tools/osm_to_map.py.
# Usage: tools/osm_fetch.sh [out_dir=osm]   then: python3 tools/osm_to_map.py osm
# Data © OpenStreetMap contributors (ODbL). Overpass servers are busy: the
# script retries on 504.
set -uo pipefail
OUT="${1:-osm}"
mkdir -p "$OUT"
U="${OVERPASS_URL:-https://maps.mail.ru/osm/tools/overpass/api/interpreter}"
q() { for i in $(seq 1 10); do code=$(curl -sS -m 300 -o "$OUT/$1.json" -w "%{http_code}" "$U" --data-urlencode "data=$2"); echo "$1 try $i: $code"; [ "$code" = 200 ] && return 0; sleep 15; done; return 1; }
A='rel["ISO3166-2"="RU-BA"];map_to_area->.a;'
UFA='rel["name"="городской округ Уфа"]["admin_level"="6"];map_to_area->.u;'
RIVERS='Белая|Уфа|Дёма|Сим|Ик|Сакмара|Юрюзань|Ай|Инзер|Зилим|Таналык|Кама|Нугуш|Зилаир|Быстрый Танып|Танып|Чермасан|Бирь|Сюнь|Урал|Большой Ик|Усолка|Стерля|Ашкадар|Уршак|Кармасан|Лемеза|Баса|Зиган'
q districts "[out:json][timeout:280];${A}rel(area.a)[\"boundary\"=\"administrative\"][\"admin_level\"=\"6\"];out geom;"
q republic "[out:json][timeout:280];rel[\"ISO3166-2\"=\"RU-BA\"];out geom;"
q places "[out:json][timeout:280];${A}node(area.a)[\"place\"~\"^(city|town|village|hamlet)$\"];out;"
q roads "[out:json][timeout:280];${A}way(area.a)[\"highway\"~\"^(motorway|trunk|primary)$\"];out geom;"
q rivers "[out:json][timeout:280];${A}way(area.a)[\"waterway\"=\"river\"][\"name\"~\"^(${RIVERS})$\"];out geom;"
q ufa_districts "[out:json][timeout:200];${UFA}rel(area.u)[\"boundary\"=\"administrative\"][\"admin_level\"=\"9\"];out geom;"
q ufa_roads "[out:json][timeout:250];${UFA}way(area.u)[\"highway\"~\"^(motorway|trunk|primary|secondary)$\"];out geom;"
q poi_amenity "[out:json][timeout:150];${UFA}nwr(area.u)[\"amenity\"~\"^(hospital|police|fire_station|university|college|marketplace|prison|bus_station|townhall)$\"][\"name\"];out center tags;"
q poi_shop "[out:json][timeout:150];${UFA}nwr(area.u)[\"shop\"~\"^(mall|supermarket)$\"][\"name\"];out center tags;"
q poi_school "[out:json][timeout:150];${UFA}nwr(area.u)[\"amenity\"=\"school\"][\"name\"];out center tags;"
q poi_misc "[out:json][timeout:150];${UFA}(nwr(area.u)[\"railway\"=\"station\"][\"name\"];nwr(area.u)[\"leisure\"~\"^(stadium|park)$\"][\"name\"];nwr(area.u)[\"military\"][\"name\"];nwr(area.u)[\"power\"=\"plant\"][\"name\"];nwr(area.u)[\"amenity\"=\"fuel\"][\"name\"];);out center tags;"
q poi_industrial "[out:json][timeout:150];${UFA}(way(area.u)[\"landuse\"=\"industrial\"][\"name\"];rel(area.u)[\"landuse\"=\"industrial\"][\"name\"];nwr(area.u)[\"man_made\"=\"works\"][\"name\"];);out center tags;"
