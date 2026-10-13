/*
 * Режим ОС по BLE-профилю.
 *
 * Раскладка у всех машин одна, отличаются только сочетания: ⌘C на Маке,
 * Ctrl+C в Windows, Super+C в Omarchy. В cradio.keymap это сделано пустыми
 * флаг-слоями WIN и LNX, которые через conditional_layers поднимают накладки
 * с отличающимися клавишами. Здесь — единственное, чего в самом ZMK нет:
 * связь «профиль хоста -> флаг-слой».
 *
 * Почему не клавишей. Клавиша есть (SYM_2 + T/G/B), но полагаться на неё
 * нельзя: состояние слоёв ZMK нигде не хранит, и после каждой перезагрузки
 * донгла — а он перезагружается от выдёргивания кабеля — режим молча
 * становился бы маковским на подключённой Windows.
 *
 * Почему не по имени или адресу хоста. Адрес известен, но профиль владелец
 * назначает сам и помнит именно номер: «второй профиль — рабочая Windows».
 * Привязка к номеру не ломается при пересопряжении машины.
 *
 * Ручной выбор не затирается переподключением: событие смены профиля ZMK
 * поднимает и при коннекте, и при дисконнекте ТЕКУЩЕГО профиля (ble.c,
 * connected/disconnected), поэтому режим применяется только когда номер
 * профиля реально сменился.
 */

#include <zephyr/init.h>
#include <zephyr/kernel.h>
#include <zephyr/logging/log.h>

#include <zmk/ble.h>
#include <zmk/event_manager.h>
#include <zmk/events/ble_active_profile_changed.h>
#include <zmk/keymap.h>

LOG_MODULE_DECLARE(zmk, CONFIG_ZMK_LOG_LEVEL);

/* Нет накладки — значит база, то есть Мак. */
#define OS_LAYER_NONE 0xff

static const uint8_t profile_layer[] = {
    [0] = OS_LAYER_NONE,
    [CONFIG_SWEEP_DONGLE_OS_PROFILE_WIN] = CONFIG_SWEEP_DONGLE_OS_LAYER_WIN,
    [CONFIG_SWEEP_DONGLE_OS_PROFILE_LNX] = CONFIG_SWEEP_DONGLE_OS_LAYER_LNX,
};

BUILD_ASSERT(CONFIG_SWEEP_DONGLE_OS_PROFILE_WIN != CONFIG_SWEEP_DONGLE_OS_PROFILE_LNX,
             "Windows и Linux не могут сидеть на одном профиле");
BUILD_ASSERT(CONFIG_SWEEP_DONGLE_OS_LAYER_WIN != CONFIG_SWEEP_DONGLE_OS_LAYER_LNX,
             "Флаг-слои Windows и Linux должны быть разными");

/* Какой профиль уже отработан. 0xff — ещё ни одного. */
static uint8_t applied_profile = 0xff;

static void set_layer(uint8_t index, bool on) {
    const zmk_keymap_layer_id_t id = zmk_keymap_layer_index_to_id(index);

    if (id == ZMK_KEYMAP_LAYER_ID_INVAL) {
        LOG_WRN("os: слоя %u нет в раскладке", index);
        return;
    }

    if (on) {
        zmk_keymap_layer_activate(id);
    } else {
        zmk_keymap_layer_deactivate(id);
    }
}

static void apply_profile(uint8_t profile) {
    const uint8_t want =
        profile < ARRAY_SIZE(profile_layer) ? profile_layer[profile] : OS_LAYER_NONE;

    /* Гасим чужой флаг раньше, чем поднимаем свой: два разом активных флага
       подняли бы обе накладки, и выиграла бы та, что выше номером. */
    if (want != CONFIG_SWEEP_DONGLE_OS_LAYER_WIN) {
        set_layer(CONFIG_SWEEP_DONGLE_OS_LAYER_WIN, false);
    }
    if (want != CONFIG_SWEEP_DONGLE_OS_LAYER_LNX) {
        set_layer(CONFIG_SWEEP_DONGLE_OS_LAYER_LNX, false);
    }
    if (want != OS_LAYER_NONE) {
        set_layer(want, true);
    }

    applied_profile = profile;
    LOG_INF("os: профиль %u -> слой %u", profile + 1, want);
}

/*
 * Первичная установка отложена: профили лежат в настройках, которые ZMK
 * подхватывает в своём SYS_INIT, и порядок инициализации между модулями
 * гарантировать нечем. К моменту срабатывания активный профиль уже прочитан.
 */
static void startup_work_cb(struct k_work *work) {
    const int profile = zmk_ble_active_profile_index();

    if (profile < 0) {
        LOG_WRN("os: активный профиль неизвестен (%d)", profile);
        return;
    }

    apply_profile((uint8_t)profile);
}

static K_WORK_DELAYABLE_DEFINE(startup_work, startup_work_cb);

static int os_profile_listener(const zmk_event_t *eh) {
    const struct zmk_ble_active_profile_changed *ev = as_zmk_ble_active_profile_changed(eh);

    if (ev == NULL) {
        return ZMK_EV_EVENT_BUBBLE;
    }

    if (ev->index == applied_profile) {
        /* Тот же профиль: это коннект или дисконнект, а не смена машины.
           Ручной выбор режима, если он был, оставляем в покое. */
        return ZMK_EV_EVENT_BUBBLE;
    }

    apply_profile(ev->index);

    return ZMK_EV_EVENT_BUBBLE;
}

ZMK_LISTENER(sweep_os_profile, os_profile_listener);
ZMK_SUBSCRIPTION(sweep_os_profile, zmk_ble_active_profile_changed);

static int os_profile_init(void) {
    k_work_schedule(&startup_work, K_MSEC(CONFIG_SWEEP_DONGLE_OS_STARTUP_DELAY_MS));
    return 0;
}

SYS_INIT(os_profile_init, APPLICATION, CONFIG_APPLICATION_INIT_PRIORITY);
