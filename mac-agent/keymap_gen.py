#!/usr/bin/env python3
"""
Генератор подписей для окна подсказок раскладки.

Читает config/cradio.keymap и пишет keymap.json, который агент кладёт в бандл
(Contents/Resources). Раскладку руками не дублируем: поправили keymap —
перегенерировали JSON, и окно показывает новое.

Что разбирается:
  * #define с одним значением (номера слоёв, VOICE_*, LANG_* и т. п.);
  * узел keymap: слои по порядку (порядок = id слоя ZMK, он же бит в маске);
  * conditional_layers, combos, macros (для подписей макросов).

Подписи готовятся сразу для трёх режимов ОС: mac, win, lnx. Отличаются они
только названиями модификаторов (⌘ / Win / Super) и смысловыми пояснениями
(⌘C «Копировать» на Маке, Ctrl+C — в Windows).

Запуск: keymap_gen.py <cradio.keymap> <keymap.json>
Вместо пути к JSON можно дать mac, win или lnx — напечатает таблицу слоёв
в этом режиме для проверки глазами.
"""

import json
import re
import sys

MODES = ("mac", "win", "lnx")

# --- позиции Sweep ------------------------------------------------------------

KEY_COUNT = 34

# Большие пальцы: 30 и 31 — левая половина, 32 и 33 — правая (внешний = дальний
# от центра). Буквенные позиции называются по подписи на базовом слое.
THUMB_NAMES = {
    30: "левый внешний большой",
    31: "левый внутренний большой",
    32: "правый внутренний большой",
    33: "правый внешний большой",
}

# --- клавиши ------------------------------------------------------------------

KEY_NAMES = {
    "SPACE": "Space", "SPC": "Space",
    "BSPC": "⌫", "BACKSPACE": "⌫",
    "DEL": "Del ⌦", "DELETE": "Del ⌦",
    "RET": "⏎", "ENTER": "⏎", "RETURN": "⏎",
    "ESC": "Esc", "ESCAPE": "Esc",
    "TAB": "Tab ⇥",
    "CAPS": "Caps ⇪", "CAPSLOCK": "Caps ⇪",
    "LEFT": "←", "LEFT_ARROW": "←", "RIGHT": "→", "RIGHT_ARROW": "→",
    "UP": "↑", "UP_ARROW": "↑", "DOWN": "↓", "DOWN_ARROW": "↓",
    "HOME": "Home", "END": "End", "PG_UP": "PgUp", "PG_DN": "PgDn",
    "PSCRN": "PrtSc", "PRINTSCREEN": "PrtSc", "INS": "Ins", "INSERT": "Ins",
    "HASH": "#", "POUND": "#", "UNDER": "_", "UNDERSCORE": "_",
    "LPAR": "(", "RPAR": ")", "LBKT": "[", "RBKT": "]", "LBRC": "{", "RBRC": "}",
    "EQUAL": "=", "QMARK": "?", "QUESTION": "?", "SQT": "'", "APOS": "'",
    "PLUS": "+", "STAR": "*", "ASTRK": "*", "DLLR": "$", "DOLLAR": "$",
    "AMPS": "&", "AT": "@", "EXCL": "!", "DQT": "\"", "MINUS": "-",
    "SLASH": "/", "FSLH": "/", "GRAVE": "`", "BSLH": "\\", "BACKSLASH": "\\",
    "PRCNT": "%", "PERCENT": "%", "TILDE": "~", "PIPE": "|", "CARET": "^",
    "SEMI": ";", "SEMICOLON": ";", "COLON": ":", "COMMA": ",", "DOT": ".",
    "PERIOD": ".", "LT": "<", "GT": ">",
    "C_VOLUME_UP": "Громче 🔊", "C_VOL_UP": "Громче 🔊", "K_VOLUME_UP": "Громче 🔊",
    "C_VOLUME_DOWN": "Тише 🔉", "C_VOL_DN": "Тише 🔉", "K_VOLUME_DOWN": "Тише 🔉",
    "K_MUTE": "Без звука 🔇", "C_MUTE": "Без звука 🔇",
    "K_PREVIOUS": "⏮", "C_PREV": "⏮", "C_PREVIOUS": "⏮",
    "K_NEXT": "⏭", "C_NEXT": "⏭",
    "K_PLAY_PAUSE": "⏯", "C_PP": "⏯", "C_PLAY_PAUSE": "⏯",
    "C_BRI_UP": "Ярче ☀", "C_BRI_DN": "Темнее ☀",
}

