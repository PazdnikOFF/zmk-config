/*
 * Короткий лог жизни соединений с ХОСТАМИ.
 *
 * Понадобился, когда в логе пошла строка ZMK «Failed to release peripheral
 * slot (-22)» по тридцать раз за сорок секунд. Сама по себе она безобидна:
 * app/src/split/bluetooth/central.c печатает её в обработчике разрыва для
 * любого соединения, у которого нет слота половинки, то есть для хостов. Но
 * её частота означает разрывы раз в секунду, а кто именно отваливается и по
 * какой причине — ZMK пишет только на уровне DBG, который на пути нажатия
 * стоит дорого.
 *
 * Здесь ровно то, чего не хватает: адрес, номер профиля, код причины и какой
 * профиль активен — уровнем WRN, без отладочного потока. Половинки не
 * трогаем, их ведёт link_stats.
 */

#include <zephyr/bluetooth/addr.h>
#include <zephyr/bluetooth/conn.h>
#include <zephyr/kernel.h>
#include <zephyr/logging/log.h>

#include <zephyr/init.h>

#include <zmk/ble.h>
#include <zmk/event_manager.h>
#include <zmk/events/ble_active_profile_changed.h>

LOG_MODULE_DECLARE(zmk, CONFIG_ZMK_LOG_LEVEL);

/* Хост — это соединение, в котором донгл выступает периферией. Центральные
   роли это половинки, у них свой учёт. */
static bool is_host(struct bt_conn *conn, struct bt_conn_info *info) {
    return bt_conn_get_info(conn, info) == 0 && info->type == BT_CONN_TYPE_LE &&
           info->role == BT_CONN_ROLE_PERIPHERAL;
}

static void describe(const char *what, struct bt_conn *conn, unsigned int code) {
    struct bt_conn_info info;

    if (!is_host(conn, &info)) {
        return;
    }

    char addr[BT_ADDR_LE_STR_LEN];
    bt_addr_le_to_str(bt_conn_get_dst(conn), addr, sizeof(addr));

    const int profile = zmk_ble_profile_index(bt_conn_get_dst(conn));

    LOG_WRN("host %s %s: профиль=%s%d активный=%d код=0x%02x", what, addr,
            profile < 0 ? "неизвестен " : "", profile + 1,
            zmk_ble_active_profile_index() + 1, code);
}

static void on_connected(struct bt_conn *conn, uint8_t err) {
    describe("подключился", conn, err);
}

static void on_disconnected(struct bt_conn *conn, uint8_t reason) {
    describe("отключился", conn, reason);
}

static void on_security_changed(struct bt_conn *conn, bt_security_t level,
                                enum bt_security_err err) {
    struct bt_conn_info info;

    if (!is_host(conn, &info)) {
        return;
    }

    if (err != BT_SECURITY_ERR_SUCCESS) {
        describe("шифрование не удалось", conn, err);
    } else {
        describe("зашифрован", conn, level);
    }
}

/*
 * Что донгл помнит о компьютерах.
 *
 * Самый частый вопрос при «не подключается»: лежит ли адрес хоста в профиле
 * вообще. ZMK печатает это только на уровне DBG при загрузке настроек
 * («Loaded ... address for profile N»), а DBG на пути нажатия стоит дорого.
 * Печатаем то же самое уровнем WRN, один раз после старта и при каждой смене
 * профиля.
 */
static void dump_profiles(struct k_work *work) {
    for (uint8_t i = 0; i < ZMK_BLE_PROFILE_COUNT; i++) {
        char addr[BT_ADDR_LE_STR_LEN];
        bt_addr_le_to_str(zmk_ble_profile_address(i), addr, sizeof(addr));

        LOG_WRN("профиль %d: %s%s%s%s", i + 1, zmk_ble_profile_is_open(i) ? "свободен" : addr,
                zmk_ble_profile_is_connected(i) ? ", подключён" : "",
                i == zmk_ble_active_profile_index() ? ", АКТИВНЫЙ" : "",
                zmk_ble_active_profile_is_open() && i == zmk_ble_active_profile_index()
                    ? " (ждёт сопряжения)"
                    : "");
    }
}

static K_WORK_DELAYABLE_DEFINE(dump_work, dump_profiles);

static int profiles_listener(const zmk_event_t *eh) {
    if (as_zmk_ble_active_profile_changed(eh) != NULL) {
        k_work_reschedule(&dump_work, K_MSEC(500));
    }

    return ZMK_EV_EVENT_BUBBLE;
}

ZMK_LISTENER(sweep_profiles_log, profiles_listener);
ZMK_SUBSCRIPTION(sweep_profiles_log, zmk_ble_active_profile_changed);

static int dump_init(void) {
    k_work_schedule(&dump_work, K_SECONDS(3));
    return 0;
}

SYS_INIT(dump_init, APPLICATION, CONFIG_APPLICATION_INIT_PRIORITY);

BT_CONN_CB_DEFINE(sweep_host_log) = {
    .connected = on_connected,
    .disconnected = on_disconnected,
    .security_changed = on_security_changed,
};
