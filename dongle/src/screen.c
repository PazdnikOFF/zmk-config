/*
 * Экран донгла: 200x200, монохром, e-paper.
 *
 * Перерисовка идёт не по таймеру, а по инвалидации LVGL: display_tick_cb в
 * ZMK — это просто lv_task_handler(), flush в драйвер уходит только когда
 * что-то реально изменилось. Поэтому всё, что меняется, меняем только при
 * фактическом изменении значения — и текст, и высоту заливки в иконках.
 *
 * Весь текст намеренно ASCII: встроенные шрифты Montserrat кириллицы не
 * содержат, а тащить свой шрифт ради двух подписей смысла нет.
 */

#include <stdio.h>
#include <string.h>

#include <zephyr/kernel.h>
#include <zephyr/logging/log.h>

#include <lvgl.h>

#include <zmk/activity.h>
#include <zmk/battery.h>
#include <zmk/display.h>
#include <zmk/display/status_screen.h>
#include <zmk/event_manager.h>
#include <zmk/events/battery_state_changed.h>
#include <zmk/events/layer_state_changed.h>
/* zmk_peripheral_battery_state_changed объявлен там же, где обычный
   battery_state_changed — отдельного заголовка у него нет. */
#include <zmk/events/activity_state_changed.h>
#include <zmk/events/ble_active_profile_changed.h>
#include <zmk/events/endpoint_changed.h>
#include <zmk/events/position_state_changed.h>
#include <zmk/ble.h>
#include <zmk/endpoints.h>
#include <zmk/keymap.h>
#include <zmk/split/central.h>

#include "dongle_ui.h"

LOG_MODULE_DECLARE(zmk, CONFIG_ZMK_LOG_LEVEL);

#define UNKNOWN_BATT (-1)

/* Геометрия ряда иконок. Экран 200x200, три силуэта в ряд. */
#define ICON_Y 2
#define ICON_W 48
#define ICON_H 34
#define ICON_BORDER 2
#define THUMB_W 14
#define THUMB_H 8
#define LEFT_X 8
#define DONGLE_X 76
#define RIGHT_X 144
#define PCT_Y 46

/* Имена слоёв в порядке cradio.keymap. Держать синхронно с раскладкой. */
static const char *const layer_names[] = {"BASE", "SYM", "SYM2", "FN", "FN2"};

/* Силуэт устройства, залитый снизу пропорционально заряду. */
struct batt_icon {
    lv_obj_t *fill;
    lv_obj_t *label;
    int16_t shown_pct; /* что уже нарисовано, чтобы не звать LVGL зря */
};

static struct batt_icon icon_left;
static struct batt_icon icon_dongle;
static struct batt_icon icon_right;

static lv_obj_t *lbl_layer;
static lv_obj_t *lbl_bt;
static lv_obj_t *lbl_layout;
static lv_obj_t *lbl_cpu_mem;
static lv_obj_t *lbl_disk_batt;

K_MUTEX_DEFINE(state_mutex);

static struct dongle_host_state host_state;

struct dongle_kbd_state {
    uint8_t self_batt;
    int16_t slot_batt[ZMK_SPLIT_CENTRAL_PERIPHERAL_COUNT];
    /*
     * Какой слот периферии оказался левой половиной. Слоты раздаются по
     * порядку подключения, поэтому определяем по первой же нажатой клавише:
     * левая половина владеет позициями 0-4, 10-14, 20-24, 30, 31.
     */
    int8_t left_slot;
};

static struct dongle_kbd_state kbd_state;

/* Моменты последних отрисовок — для ограничителей частоты, см. schedule(). */
static int64_t last_batt_render_ms;
static int64_t last_mac_render_ms;
static int64_t last_bt_render_ms;

/*
 * Простой: панель не трогаем совсем. Глубокий сон при этом намеренно выключен
 * (ZMK_SLEEP=n) — он гасит радио, а разбудить донгл нажатием на половинке
 * можно только по радио, своих кнопок у него нет. Так что экономим на экране и
 * на простое процессора, а связь держим живой ради мгновенной реакции.
 */