MEDIA_KEYS = {k for k in KEY_NAMES if k.startswith(("C_", "K_"))}

# Что даёт Shift на американской раскладке — чтобы LS(N6) читалось как «^».
SHIFTED = {
    "1": "!", "2": "@", "3": "#", "4": "$", "5": "%", "6": "^", "7": "&",
    "8": "*", "9": "(", "0": ")", "-": "_", "=": "+", "[": "{", "]": "}",
    "\\": "|", ";": ":", "'": "\"", "`": "~", ",": "<", ".": ">", "/": "?",
}

# Клавиши-модификаторы сами по себе. C — Ctrl, A — Alt, S — Shift, G — Gui.
MOD_KEYS = {
    "LCTRL": "C", "LEFT_CONTROL": "C", "LCTL": "C", "RCTRL": "C", "RIGHT_CONTROL": "C",
    "LALT": "A", "LEFT_ALT": "A", "RALT": "A", "RIGHT_ALT": "A", "LOPT": "A",
    "LSHFT": "S", "LEFT_SHIFT": "S", "LSHIFT": "S", "RSHFT": "S", "RIGHT_SHIFT": "S",
    "LGUI": "G", "LEFT_GUI": "G", "LCMD": "G", "LEFT_COMMAND": "G", "LWIN": "G",
    "RGUI": "G", "RCMD": "G", "RIGHT_COMMAND": "G",
}

MOD_FUNCS = {
    "LC": "C", "RC": "C", "LA": "A", "RA": "A", "LS": "S", "RS": "S", "LG": "G", "RG": "G",
}

MOD_ORDER = "CASG"  # ключи таблицы SEMANTICS и порядок Apple: ⌃⌥⇧⌘

# Порядок в подписи: на Маке как в меню macOS, в Windows и Linux клавиша Win
# по привычке первой — «Win+Shift+S», «Super+Ctrl+X».
LABEL_ORDER = {"mac": "CASG", "win": "GCAS", "lnx": "GCAS"}

MOD_TEXT = {
    "mac": {"C": "⌃", "A": "⌥", "S": "⇧", "G": "⌘"},
    "win": {"C": "Ctrl", "A": "Alt", "S": "Shift", "G": "Win"},
    "lnx": {"C": "Ctrl", "A": "Alt", "S": "Shift", "G": "Super"},
}

MOD_ALONE = {
    "mac": {"C": "⌃ Control", "A": "⌥ Option", "S": "⇧ Shift", "G": "⌘ Command"},
    "win": {"C": "Ctrl", "A": "Alt", "S": "⇧ Shift", "G": "Win"},
    "lnx": {"C": "Ctrl", "A": "Alt", "S": "⇧ Shift", "G": "Super"},
}

# --- смысл сочетаний ------------------------------------------------------------
#
# Ключ — модификаторы в порядке MOD_ORDER, «+», имя клавиши ZMK. Значение —
# пояснение и признак опасности (закрывает окно или программу).

