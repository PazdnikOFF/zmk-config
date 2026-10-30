/*
 * Хост с ключами, но без профиля.
 *
 * ZMK записывает адрес в профиль только по итогам сопряжения (ble.c,
 * auth_pairing_complete). Хост, у которого бонд уже есть, сразу шифрует связь,
 * сопряжения нет, и профиль остаётся открытым: на хосте «подключено», а нажатия
 * уходят в никуда, потому что активный профиль считается неподключённым.
 *
 * Если активный профиль свободен, записываем такой хост в него. Бонды не трогаем.
 *
 * Пауза нужна из-за нового сопряжения: security_changed приходит раньше
 * pairing_complete, а профиль, занятый в этот промежуток, ZMK счёл бы чужим и снял
 * бы свежий бонд. За паузу сопряжение заканчивается и профиль перестаёт быть
 * открытым. Половинки отсекаются ролью: к ним донгл подключается сам.
 */

#include <zephyr/bluetooth/addr.h>
#include <zephyr/bluetooth/bluetooth.h>
#include <zephyr/bluetooth/conn.h>
#include <zephyr/init.h>
#include <zephyr/kernel.h>

#include <zmk/ble.h>
#include <zmk/event_manager.h>
#include <zmk/events/ble_active_profile_changed.h>

/* Объявлены в ble.c без заголовка. */
extern void set_profile_address(uint8_t index, const bt_addr_le_t *addr);
extern int update_advertising(void);

#define ADOPT_DELAY K_SECONDS(2)

struct orphan {
    bool found;
    bt_addr_le_t addr;
};

static void find_orphan(struct bt_conn *conn, void *user_data) {
    struct orphan *orphan = user_data;
    struct bt_conn_info info;

    if (orphan->found || bt_conn_get_info(conn, &info) != 0 ||
        info.role != BT_CONN_ROLE_PERIPHERAL || info.state != BT_CONN_STATE_CONNECTED ||
        bt_conn_get_security(conn) < BT_SECURITY_L2) {
        return;
    }

    const bt_addr_le_t *dst = bt_conn_get_dst(conn);

    if (bt_addr_le_is_rpa(dst) || zmk_ble_profile_index(dst) >= 0 ||
        !bt_le_bond_exists(BT_ID_DEFAULT, dst)) {
        return;
    }

    bt_addr_le_copy(&orphan->addr, dst);
    orphan->found = true;
}

static void adopt_work_cb(struct k_work *work) {
    struct orphan orphan = {0};

    if (!zmk_ble_active_profile_is_open()) {
        return;
    }

    bt_conn_foreach(BT_CONN_TYPE_LE, find_orphan, &orphan);

    if (orphan.found) {
        set_profile_address(zmk_ble_active_profile_index(), &orphan.addr);
        update_advertising();
    }
}

static K_WORK_DELAYABLE_DEFINE(adopt_work, adopt_work_cb);

static void security_changed(struct bt_conn *conn, bt_security_t level, enum bt_security_err err) {
    if (err == BT_SECURITY_ERR_SUCCESS) {
        k_work_reschedule(&adopt_work, ADOPT_DELAY);
    }
}

BT_CONN_CB_DEFINE(host_profile_cb) = {
    .security_changed = security_changed,
};

static int host_profile_listener(const zmk_event_t *eh) {
    if (as_zmk_ble_active_profile_changed(eh) != NULL) {
        k_work_reschedule(&adopt_work, ADOPT_DELAY);
    }

    return ZMK_EV_EVENT_BUBBLE;
}

ZMK_LISTENER(sweep_host_profile, host_profile_listener);
ZMK_SUBSCRIPTION(sweep_host_profile, zmk_ble_active_profile_changed);