static bool ui_suspended;

/* --- отрисовка ------------------------------------------------------------ */

static void request_mac_render(void);

/* Обновляем подпись только если текст изменился — иначе лишний refresh. */
static void set_text_if_changed(lv_obj_t *label, const char *text) {
    if (!label) {
        return;
    }

    const char *current = lv_label_get_text(label);
    if (current && strcmp(current, text) == 0) {
        return;
    }

    lv_label_set_text(label, text);
}

static void icon_set_percent(struct batt_icon *icon, int16_t pct) {
    if (!icon->fill || icon->shown_pct == pct) {
        return;
    }

    icon->shown_pct = pct;

    const int16_t inner_h = ICON_H - 2 * ICON_BORDER;
    const int16_t filled = (pct <= 0) ? 0 : (int16_t)((int32_t)inner_h * MIN(pct, 100) / 100);

    lv_obj_set_height(icon->fill, filled);

    char buf[8];
    if (pct < 0) {
        snprintf(buf, sizeof(buf), "--");
    } else {
        snprintf(buf, sizeof(buf), "%d%%", pct);
    }
    set_text_if_changed(icon->label, buf);
}

static void render_batt_cb(struct k_work *work) {
    struct dongle_kbd_state kbd;

    k_mutex_lock(&state_mutex, K_FOREVER);
    kbd = kbd_state;
    k_mutex_unlock(&state_mutex);

    last_batt_render_ms = k_uptime_get();

    int16_t left = UNKNOWN_BATT, right = UNKNOWN_BATT;
    if (kbd.left_slot >= 0) {
        left = kbd.slot_batt[kbd.left_slot];
        right = kbd.slot_batt[kbd.left_slot == 0 ? 1 : 0];
    }

    icon_set_percent(&icon_left, left);
    icon_set_percent(&icon_right, right);
    icon_set_percent(&icon_dongle,
                     kbd.self_batt > 0 ? (int16_t)kbd.self_batt : (int16_t)UNKNOWN_BATT);

    /* Раз панель всё равно проснулась — подтянем и метрики мака. */
    request_mac_render();
}

static void render_mac_cb(struct k_work *work) {
    struct dongle_host_state host;

    k_mutex_lock(&state_mutex, K_FOREVER);
    host = host_state;
    k_mutex_unlock(&state_mutex);

    last_mac_render_ms = k_uptime_get();

    char buf[48];

    set_text_if_changed(lbl_layout, (host.valid && host.layout[0]) ? host.layout : "--");

    if (host.valid) {
        snprintf(buf, sizeof(buf), "CPU %u%%   MEM %u%%", host.cpu_pct, host.mem_pct);
    } else {
        snprintf(buf, sizeof(buf), "CPU --   MEM --");
    }
    set_text_if_changed(lbl_cpu_mem, buf);

    if (host.valid) {
        snprintf(buf, sizeof(buf), "%uG free   BAT %u%%%s", host.disk_free_gb, host.batt_pct,
                 host.charging ? "+" : "");
    } else {
        snprintf(buf, sizeof(buf), "--G free   BAT --");
    }
    set_text_if_changed(lbl_disk_batt, buf);
}

/*
 * Текущий выход: USB либо номер BLE-профиля. Профиль показывается с единицы,
 * как в штатном виджете ZMK, чтобы не расходиться с привычной нумерацией
 * (&bt BT_SEL 0 — это профиль 1 на экране).
 *
 * Состояний у BLE три: привязан и подключён, привязан но не подключён,
 * свободен и ждёт сопряжения.
 */
static void render_bt_cb(struct k_work *work) {
    last_bt_render_ms = k_uptime_get();

    const struct zmk_endpoint_instance endpoint = zmk_endpoints_selected();
    char buf[16];

    switch (endpoint.transport) {
    case ZMK_TRANSPORT_USB:
        snprintf(buf, sizeof(buf), "USB");
        break;
    case ZMK_TRANSPORT_BLE: {
        const int profile = endpoint.ble.profile_index + 1;

        if (zmk_ble_active_profile_is_open()) {
            snprintf(buf, sizeof(buf), "BT%d ?", profile);
        } else if (zmk_ble_active_profile_is_connected()) {
            snprintf(buf, sizeof(buf), "BT%d", profile);
        } else {
            snprintf(buf, sizeof(buf), "BT%d x", profile);
        }
        break;
    }
    default:
        snprintf(buf, sizeof(buf), "--");
        break;
    }

    set_text_if_changed(lbl_bt, buf);
}