SEMANTICS = {
    "mac": {
        "G+Z": "Отменить", "G+X": "Вырезать", "G+C": "Копировать", "G+V": "Вставить",
        "G+A": "Выделить всё", "G+S": "Сохранить", "G+O": "Открыть", "G+F": "Найти",
        "G+P": "Печать", "G+R": "Обновить", "G+N": "Новое окно",
        "G+Q": ("Выйти из программы", True), "G+W": ("Закрыть окно", True),
        "C+SPACE": "Смена языка", "G+SPACE": "Смена языка",
        "SG+N3": "Снимок экрана", "SG+NUMBER_3": "Снимок экрана",
        "SG+N4": "Снимок области", "SG+NUMBER_4": "Снимок области",
        "G+LEFT": "Начало строки", "G+RIGHT": "Конец строки",
        "G+UP": "Начало документа", "G+DOWN": "Конец документа",
        "G+BSPC": "Стереть до начала строки", "G+BACKSPACE": "Стереть до начала строки",
        "CAG+SPACE": "Голосовой ввод",
    },
    "win": {
        "C+Z": "Отменить", "C+X": "Вырезать", "C+C": "Копировать", "C+V": "Вставить",
        "C+A": "Выделить всё", "C+S": "Сохранить", "C+O": "Открыть", "C+F": "Найти",
        "C+P": "Печать", "C+N": "Новое окно", "F5": "Обновить",
        "A+F4": ("Закрыть окно", True),
        "HOME": "Начало строки", "END": "Конец строки",
        "C+HOME": "Начало документа", "C+END": "Конец документа",
        "G+SPACE": "Смена языка", "G+H": "Голосовой ввод",
        "G+PSCRN": "Снимок экрана", "SG+S": "Снимок области",
    },
    "lnx": {
        "C+Z": "Отменить", "G+X": "Вырезать", "G+C": "Копировать", "G+V": "Вставить",
        "C+A": "Выделить всё", "C+S": "Сохранить", "C+O": "Открыть", "C+F": "Найти",
        "C+P": "Печать", "C+N": "Новое окно", "F5": "Обновить",
        "G+W": ("Закрыть окно", True), "A+F4": ("Закрыть окно", True),
        "HOME": "Начало строки", "END": "Конец строки",
        "C+HOME": "Начало документа", "C+END": "Конец документа",
        "CG+C": "Меню снимка экрана", "PSCRN": "Снимок области",
        "CS": "Смена языка", "CG+X": "Голосовой ввод",
    },
}

# Имена действий по префиксу #define, через который клавиша попала в раскладку.
DEFINE_ACTIONS = {
    "VOICE_": "Голосовой ввод",
    "LANG_": "Смена языка",
}

# Макросы — по метке узла. Неизвестный макрос подписывается сочетанием,
# которое он отправляет, и пометкой «макрос».
MACRO_ACTIONS = {
    "win_lang": ("Смена языка", False),
    "win_voice": ("Голосовой ввод", False),
    "win_shot": ("Снимок экрана", False),
    "win_area": ("Снимок области", False),
    "alt_f4": ("Закрыть окно", True),
    "alt_tab": ("Предыдущее окно", False),
    "del_bol": ("Стереть до начала строки", False),
}

# --- разбор devicetree -----------------------------------------------------------


def strip_comments(text):
    text = re.sub(r"/\*.*?\*/", " ", text, flags=re.DOTALL)
    return re.sub(r"//[^\n]*", " ", text)


def read_defines(text):
    defines = {}
    for m in re.finditer(r"^[ \t]*#define[ \t]+([A-Za-z_]\w*)[ \t]+([^\n]+)$", text, re.MULTILINE):
        defines[m.group(1)] = m.group(2).strip()
    return defines


def find_block(text, header_regex, start=0):
    """Тело первого узла, чей заголовок подходит под regex: (имя, тело, конец)."""
    m = re.compile(header_regex).search(text, start)
    if not m:
        return None
    i = text.index("{", m.end() - 1)
    depth = 0
    for j in range(i, len(text)):
        if text[j] == "{":
            depth += 1
        elif text[j] == "}":
            depth -= 1
            if depth == 0:
                return m, text[i + 1 : j], j + 1
    raise ValueError("незакрытая скобка после " + m.group(0))


def child_nodes(body):
    """Прямые потомки узла: [(метка или None, имя, тело)]."""
    nodes = []
    pos = 0
    rx = re.compile(r"(?:([A-Za-z_]\w*)\s*:\s*)?([A-Za-z_][\w\-,@]*)\s*\{")
    while True:
        found = find_block(body, rx.pattern, pos)
        if not found:
            break
        m, inner, end = found
        nodes.append((m.group(1), m.group(2), inner))
        pos = end
    return nodes


def prop(body, name):
    m = re.search(r"(?<![\w-])" + re.escape(name) + r"\s*=\s*<([^>]*)>\s*;", body, re.DOTALL)
    return m.group(1) if m else None


