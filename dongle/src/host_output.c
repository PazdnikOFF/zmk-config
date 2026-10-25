/*
 * Выбор выхода при смене BLE-профиля.
 *
 * Донгл почти всегда воткнут в USB — к маку, к блоку питания, к хабу. Для
 * ZMK это полноценный хост: app/src/endpoints.c, get_selected_transport()
 * отдаёт предпочтение (по умолчанию USB) всякий раз, когда готовы ОБА
 * выхода. Поэтому при донгле в маке нажатия уходили в мак и тогда, когда
 * владелец переключился на BT2 (Windows) или BT3 (Linux): профиль менялся,
 * выход — нет. Штатное лекарство — клавиша &out OUT_BLE, но раскладку мы не
 * трогаем.
 *
 * Здесь: смена номера профиля трактуется как «хочу печатать по BT».
 *
 * Откатить выход на USB просто — выдернуть и воткнуть кабель? Нет,
 * предпочтение сохраняется в настройках (endpoints/preferred). Но терять
 * нечего: если активный профиль НЕ подключён, ZMK сам уходит на USB
 * (get_selected_transport: «Only USB is ready»). То есть печатать в мак по
 * проводу можно так же, как раньше, — достаточно выбрать профиль, которым
 * никто не занят, или остаться на том, где хост отвалился.
 *
 * Коннект и дисконнект текущего профиля поднимают то же событие, что и
 * смена машины, поэтому сравниваем номер: иначе каждое переподключение
 * хоста навязывало бы BT.
 */

#include <zephyr/init.h>
#include <zephyr/kernel.h>
#include <zephyr/logging/log.h>

#include <zmk/ble.h>
#include <zmk/endpoints.h>
#include <zmk/event_manager.h>
#include <zmk/events/ble_active_profile_changed.h>

LOG_MODULE_DECLARE(zmk, CONFIG_ZMK_LOG_LEVEL);

/* 0xff — ещё ни одного события; первый профиль берём из настроек. */
static uint8_t known_profile = 0xff;

static void startup_work_cb(struct k_work *work) {
    const int profile = zmk_ble_active_profile_index();

    if (profile >= 0) {
        known_profile = (uint8_t)profile;
    }
}

static K_WORK_DELAYABLE_DEFINE(startup_work, startup_work_cb);

static int host_output_listener(const zmk_event_t *eh) {
    const struct zmk_ble_active_profile_changed *ev = as_zmk_ble_active_profile_changed(eh);

    if (ev == NULL) {
        return ZMK_EV_EVENT_BUBBLE;
    }

    if (ev->index == known_profile) {
        /* Тот же профиль: коннект или дисконнект, а не выбор машины. */
        return ZMK_EV_EVENT_BUBBLE;
    }

    known_profile = ev->index;

    LOG_INF("out: профиль %u -> выход BT", ev->index + 1);
    zmk_endpoints_select_transport(ZMK_TRANSPORT_BLE);

    return ZMK_EV_EVENT_BUBBLE;
}

ZMK_LISTENER(sweep_host_output, host_output_listener);
ZMK_SUBSCRIPTION(sweep_host_output, zmk_ble_active_profile_changed);

static int host_output_init(void) {
    k_work_schedule(&startup_work, K_MSEC(CONFIG_SWEEP_DONGLE_BLE_ON_SWITCH_DELAY_MS));
    return 0;
}

SYS_INIT(host_output_init, APPLICATION, CONFIG_APPLICATION_INIT_PRIORITY);