/*
 * Слой рисуется отдельной работой и в своём темпе.
 *
 * Значение читается в момент отрисовки, а не в момент события. Это намеренно:
 * моментальные слои (&mo) живут доли секунды, панель за ними всё равно не
 * успевает, и к моменту отрисовки слой обычно снова BASE — текст не меняется,
 * обновления не происходит. То есть на панель попадают ровно те слои, на
 * которых реально задержались, а мельтешение при быстрых нажатиях не стоит
 * ничего.
 */
static void render_layer_cb(struct k_work *work) {
    const uint8_t layer = zmk_keymap_highest_layer_active();
    char buf[16];

    if (layer < ARRAY_SIZE(layer_names)) {
        snprintf(buf, sizeof(buf), "%s", layer_names[layer]);
    } else {
        snprintf(buf, sizeof(buf), "L%u", layer);
    }

    set_text_if_changed(lbl_layer, buf);

    /* Раз панель всё равно проснулась — подтянем и метрики мака. */
    request_mac_render();
}

/*
 * Ограничитель частоты обновлений панели.
 *
 * Обновляется всегда только изменившийся участок: LVGL отдаёт во flush лишь
 * «грязный» прямоугольник, а ssd16xx при наличии профиля partial делает по
 * нему частичное обновление. Но даже частичное стоит сотен миллисекунд, а
 * поводов дёрнуться много — метрики раз в 5 секунд и каждое нажатие слоя.
 *
 * Поэтому два барьера: короткая склейка пачки изменений в одну отрисовку и
 * жёсткий минимальный промежуток между обновлениями. k_work_schedule не
 * сбрасывает уже назначенный таймер, поэтому непрерывный поток изменений не
 * может откладывать отрисовку бесконечно — первый запросивший назначает срок,
 * остальные поглощаются.
 */
/*
 * Три блока экрана обновляются РАЗДЕЛЬНО, и это принципиально.
 *
 * Драйвер ssd16xx требует записи во всю ширину, поэтому Zephyr расширяет любую
 * грязную область до полной ширины экрана (lvgl_rounder_cb_mono,
 * SCREEN_INFO_X_ALIGNMENT_WIDTH) — обновляется горизонтальная полоса. Если
 * трогать батареи наверху и метрики внизу в одном проходе, LVGL склеит две
 * далёкие полосы в одну область почти во весь экран. Поэтому у каждого блока
 * своя работа и свой темп: полосы получаются узкие и независимые.
 */
#define BLOCK_COALESCE_MS 500

/* Заряд — раз в 5 секунд. */
#define BATT_MIN_GAP_MS 5000

/*
 * Ресурсы мака сами по себе поводом для обновления НЕ являются: приходящие
 * метрики только копятся в состоянии. На панель они попадают попутно — когда
 * экран и так обновляется из-за слоя или заряда.
 *
 * Попутная отрисовка сдвинута на полторы секунды намеренно. Нарисовать её в
 * том же цикле нельзя: блоки лежат в разных концах экрана, а ssd16xx пишет
 * только во всю ширину, поэтому LVGL склеил бы две далёкие полосы в одну
 * почти во весь экран. Полторы секунды заведомо больше одного обновления
 * (~650 мс), так что полосы получаются раздельными.
 */
#define MAC_MIN_GAP_MS 15000
#define MAC_PIGGYBACK_DELAY_MS 1500

/* Выбор выхода — реакция на нажатие, тут нужна расторопность. */
#define BT_MIN_GAP_MS 2000
#define BT_COALESCE_MS 300

