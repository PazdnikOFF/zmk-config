/*
 * Один хост за раз.
 *
 * ZMK не разрывает связь с хостом, когда активным становится другой профиль:
 * мак остаётся подключённым, пока активна Windows, и наоборот. Замер
 * 29.09.2026 показал у донгла четыре радиолинка разом — две половинки по
 * 7,5 мс (роли центральные) и два хоста, 15 и 22,5 мс (роли периферийные).
 *
 * Для контроллера это не бесплатно, и он сам об этом пишет. Справка Zephyr к
 * BT_CTLR_SCHED_ADVANCED (включён): планировщик «uses connection parameter
 * request in peripheral role to negotiate non-overlapping placement with
 * active central roles to avoid peripheral roles drifting into active central
 * roles». То есть события периферийной роли способны наползать на события
 * центральных, и тогда их вытесняет. Нажатие в такой момент ждёт следующего
 * события соединения, а то и нескольких — это и есть вязкость, которая
 * приходит и уходит сама: наползание медленно дрейфует.
 *
 * Чем меньше ролей, тем меньше наползаний. Лишний хост — единственная роль,
 * без которой можно обойтись: половинки нужны обе, активный хост нужен.
 *
 * Обратно чужой хост сам не подключится: центральный может подключиться
 * только к тому, кто рекламируется, а ZMK рекламируется лишь для активного
 * профиля. Цена — при переключении профиля хост переподключается сам, это
 * секунда-другая.
 */

#include <zephyr/bluetooth/conn.h>
#include <zephyr/bluetooth/hci_types.h>
#include <zephyr/kernel.h>
#include <zephyr/logging/log.h>

#include <zmk/ble.h>
#include <zmk/event_manager.h>
#include <zmk/events/ble_active_profile_changed.h>

LOG_MODULE_DECLARE(zmk, CONFIG_ZMK_LOG_LEVEL);

static void drop_foreign_cb(struct bt_conn *conn, void *data) {
    struct bt_conn_info info;

    if (bt_conn_get_info(conn, &info) != 0 || info.type != BT_CONN_TYPE_LE) {
        return;
    }

    /* Центральные роли — это половинки, их не трогаем. */
    if (info.role != BT_CONN_ROLE_PERIPHERAL) {
        return;
    }

    /*
     * Сверяемся не с адресом активного профиля, а с тем, в КАКОМ профиле
     * записан этот хост. Разница существенная: пока активный профиль пуст,
     * идёт сопряжение новой машины, её адрес ещё ни в одном профиле не лежит
     * и в момент подключения не совпадает ни с чем. Сравнение с адресом
     * выгоняло бы ровно того, кого сейчас сопрягают.
     */
    const int active = zmk_ble_active_profile_index();
    const int profile = zmk_ble_profile_index(bt_conn_get_dst(conn));

    if (profile < 0 || profile == active) {
        return;
    }

    char addr[BT_ADDR_LE_STR_LEN];
    bt_addr_le_to_str(bt_conn_get_dst(conn), addr, sizeof(addr));

    const int err = bt_conn_disconnect(conn, BT_HCI_ERR_REMOTE_USER_TERM_CONN);

    LOG_WRN("solo: отключаю хост профиля %d (%s), активен %d: %d", profile + 1, addr, active + 1,
            err);
}

/*
 * Через работу, а не прямо из колбэка: bt_conn_disconnect внутри обработчика
 * connected отрабатывает до того, как стек закончит с этим соединением, и
 * ZMK в том же колбэке ещё правит рекламу.
 */
/*
 * Выгоняем чужого только при ПОДКЛЮЧЁННОМ активном хосте, и это не
 * придирка, а единственный способ не устроить карусель.
 *
 * ZMK рекламируется открыто даже для сопряжённого профиля: направленную
 * рекламу там отключили из-за центральных с приватными адресами (ble.c,
 * update_advertising, ссылка на zephyr#14984). Пока активный хост не
 * подключён, реклама идёт — и выгнанный чужой хост цепляется обратно на неё
 * через доли секунды, а мы выгоняем его снова. В логе это выглядело как
 * connected/solo/connected по кругу, и между кругами ZMK писал «Not sending,
 * not connected to active profile»: нажатия в этот момент терялись.
 *
 * Когда активный хост подключён, ZMK рекламу не ведёт вовсе, и вернуться
 * чужому некуда — выгон срабатывает ровно один раз.
 */
static void drop_foreign_work_cb(struct k_work *work) {
    if (!zmk_ble_active_profile_is_connected()) {
        LOG_DBG("solo: активный хост ещё не подключён, чужих не трогаю");
        return;
    }

    bt_conn_foreach(BT_CONN_TYPE_LE, drop_foreign_cb, NULL);
}

static K_WORK_DELAYABLE_DEFINE(drop_work, drop_foreign_work_cb);

static void schedule_drop(void) {
    k_work_reschedule(&drop_work, K_MSEC(CONFIG_SWEEP_DONGLE_SINGLE_HOST_DELAY_MS));
}

static void host_solo_connected(struct bt_conn *conn, uint8_t err) {
    if (err == 0) {
        schedule_drop();
    }
}

BT_CONN_CB_DEFINE(host_solo_cb) = {
    .connected = host_solo_connected,
};

static int host_solo_listener(const zmk_event_t *eh) {
    if (as_zmk_ble_active_profile_changed(eh) != NULL) {
        /* Профиль сменился: прошлый хост остался висеть — выгнать. */
        schedule_drop();
    }

    return ZMK_EV_EVENT_BUBBLE;
}

ZMK_LISTENER(sweep_host_solo, host_solo_listener);
ZMK_SUBSCRIPTION(sweep_host_solo, zmk_ble_active_profile_changed);