def expand(token, defines, depth=0):
    if depth > 10:
        return token
    out = re.sub(
        r"\b[A-Za-z_]\w*\b",
        lambda m: defines[m.group(0)] if m.group(0) in defines else m.group(0),
        token,
    )
    return out if out == token else expand(out, defines, depth + 1)


def split_bindings(text, defines):
    """
    Список привязок: [(поведение, [параметры], define-источник)].

    Токены режутся по пробелам. Привязка начинается с «&поведение» или с
    имени #define, раскрывающегося в «&…» (VOICE_MAC). Вложенные скобки
    LC(LA(LG(SPACE))) пробелов не содержат и идут одним токеном.
    """
    result = []
    for raw in text.split():
        origin = None
        token = raw
        if not raw.startswith("&") and raw in defines and expand(raw, defines).startswith("&"):
            origin = raw
            token = expand(raw, defines)
        if token.startswith("&"):
            parts = token.split()
            result.append([parts[0][1:], [expand(p, defines) for p in parts[1:]], origin])
        else:
            if not result:
                raise ValueError("параметр без поведения: " + raw)
            result[-1][1].append(expand(raw, defines))
    return [tuple(b) for b in result]


def numbers(text, defines):
    return [int(expand(t, defines), 0) for t in text.split()]


# --- подписи ------------------------------------------------------------------------


def parse_chord(param):
    """LC(LA(LG(SPACE))) -> ({'C','A','G'}, 'SPACE')."""
    mods = set()
    while True:
        m = re.fullmatch(r"([A-Z]{2})\((.*)\)", param)
        if not m or m.group(1) not in MOD_FUNCS:
            break
        mods.add(MOD_FUNCS[m.group(1)])
        param = m.group(2)
    return mods, param


def key_text(key):
    if key in KEY_NAMES:
        return KEY_NAMES[key]
    m = re.fullmatch(r"(?:NUMBER_|N)(\d)", key)
    if m:
        return m.group(1)
    if re.fullmatch(r"F\d{1,2}", key):
        return key
    if re.fullmatch(r"[A-Z]", key):
        return key
    return key.replace("_", " ").title()


def mods_key(mods):
    return "".join(c for c in MOD_ORDER if c in mods)


def chord_label(mods, key, mode):
    """Подпись сочетания: «⌘C» на Маке, «Ctrl+C» в Windows."""
    if not mods and key in MOD_KEYS:
        return MOD_ALONE[mode][MOD_KEYS[key]]
    text = key_text(key)
    if mods == {"S"} and text in SHIFTED:
        return SHIFTED[text]
    if not mods:
        return text
    ordered = [MOD_TEXT[mode][c] for c in LABEL_ORDER[mode] if c in mods]
    if mode == "mac":
        return "".join(ordered) + text
    return "+".join(ordered + [text])


def semantic(mods, key, mode):
    """(пояснение, опасно) по таблице SEMANTICS или (None, False)."""
    table = SEMANTICS[mode]
    variants = [mods_key(mods) + "+" + key, key] if mods else [key]
    if key in MOD_KEYS and not mods:
        variants = []
    # «Ctrl+Shift» в Omarchy — это LC(LSHFT): модификатор как клавиша.
    if key in MOD_KEYS and mods:
        variants = [mods_key(mods | {MOD_KEYS[key]})]
    for v in variants:
        if v in table:
            value = table[v]
            return (value, False) if isinstance(value, str) else value
    return None, False


def same(value):
    return {m: value for m in MODES}


def macro_chord(macro, mode):
    """Что отправляет макрос, в виде «Win+Space» или «Shift+Home, ⌫»."""
    steps = []
    held = set()
    action = "tap"
    for name, params, _ in macro:
        if name in ("macro_press", "macro_release", "macro_tap"):
            action = name[6:]
            continue
        if name != "kp" or not params:
            continue
        mods, key = parse_chord(params[0])
        if action == "press" and key in MOD_KEYS and not mods:
            held.add(MOD_KEYS[key])
        elif action == "release":
            continue
        else:
            steps.append(chord_label(held | mods, key, mode))
    return ", ".join(steps)