/*
 * Слой показывается, только если продержался 5 секунд. Здесь именно
 * k_work_reschedule, который СБРАСЫВАЕТ таймер: каждое переключение отодвигает
 * отрисовку, поэтому мелькание при переборе слоёв не доходит до панели, а
 * рисуется тот слой, на котором остановились.
 */
#define LAYER_SETTLE_MS 5000

K_WORK_DELAYABLE_DEFINE(layer_work, render_layer_cb);
K_WORK_DELAYABLE_DEFINE(batt_work, render_batt_cb);
K_WORK_DELAYABLE_DEFINE(mac_work, render_mac_cb);
K_WORK_DELAYABLE_DEFINE(bt_work, render_bt_cb);

static void schedule(struct k_work_delayable *work, int64_t last_ms, int32_t min_gap,
                     int32_t coalesce) {
    if (!zmk_display_is_initialized() || ui_suspended) {
        return;
    }

    const int64_t since = k_uptime_get() - last_ms;
    const int32_t delay = (since >= min_gap) ? coalesce : (int32_t)(min_gap - since);

    k_work_schedule_for_queue(zmk_display_work_q(), work, K_MSEC(delay));
}

static void request_layer_render(void) {
    if (zmk_display_is_initialized() && !ui_suspended) {
        k_work_reschedule_for_queue(zmk_display_work_q(), &layer_work, K_MSEC(LAYER_SETTLE_MS));
    }
}

static void request_batt_render(void) {
    schedule(&batt_work, last_batt_render_ms, BATT_MIN_GAP_MS, BLOCK_COALESCE_MS);
}

static void request_mac_render(void) {
    schedule(&mac_work, last_mac_render_ms, MAC_MIN_GAP_MS, MAC_PIGGYBACK_DELAY_MS);
}

static void request_bt_render(void) {
    schedule(&bt_work, last_bt_render_ms, BT_MIN_GAP_MS, BT_COALESCE_MS);
}

/*
 * Уход в простой и возврат из него.
 *
 * При засыпании гасим всё запланированное — иначе отложенная отрисовка
 * сработает уже в простое. При пробуждении обнуляем отметки времени, чтобы
 * ограничители не задержали первую отрисовку, но саму её сдвигаем на секунду:
 * пусть первые нажатия уйдут хосту раньше, чем панель займётся своим долгим
 * обновлением.
 */
#define WAKE_RENDER_DELAY_MS 1000

static void ui_set_suspended(bool suspended) {
    if (ui_suspended == suspended) {
        return;
    }

    ui_suspended = suspended;

    if (suspended) {
        k_work_cancel_delayable(&layer_work);
        k_work_cancel_delayable(&batt_work);
        k_work_cancel_delayable(&mac_work);
        k_work_cancel_delayable(&bt_work);
        return;
    }

    last_batt_render_ms = 0;
    last_mac_render_ms = 0;
    last_bt_render_ms = 0;

    if (!zmk_display_is_initialized()) {
        return;
    }

    /* Разносим по времени: одновременная отрисовка блоков из разных концов
       экрана склеилась бы в одну полосу почти во весь экран. */
    struct k_work_q *q = zmk_display_work_q();
    k_work_schedule_for_queue(q, &bt_work, K_MSEC(WAKE_RENDER_DELAY_MS));
    k_work_schedule_for_queue(q, &layer_work, K_MSEC(WAKE_RENDER_DELAY_MS + 1500));
    k_work_schedule_for_queue(q, &batt_work, K_MSEC(WAKE_RENDER_DELAY_MS + 3000));
    k_work_schedule_for_queue(q, &mac_work, K_MSEC(WAKE_RENDER_DELAY_MS + 4500));
}

void dongle_ui_set_host(const struct dongle_host_state *st) {
    /* Только копим. Отрисовка случится попутно, см. MAC_PIGGYBACK_DELAY_MS. */
    k_mutex_lock(&state_mutex, K_FOREVER);
    host_state = *st;
    k_mutex_unlock(&state_mutex);
}

/* --- состояние наружу ------------------------------------------------------ */

