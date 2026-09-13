/*
 * Скорость печати для экрана донгла.
 *
 * Считается только печать: серия из MIN_PRESSES и больше нажатий, где каждое
 * следующее пришло меньше чем через GAP_MS после предыдущего. Паузы, простой и
 * одиночные нажатия в среднее не входят вовсе — ни временем, ни символами.
 *
 * Символы — нажатия, которые печатают: буквы, цифры, знаки, пробел и Enter.
 * Backspace, стрелки, Esc, F-клавиши и сочетания с Cmd/Ctrl/Alt символами не
 * считаются, но серию не рвут: исправлять опечатки — тоже печать.
 *
 * Среднее берётся по последним WINDOW_MS именно печати, а не настенного
 * времени: как только набранное время переваливает за окно, старые серии
 * вытесняются пропорционально. Число на экране — текущий темп, а не весь день.
 *
 * Цена: несколько сложений на нажатие под спинлоком, без таймеров и потоков.
 * Когда перерисовать панель, решает screen.c — не чаще раза в минуту.
 */

#include <zephyr/kernel.h>

#include <dt-bindings/zmk/hid_usage_pages.h>
#include <dt-bindings/zmk/modifiers.h>
#include <zmk/event_manager.h>
#include <zmk/events/keycode_state_changed.h>
#include <zmk/hid.h>

#include "dongle_ui.h"

#define GAP_MS 1000
#define MIN_PRESSES 10
#define WINDOW_MS (5 * 60 * 1000)

/*
 * Модификаторы, превращающие букву в сочетание. Shift — нет: заглавная буква
 * тоже символ. Удерживаемые модификаторы берутся из состояния HID: в событии
 * самой буквы при зажатом Cmd поле модификаторов пустое.
 */
#define SHORTCUT_MODS (MOD_LCTL | MOD_LALT | MOD_LGUI | MOD_RCTL | MOD_RALT | MOD_RGUI)

static struct k_spinlock lock;

/* Текущая серия. */
static int64_t last_ms;
static uint32_t cur_presses;
static uint32_t cur_chars;
static int64_t cur_span_ms;

/* Засчитанные серии в пределах окна. */
static uint32_t acc_chars;
static int64_t acc_span_ms;

static bool is_char(const struct zmk_keycode_state_changed *ev) {
    if ((ev->implicit_modifiers | zmk_hid_get_explicit_mods()) & SHORTCUT_MODS) {
        return false;
    }

    /* 0x04-0x27 буквы и цифры, 0x28 Enter, 0x2C пробел, 0x2D-0x38 знаки. */
    const uint32_t k = ev->keycode;
    return (k >= 0x04 && k <= 0x28) || (k >= 0x2C && k <= 0x38);
}

/* Засчитать законченную серию, вытеснив из окна соответствующую долю старых. */
static void commit_locked(void) {
    int64_t span = cur_span_ms;
    uint32_t chars = cur_chars;

    if (cur_presses < MIN_PRESSES || span <= 0) {
        return;
    }

    if (span > WINDOW_MS) {
        chars = (uint32_t)((int64_t)chars * WINDOW_MS / span);
        span = WINDOW_MS;
    }

    const int64_t keep = WINDOW_MS - span;
    if (acc_span_ms > keep) {
        acc_chars = (uint32_t)((int64_t)acc_chars * keep / acc_span_ms);
        acc_span_ms = keep;
    }

    acc_chars += chars;
    acc_span_ms += span;
}

int typing_speed_cpm(void) {
    k_spinlock_key_t key = k_spin_lock(&lock);

    int64_t span = acc_span_ms;
    uint32_t chars = acc_chars;

    /* Идущая серия видна сразу, как только набрала порог. */
    if (cur_presses >= MIN_PRESSES) {
        span += cur_span_ms;
        chars += cur_chars;
    }

    k_spin_unlock(&lock, key);

    if (span <= 0) {
        return -1;
    }

    return (int)((int64_t)chars * 60000 / span);
}

static int typing_speed_listener(const zmk_event_t *eh) {
    const struct zmk_keycode_state_changed *ev = as_zmk_keycode_state_changed(eh);

    /* Громкость и прочие клавиши страницы Consumer к печати не относятся. */
    if (ev == NULL || !ev->state || ev->usage_page != HID_USAGE_KEY) {
        return ZMK_EV_EVENT_BUBBLE;
    }

    const bool ch = is_char(ev);
    bool counted;

    k_spinlock_key_t key = k_spin_lock(&lock);

    const int64_t now = ev->timestamp;
    /* Hold-tap отдаёт придержанные нажатия с их исходными метками, так что
       время может идти назад; такой промежуток считаем нулевым. */
    const int64_t gap = (now > last_ms) ? now - last_ms : 0;

    if (cur_presses == 0 || gap >= GAP_MS) {
        commit_locked();
        cur_presses = 1;
        cur_chars = 0;
        cur_span_ms = 0;
    } else {
        cur_presses++;
        cur_span_ms += gap;
        if (ch) {
            cur_chars++;
        }
    }

    if (now > last_ms) {
        last_ms = now;
    }

    counted = cur_presses >= MIN_PRESSES || acc_span_ms > 0;

    k_spin_unlock(&lock, key);

    /* Сама просьба дешёвая: при уже назначенной отрисовке она ничего не
       делает, а частоту панели ограничивает screen.c. */
    if (counted) {
        dongle_ui_request_speed_render();
    }

    return ZMK_EV_EVENT_BUBBLE;
}

ZMK_LISTENER(typing_speed, typing_speed_listener);
ZMK_SUBSCRIPTION(typing_speed, zmk_keycode_state_changed);