class Labeler:
    def __init__(self, layer_names, macros, hold_taps):
        self.layer_names = layer_names
        self.macros = macros
        self.hold_taps = hold_taps

    def layer_name(self, index):
        return self.layer_names.get(index, f"L{index}")

    def kp(self, param):
        mods, key = parse_chord(param)
        label, note, danger = {}, {}, {}
        for mode in MODES:
            label[mode] = chord_label(mods, key, mode)
            n, d = semantic(mods, key, mode)
            note[mode] = n
            danger[mode] = d
        kind = "media" if key in MEDIA_KEYS else ("mod" if key in MOD_KEYS and not mods else "key")
        return {"t": "key", "kind": kind, "label": label, "note": note, "danger": danger}

    def binding(self, name, params, origin):
        if name == "trans":
            return {"t": "trans"}
        if name == "none":
            return {"t": "none"}

        key = self._binding(name, params)

        # Клавиша пришла через #define с понятным смыслом (VOICE_WIN, LANG_LNX):
        # крупно — действие словами, мелко — что именно уходит на хост.
        if origin:
            for prefix, action in DEFINE_ACTIONS.items():
                if origin.startswith(prefix):
                    key["note"] = dict(key["label"])
                    key["label"] = same(action)
                    key["kind"] = "action"
        return key

    def _binding(self, name, params):
        if name == "kp":
            return self.kp(params[0])

        if name in self.macros:
            title, danger = MACRO_ACTIONS.get(name, (None, False))
            chord = {m: macro_chord(self.macros[name], m) for m in MODES}
            if title is None:
                return {"t": "key", "kind": "macro", "label": chord,
                        "note": same("макрос"), "danger": same(False)}
            return {"t": "key", "kind": "action", "label": same(title),
                    "note": chord, "danger": same(danger)}

        if name in ("mo", "tog", "to", "sl"):
            target = int(params[0])
            hint = {"mo": "удерживать", "tog": "вкл/выкл", "to": "перейти", "sl": "на одно нажатие"}[name]
            return {"t": "key", "kind": "layer", "layer": target,
                    "label": same(self.layer_name(target)), "note": same(hint),
                    "danger": same(False)}

        if name == "lt":
            target = int(params[0])
            tap = self.kp(params[1])
            tap["hold"] = same(self.layer_name(target))
            return tap

        if name == "mt" or name in self.hold_taps:
            # Привязка hold-tap: первый параметр — удержание, второй — нажатие.
            tap = self.kp(params[1])
            hold = self.kp(params[0])
            tap["hold"] = hold["label"]
            return tap

        if name == "bt":
            cmd = params[0]
            if cmd == "BT_SEL":
                n = int(params[1]) + 1
                return {"t": "key", "kind": "bt", "label": same(f"BT {n}"),
                        "note": same(f"профиль {n}"), "danger": same(True)}
            texts = {
                "BT_CLR_ALL": ("Забыть все BT", "стирает все пары"),
                "BT_CLR": ("Забыть BT", "стирает текущую пару"),
                "BT_NXT": ("BT дальше", "следующий профиль"),
                "BT_PRV": ("BT назад", "предыдущий профиль"),
                "BT_DISC": ("Отключить BT", f"профиль {(params[1:] or [''])[0]}"),
            }
            label, note = texts.get(cmd, (cmd, "Bluetooth"))
            return {"t": "key", "kind": "bt", "label": same(label), "note": same(note),
                    "danger": same(True)}

        if name == "out":
            texts = {"OUT_USB": "Вывод USB", "OUT_BLE": "Вывод BLE", "OUT_TOG": "USB ⇄ BLE"}
            return {"t": "key", "kind": "out", "label": same(texts.get(params[0], params[0])),
                    "note": same("куда идут нажатия"), "danger": same(True)}

        if name == "studio_unlock":
            return {"t": "key", "kind": "danger", "label": same("Studio"),
                    "note": same("разблокировать"), "danger": same(True)}
        if name in ("bootloader", "sys_reset"):
            text = "Загрузчик" if name == "bootloader" else "Перезагрузка"
            return {"t": "key", "kind": "danger", "label": same(text),
                    "note": same("клавиатуры"), "danger": same(True)}
        if name == "caps_word":
            return {"t": "key", "kind": "key", "label": same("Caps Word"),
                    "note": same(None), "danger": same(False)}

        return {"t": "key", "kind": "other", "label": same("&" + name),
                "note": same(" ".join(params) or None), "danger": same(False)}