void dongle_ui_fill_state(struct dongle_public_state *out) {
    struct dongle_kbd_state kbd;

    k_mutex_lock(&state_mutex, K_FOREVER);
    kbd = kbd_state;
    k_mutex_unlock(&state_mutex);

    int16_t left = UNKNOWN_BATT, right = UNKNOWN_BATT;
    if (kbd.left_slot >= 0) {
        left = kbd.slot_batt[kbd.left_slot];
        right = kbd.slot_batt[kbd.left_slot == 0 ? 1 : 0];
    }

    out->version = DONGLE_STATE_VERSION;
    out->layer = zmk_keymap_highest_layer_active();
    out->batt_left = (left < 0) ? DONGLE_BATT_UNKNOWN : (uint8_t)left;
    out->batt_right = (right < 0) ? DONGLE_BATT_UNKNOWN : (uint8_t)right;
    out->batt_dongle = kbd.self_batt > 0 ? kbd.self_batt : DONGLE_BATT_UNKNOWN;

    const struct zmk_endpoint_instance endpoint = zmk_endpoints_selected();

    if (endpoint.transport == ZMK_TRANSPORT_USB) {
        out->bt_profile = 0;
        out->bt_flags = DONGLE_BT_USB;
        return;
    }

    out->bt_profile = endpoint.ble.profile_index + 1;
    out->bt_flags = 0;
    if (zmk_ble_active_profile_is_open()) {
        out->bt_flags |= DONGLE_BT_OPEN;
    }
    if (zmk_ble_active_profile_is_connected()) {
        out->bt_flags |= DONGLE_BT_CONNECTED;
    }
}

/* --- слушатели событий ZMK ------------------------------------------------ */

static bool position_is_left(uint32_t position) {
    /* Большие пальцы: 30, 31 — левые; 32, 33 — правые. */
    if (position >= 30) {
        return position < 32;
    }

    /* Остальные ряды идут пятёрками: левая половина, потом правая. */
    return (position % 10) < 5;
}

static int dongle_ui_event_listener(const zmk_event_t *eh) {
    bool dirty = false;

    k_mutex_lock(&state_mutex, K_FOREVER);

    if (as_zmk_layer_state_changed(eh) != NULL) {
        /* Слой живёт своим темпом, к общему обновлению отношения не имеет. */
        k_mutex_unlock(&state_mutex);
        request_layer_render();
        return ZMK_EV_EVENT_BUBBLE;
    } else if (as_zmk_activity_state_changed(eh) != NULL) {
        k_mutex_unlock(&state_mutex);
        ui_set_suspended(zmk_activity_get_state() != ZMK_ACTIVITY_ACTIVE);
        return ZMK_EV_EVENT_BUBBLE;
    } else if (as_zmk_ble_active_profile_changed(eh) != NULL ||
               as_zmk_endpoint_changed(eh) != NULL) {
        k_mutex_unlock(&state_mutex);
        request_bt_render();
        return ZMK_EV_EVENT_BUBBLE;
    } else if (as_zmk_battery_state_changed(eh) != NULL) {
        uint8_t soc = zmk_battery_state_of_charge();
        if (soc != kbd_state.self_batt) {
            kbd_state.self_batt = soc;
            dirty = true;
        }
    } else {
        const struct zmk_peripheral_battery_state_changed *pb =
            as_zmk_peripheral_battery_state_changed(eh);
        const struct zmk_position_state_changed *pos = as_zmk_position_state_changed(eh);

        if (pb != NULL && pb->source < ARRAY_SIZE(kbd_state.slot_batt)) {
            if (kbd_state.slot_batt[pb->source] != pb->state_of_charge) {
                kbd_state.slot_batt[pb->source] = pb->state_of_charge;
                dirty = true;
            }
        } else if (pos != NULL && kbd_state.left_slot < 0 &&
                   pos->source < ARRAY_SIZE(kbd_state.slot_batt)) {
            /* Первое же нажатие говорит, какой слот — левая половина. */
            kbd_state.left_slot =
                position_is_left(pos->position) ? pos->source : (pos->source == 0 ? 1 : 0);
            dirty = true;
        }
    }

    k_mutex_unlock(&state_mutex);

    if (dirty) {
        request_batt_render();
    }

    return ZMK_EV_EVENT_BUBBLE;
}

