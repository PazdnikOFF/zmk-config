/*
 * Замедление сплит-линков на простое.
 *
 * Самый крупный потребитель на донгле — радио, и обычные приёмы тут не
 * помогают. Slave latency, который ZMK ставит сплиту равным 30, позволяет
 * спать ПЕРИФЕРИИ: половинка, которой нечего сказать, пропускает события.
 * Центральный такого права не имеет — он обязан присутствовать на каждом
 * событии соединения по каждому линку. При интервале 15 мс и двух половинках
 * это около 133 пробуждений радио в секунду, круглосуточно.
 *
 * Зато сам интервал можно менять на ходу. На простое растягиваем его до
 * секунды, при первом же нажатии возвращаем обратно. Цена — первое нажатие
 * после простоя доедет с задержкой до секунды; последующие идут с обычной
 * скоростью, потому что параметры к тому моменту уже возвращены.
 *
 * Трогаем только те соединения, где мы центральный: линк к хосту — это наша
 * периферийная роль, там параметры диктует хост, а экономия обеспечена
 * отдельно через CONFIG_BT_PERIPHERAL_PREF_LATENCY.
 */

#include <zephyr/bluetooth/conn.h>
#include <zephyr/kernel.h>
#include <zephyr/logging/log.h>

#include <zmk/activity.h>
#include <zmk/event_manager.h>
#include <zmk/events/activity_state_changed.h>

LOG_MODULE_DECLARE(zmk, CONFIG_ZMK_LOG_LEVEL);

/* Активный режим повторяет то, что ZMK ставит сплиту при подключении. */
#define ACTIVE_INTERVAL CONFIG_ZMK_SPLIT_BLE_PREF_INT
#define ACTIVE_LATENCY CONFIG_ZMK_SPLIT_BLE_PREF_LATENCY
#define ACTIVE_TIMEOUT CONFIG_ZMK_SPLIT_BLE_PREF_TIMEOUT

/*
 * На простое latency обнуляется намеренно. Она задаётся в интервалах, и при
 * растянутом интервале половинка получила бы право молчать десятки секунд —
 * связь развалилась бы по таймауту.
 */
#define IDLE_INTERVAL CONFIG_SWEEP_DONGLE_IDLE_SPLIT_INT
#define IDLE_LATENCY 0
#define IDLE_TIMEOUT CONFIG_SWEEP_DONGLE_IDLE_SPLIT_TIMEOUT

/*
 * Требование спецификации: таймаут должен превышать
 * (1 + latency) * интервал * 2. Интервал в единицах по 1.25 мс, таймаут — по
 * 10 мс, отсюда деление на 8. Проверяем на этапе сборки, чтобы не обнаружить
 * разваливающийся сплит на живом устройстве.
 */
BUILD_ASSERT(IDLE_TIMEOUT * 8 > (1 + IDLE_LATENCY) * IDLE_INTERVAL * 2,
             "IDLE_TIMEOUT слишком мал для выбранного интервала простоя");
BUILD_ASSERT(ACTIVE_TIMEOUT * 8 > (1 + ACTIVE_LATENCY) * ACTIVE_INTERVAL * 2,
             "ACTIVE_TIMEOUT слишком мал для выбранного интервала");

static void apply_to_conn(struct bt_conn *conn, void *data) {
    const struct bt_le_conn_param *param = data;
    struct bt_conn_info info;

    if (bt_conn_get_info(conn, &info) != 0) {
        return;
    }

    /* Только линки к половинкам: там параметры назначаем мы. */
    if (info.role != BT_CONN_ROLE_CENTRAL) {
        return;
    }

    int err = bt_conn_le_param_update(conn, param);
    if (err != 0 && err != -EALREADY) {
        LOG_WRN("не удалось сменить параметры соединения: %d", err);
    }
}

static void set_split_params(bool idle) {
    struct bt_le_conn_param param = {
        .interval_min = idle ? IDLE_INTERVAL : ACTIVE_INTERVAL,
        .interval_max = idle ? IDLE_INTERVAL : ACTIVE_INTERVAL,
        .latency = idle ? IDLE_LATENCY : ACTIVE_LATENCY,
        .timeout = idle ? IDLE_TIMEOUT : ACTIVE_TIMEOUT,
    };

    LOG_INF("сплит: интервал %u (%u мс)", param.interval_min, param.interval_min * 5 / 4);

    bt_conn_foreach(BT_CONN_TYPE_LE, apply_to_conn, &param);
}

static int power_event_listener(const zmk_event_t *eh) {
    if (as_zmk_activity_state_changed(eh) == NULL) {
        return ZMK_EV_EVENT_BUBBLE;
    }

    set_split_params(zmk_activity_get_state() != ZMK_ACTIVITY_ACTIVE);

    return ZMK_EV_EVENT_BUBBLE;
}

ZMK_LISTENER(dongle_power, power_event_listener);
ZMK_SUBSCRIPTION(dongle_power, zmk_activity_state_changed);