def position_name(pos, base_keys):
    if pos in THUMB_NAMES:
        return THUMB_NAMES[pos]
    key = base_keys[pos]
    if key.get("t") == "key":
        return key["label"]["mac"]
    return f"клавиша {pos}"


def bindings_text(body):
    """Всё содержимое bindings = <…>, <…>; одной строкой."""
    m = re.search(r"\bbindings\s*=\s*(.*?);", body, re.DOTALL)
    return " ".join(re.findall(r"<([^>]*)>", m.group(1))) if m else ""


def iter_blocks(text, header):
    pos = 0
    while True:
        found = find_block(text, header, pos)
        if not found:
            return
        _, body, pos = found
        yield body


def read_behaviors(text, defines):
    """Макросы по метке узла и метки поведений hold-tap."""
    macros, hold_taps = {}, set()
    for header in (r"\bmacros\s*\{", r"\bbehaviors\s*\{"):
        for body in iter_blocks(text, header):
            for label, _, inner in child_nodes(body):
                compat = re.search(r'compatible\s*=\s*"([^"]+)"', inner)
                if not label or not compat:
                    continue
                if compat.group(1) == "zmk,behavior-macro":
                    macros[label] = split_bindings(bindings_text(inner), defines)
                elif compat.group(1) == "zmk,behavior-hold-tap":
                    hold_taps.add(label)
    return macros, hold_taps


def read_layers(text, defines, labeler, layer_names):
    _, keymap_body, _ = find_block(text, r"\bkeymap\s*\{")
    layers = []
    for index, (_, node, body) in enumerate(child_nodes(keymap_body)):
        bindings = split_bindings(prop(body, "bindings"), defines)
        if len(bindings) != KEY_COUNT:
            raise ValueError(f"слой {node}: {len(bindings)} привязок вместо {KEY_COUNT}")
        display = re.search(r'display-name\s*=\s*"([^"]+)"', body)
        name = display.group(1) if display else layer_names.get(index, node)
        if index == 0 and name == "QWERTY":
            name = "BASE"
        layers.append({"index": index, "node": node, "name": name})
    labeler.layer_names = {layer["index"]: layer["name"] for layer in layers}
    for layer, (_, _, body) in zip(layers, child_nodes(keymap_body), strict=True):
        bindings = split_bindings(prop(body, "bindings"), defines)
        layer["keys"] = [labeler.binding(*b) for b in bindings]
    return layers


def read_conditional(text, defines):
    found = find_block(text, r"\bconditional_layers\s*\{")
    if not found:
        return []
    return [
        {
            "if": numbers(prop(body, "if-layers"), defines),
            "then": numbers(prop(body, "then-layer"), defines)[0],
        }
        for _, _, body in child_nodes(found[1])
    ]


def read_combos(text, defines, labeler):
    found = find_block(text, r"\bcombos\s*\{")
    if not found:
        return []
    combos = []
    for _, node, body in child_nodes(found[1]):
        only = prop(body, "layers")
        combos.append({
            "node": node,
            "positions": numbers(prop(body, "key-positions"), defines),
            "binding": labeler.binding(*split_bindings(prop(body, "bindings"), defines)[0]),
            "layers": numbers(only, defines) if only else [],
        })
    return combos


def generate(path):
    with open(path, encoding="utf-8") as f:
        text = strip_comments(f.read())
    defines = read_defines(text)
    text = re.sub(r"^[ \t]*#[^\n]*$", " ", text, flags=re.MULTILINE)

    # Номер слоя -> имя из #define (QWERTY, SYM_2 …), если такой есть.
    layer_names = {}
    for name, value in defines.items():
        if re.fullmatch(r"\d+", value) and name.isupper():
            layer_names.setdefault(int(value), name)

    macros, hold_taps = read_behaviors(text, defines)
    labeler = Labeler(layer_names, macros, hold_taps)
    layers = read_layers(text, defines, labeler, layer_names)
    combos = read_combos(text, defines, labeler)
    flags = {"win": int(defines.get("WIN", -1)), "lnx": int(defines.get("LNX", -1))}

    return {
        "source": "config/cradio.keymap",
        "keyCount": KEY_COUNT,
        "flags": flags,
        "layers": layers,
        "conditional": read_conditional(text, defines),
        "combos": combos,
        "hints": access_hints(layers, combos, flags),
    }