ZMK_LISTENER(dongle_ui, dongle_ui_event_listener);
ZMK_SUBSCRIPTION(dongle_ui, zmk_layer_state_changed);
ZMK_SUBSCRIPTION(dongle_ui, zmk_battery_state_changed);
ZMK_SUBSCRIPTION(dongle_ui, zmk_peripheral_battery_state_changed);
ZMK_SUBSCRIPTION(dongle_ui, zmk_position_state_changed);
ZMK_SUBSCRIPTION(dongle_ui, zmk_ble_active_profile_changed);
ZMK_SUBSCRIPTION(dongle_ui, zmk_endpoint_changed);
ZMK_SUBSCRIPTION(dongle_ui, zmk_activity_state_changed);

/* --- построение экрана ---------------------------------------------------- */

static lv_obj_t *make_label(lv_obj_t *parent, const lv_font_t *font, int16_t x, int16_t y,
                            const char *text) {
    lv_obj_t *label = lv_label_create(parent);

    lv_obj_set_style_text_font(label, font, LV_PART_MAIN);
    lv_label_set_text(label, text);
    lv_obj_set_pos(label, x, y);

    return label;
}

/* Пустой прямоугольник без темы: контур либо сплошная заливка. */
static lv_obj_t *make_box(lv_obj_t *parent, int16_t x, int16_t y, int16_t w, int16_t h,
                          bool outline) {
    lv_obj_t *box = lv_obj_create(parent);

    lv_obj_clear_flag(box, LV_OBJ_FLAG_SCROLLABLE);
    lv_obj_set_pos(box, x, y);
    lv_obj_set_size(box, w, h);
    lv_obj_set_style_pad_all(box, 0, LV_PART_MAIN);
    lv_obj_set_style_radius(box, 2, LV_PART_MAIN);

    if (outline) {
        lv_obj_set_style_bg_opa(box, LV_OPA_TRANSP, LV_PART_MAIN);
        lv_obj_set_style_border_width(box, ICON_BORDER, LV_PART_MAIN);
        lv_obj_set_style_border_color(box, lv_color_black(), LV_PART_MAIN);
    } else {
        lv_obj_set_style_bg_opa(box, LV_OPA_COVER, LV_PART_MAIN);
        lv_obj_set_style_bg_color(box, lv_color_black(), LV_PART_MAIN);
        lv_obj_set_style_border_width(box, 0, LV_PART_MAIN);
    }

    return box;
}

/*
 * Силуэт половины клавиатуры: блок клавиш плюс выступ под большие пальцы с
 * внутренней стороны. Заливается только основной блок — растить заливку через
 * две фигуры сразу незачем, читается и так.
 */
static void build_half_icon(lv_obj_t *screen, struct batt_icon *icon, int16_t x, bool is_left) {
    lv_obj_t *body = make_box(screen, x, ICON_Y, ICON_W, ICON_H, true);

    icon->fill = make_box(body, 0, 0, ICON_W - 2 * ICON_BORDER, 0, false);
    lv_obj_align(icon->fill, LV_ALIGN_BOTTOM_MID, 0, 0);

    const int16_t thumb_x = is_left ? (x + ICON_W - THUMB_W - 4) : (x + 4);
    make_box(screen, thumb_x, ICON_Y + ICON_H, THUMB_W, THUMB_H, true);

    icon->label = make_label(screen, &lv_font_montserrat_16, x, PCT_Y, "--");
    lv_obj_set_width(icon->label, ICON_W);
    lv_obj_set_style_text_align(icon->label, LV_TEXT_ALIGN_CENTER, LV_PART_MAIN);

    icon->shown_pct = 0; /* заставит первую отрисовку пройти */
}

/*
 * Силуэт донгла: корпус с экранчиком. Экранчик рисуется поверх заливки белым,
 * чтобы оставаться видимым при полном заряде.
 */
