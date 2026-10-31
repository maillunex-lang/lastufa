# Моддинг (API модов v1)

## Структура мода

```
mod.json            (или manifest.json)
preview.png         (необязательно)
README.md
data/               JSON-определения контента
assets/             текстуры, модели GLB/GLTF, звук OGG/WAV/MP3
scripts/            декларативные правила (JSON)
locale/             переводы (зарезервировано)
```

Минимальный `mod.json`:

```json
{"id": "my.mod", "name": "Мой мод", "type": "MOD", "category": "items", "version": "1.0.0", "min_game_version": "0.1.0", "api_version": 1}
```

`category` — группа в каталоге: `system` (обновления игры), `locations`, `items`, `zombies`, `quests`,
`gameplay`, `graphics`, `audio`, `localization`, `other`. Если не указана, определяется по типу пакета и
по именам файлов (`data/items*.json` → предметы, `assets/*.png` → графика, `*.ogg` → звук…).

Сборка с контрольными суммами и подписью: `python3 tools/afpkg.py build path/to/mod --out dist`.
Мод без списка файлов тоже установится, но с пометкой «целостность не подтверждена».

## Файлы данных

Любой `*.json` в `data/` (рекурсивно):

```json
{"kind": "item", "defs": [ {"id": "echpochmak", "name": "Эчпочмак", "category": "food", "weight": 0.25, "use": {"hunger": 28}} ]}
```

- Короткий id получает пространство имён пакета: `my.mod:echpochmak`. Ссылки на чужой контент — полным id (`core:crowbar`). Короткая ссылка ищется сначала в своём пакете, затем в `core`.
- Определение с уже существующим полным id **заменяет** его (переопределение; побеждает пакет, загруженный позже).
- `"patch": true` — **глубокое слияние** с существующим определением (например, поднять ценность мёда, не переписывая всё).
- Ошибки в данных не роняют игру: определение пропускается и показывается во вкладке «Установленные».

### Виды данных и обязательные поля

| kind | обязательные поля | полезные поля |
|---|---|---|
| `item` | name, category, weight | stack, value, spoil_hours, description, use{hunger, thirst, stress, health, cures[], pain_relief_hours, sickness_chance, infection_delay_hours}, weapon{type melee/firearm, damage, range, arc_deg, cooldown, stamina, noise, wear, ammo, mag, pellets, spread_deg, reload_time, falloff_start}, clothing{slot, insulation, rain_protection} |
| `zombie` | name, hp, speed_walk, damage | speed_run, attack_cooldown, attack_range, sight, fov_deg, hearing, smell, armor, infect_chance, bleed_chance, burn_chance, behavior (shambler/runner/lurker/brute), color, scale, memory_sec, light_sensitivity, loot_table |
| `loot_table` | entries[{item, weight, min, max, quality[a,b]}] | rolls[min,max], empty_chance |
| `location` | name, size[w,d] | region, ground_color, player_spawn, patches, buildings[{name,pos,size,color,kind}], props[{type car/bus/barricade/bench/swing/tree,pos,rot,color}], lights, containers[{id,name,pos,loot_table,search_sec}], zombie_spawns[{type,pos,count,radius}], exits |
| `region` | name, lat, lon, kind | population, danger, loot_table, location, description |
| `road` | name, points[[lat,lon]] | class, nodes[region ids] (рёбра графа путешествий) |
| `river`, `border` | points | name, width |
| `need` | name, max | start, decay_per_hour, critical, damage_per_hour_at_zero, sleep_recovery_per_hour |
| `climate` | season, base_temp, weather{state: weight} | daily_amp |
| `rule` | on, actions | if, once, cooldown_minutes |

Пример привязки новой детальной локации к существующему району карты — `content_src/region_sterlitamak/data/region_patch.json`.

## Правила-скрипты (`scripts/*.json`)

Моды **не могут исполнять код**. Поведение описывается правилами:

```json
{"kind": "rule", "defs": [
  {"id": "grandma_gift", "on": "day_passed",
   "if": [{"field": "day", "op": "==", "value": 3}],
   "once": true,
   "actions": [
     {"type": "journal", "category": "mod", "text": "У подъезда — узелок…"},
     {"type": "give_item", "item": "echpochmak", "qty": 3}
   ]}
]}
```

**События:** `day_passed{day}`, `hour_passed{hour, day}`, `zombie_killed{type, kills}`, `item_used{item}`, `location_entered{location}`, `container_looted{container, location}`, `region_visited{region}`, `session_started`.

**Условия:** `field` — поле события или `flag:<имя>`, `season`, `hour`, `region`; `op` — `== != > < >= <= in exists`.

**Действия:**

| type | параметры | ограничения |
|---|---|---|
| `journal` | text, category | 600 символов |
| `notify` | text, kind (info/good/warn/danger) | 200 символов |
| `give_item` | item, qty | qty ≤ 20 |
| `add_stress` | amount | −50…50 |
| `reveal_region` | region, level | уровень 1–2 |
| `set_flag` | flag, value | имя ≤ 48 символов |

Лимиты: ≤ 8 действий в правиле, ≤ 16 срабатываний на одно событие. Правила с неизвестными событиями/действиями отклоняются при загрузке. Состояние правил (`once`, флаги, время последнего срабатывания) хранится в сохранении.

## Ассеты

Ссылка вида `"my.mod:assets/models/car.glb"` или путь относительно пакета. `Assets.load_async(path, cb)` загружает PNG/JPG/WebP (в текстуру с мипмапами), GLB/GLTF (в `PackedScene`), OGG/WAV/MP3. Кэш ограничен бюджетом профиля устройства.

> Подстановка GLB-моделей вместо примитивов в построителе локаций (поле `model`) запланирована, но ещё не подключена.

## Версионирование API

`api_version` в манифесте сравнивается с `AfPaths.MOD_API_VERSION` (сейчас 1). Новые события/действия добавляются без смены версии; несовместимые изменения повышают версию, старые моды тогда отключаются с понятной причиной, а не ломают игру.