HOW = {"удерживать": "удерживать", "вкл/выкл": "нажать (вкл/выкл)", "перейти": "нажать"}


def key_ways(layers, target, base_keys):
    """Клавиши, ведущие на слой: «удерживать правый внешний большой»."""
    ways = []
    for src in layers:
        for pos, key in enumerate(src["keys"]):
            if key.get("kind") != "layer" or key.get("layer") != target:
                continue
            how = HOW.get(key["note"]["mac"], key["note"]["mac"])
            where = "" if src["index"] == 0 else f" на {src['name']}"
            ways.append(f"{how} {position_name(pos, base_keys)}{where}")
    return ways


def combo_place(positions, base_keys):
    """«оба правых больших» для пары больших пальцев одной руки, иначе «R + T»."""
    if all(p in THUMB_NAMES for p in positions):
        sides = {"левых" if p < 32 else "правых" for p in positions}
        if len(sides) == 1:
            return f"оба {sides.pop()} больших"
    return " + ".join(position_name(p, base_keys) for p in positions)


def combo_ways(combos, target, base_keys):
    ways = []
    for combo in combos:
        key = combo["binding"]
        if key.get("kind") == "layer" and key.get("layer") == target and key["note"]["mac"] != "перейти":
            ways.append(f"{combo_place(combo['positions'], base_keys)} вместе (вкл/выкл)")
    return ways


def mode_hint(combos, flags, base_keys, names):
    mode_names = {0: "Мак", flags["win"]: "Windows", flags["lnx"]: "Linux"}
    modes, where = [], None
    for combo in combos:
        key = combo["binding"]
        if key.get("kind") != "layer" or key["note"]["mac"] != "перейти":
            continue
        if key["layer"] not in mode_names:
            continue
        pair = "+".join(position_name(p, base_keys) for p in combo["positions"])
        modes.append(f"{pair} {mode_names[key['layer']]}")
        if combo["layers"]:
            where = names.get(combo["layers"][0])
    if not modes:
        return None
    place = f" на {where}" if where else ""
    return {"layer": -1, "text": f"Режим ОС{place}: {', '.join(modes)}"}


def access_hints(layers, combos, flags):
    """Короткие строки «как попасть на слой» — по самим привязкам и комбо."""
    base_keys = layers[0]["keys"]
    names = {layer["index"]: layer["name"] for layer in layers}
    flag_layers = {flags["win"], flags["lnx"]}
    hints = []
    for layer in layers:
        idx = layer["index"]
        if idx == 0 or idx in flag_layers:
            continue
        ways = key_ways(layers, idx, base_keys) + combo_ways(combos, idx, base_keys)
        if ways:
            hints.append({"layer": idx, "text": f"{layer['name']} — {'; '.join(ways)}"})
    mode = mode_hint(combos, flags, base_keys, names)
    if mode:
        hints.append(mode)
    return hints


def cell_text(key, mode):
    if key["t"] != "key":
        return "·" if key["t"] == "trans" else "∅"
    text = key["label"][mode]
    if key.get("hold"):
        text += "/" + key["hold"][mode]
    return ("!" + text) if key["danger"][mode] else text


def print_table(data, mode):
    for layer in data["layers"]:
        cells = [cell_text(key, mode) for key in layer["keys"]]
        print(f"== {layer['index']} {layer['name']}")
        for row in (cells[0:10], cells[10:20], cells[20:30], cells[30:34]):
            print("   " + " | ".join(row))
    for hint in data["hints"]:
        print("* " + hint["text"])


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    data = generate(sys.argv[1])
    target = sys.argv[2] if len(sys.argv) > 2 else "mac"
    if target in MODES:
        print_table(data, target)
        return
    with open(target, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=1)


if __name__ == "__main__":
    main()