static void build_dongle_icon(lv_obj_t *screen, struct batt_icon *icon, int16_t x) {
    lv_obj_t *body = make_box(screen, x, ICON_Y, ICON_W, ICON_H, true);

    icon->fill = make_box(body, 0, 0, ICON_W - 2 * ICON_BORDER, 0, false);
    lv_obj_align(icon->fill, LV_ALIGN_BOTTOM_MID, 0, 0);

    lv_obj_t *panel = make_box(body, 0, 0, 26, 16, true);
    lv_obj_set_style_bg_opa(panel, LV_OPA_COVER, LV_PART_MAIN);
    lv_obj_set_style_bg_color(panel, lv_color_white(), LV_PART_MAIN);
    lv_obj_align(panel, LV_ALIGN_CENTER, 0, 0);

    icon->label = make_label(screen, &lv_font_montserrat_16, x, PCT_Y, "--");
    lv_obj_set_width(icon->label, ICON_W);
    lv_obj_set_style_text_align(icon->label, LV_TEXT_ALIGN_CENTER, LV_PART_MAIN);

    icon->shown_pct = 0;
}

static void make_rule(lv_obj_t *screen, int16_t y) {
    make_box(screen, 10, y, 180, 2, false);
}

#if IS_ENABLED(CONFIG_SWEEP_DONGLE_DEBUG_REFRESH)
/*
 * Сколько пикселей реально ушло в панель за один цикл обновления. Нужен, чтобы
 * отличить «LVGL отдаёт слишком большую область» от «панель мигает целиком на
 * своём частичном профиле» — снаружи это выглядит одинаково.
 */
static void refresh_monitor_cb(lv_disp_drv_t *drv, uint32_t time_ms, uint32_t px) {
    LOG_WRN("flush: %u px (%u%% экрана) за %u мс", px, (px * 100) / (200 * 200), time_ms);
}
#endif

lv_obj_t *zmk_display_status_screen(void) {
    lv_obj_t *screen = lv_obj_create(NULL);
    lv_obj_clear_flag(screen, LV_OBJ_FLAG_SCROLLABLE);
    lv_obj_set_style_pad_all(screen, 0, LV_PART_MAIN);

    kbd_state.left_slot = -1;
    for (size_t i = 0; i < ARRAY_SIZE(kbd_state.slot_batt); i++) {
        kbd_state.slot_batt[i] = UNKNOWN_BATT;
    }

    /* Ряд батарей: левая половина — донгл — правая половина. */
    build_half_icon(screen, &icon_left, LEFT_X, true);
    build_dongle_icon(screen, &icon_dongle, DONGLE_X);
    build_half_icon(screen, &icon_right, RIGHT_X, false);

    make_rule(screen, 70);

    /* Живёт в одной полосе со слоем — там слева пусто, а обновление полосы
       всё равно общее, так что отдельной строки это не стоит. */
    lbl_bt = make_label(screen, &lv_font_montserrat_16, 8, 86, "BT1");

    lbl_layer = make_label(screen, &lv_font_montserrat_28, 0, 76, "BASE");
    lv_obj_set_width(lbl_layer, 200);
    lv_obj_set_style_text_align(lbl_layer, LV_TEXT_ALIGN_CENTER, LV_PART_MAIN);

    make_rule(screen, 114);

    make_label(screen, &lv_font_montserrat_16, 8, 128, "MAC");
    lbl_layout = make_label(screen, &lv_font_montserrat_28, 100, 120, "--");
    lv_obj_set_width(lbl_layout, 92);
    lv_obj_set_style_text_align(lbl_layout, LV_TEXT_ALIGN_RIGHT, LV_PART_MAIN);

    lbl_cpu_mem = make_label(screen, &lv_font_montserrat_16, 8, 158, "CPU --   MEM --");
    lbl_disk_batt = make_label(screen, &lv_font_montserrat_16, 8, 178, "--G free   BAT --");

#if IS_ENABLED(CONFIG_SWEEP_DONGLE_DEBUG_REFRESH)
    lv_disp_t *disp = lv_disp_get_default();
    if (disp != NULL && disp->driver != NULL) {
        disp->driver->monitor_cb = refresh_monitor_cb;
    }
#endif

    return screen;
}
