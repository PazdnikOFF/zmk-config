/*
 * Повтор рекламы половинки, пока нет связи с донглом.
 *
 * Лечит «после перезагрузки донгла половинка не цепляется сама, помогает
 * только её ресет». Механизм (ZMK v0.3, Zephyr 3.5):
 *
 *   1. половинка с бондом рекламирует только направленно — на адрес донгла;
 *   2. для направленной рекламы Zephyr сначала проверяет, нет ли уже объекта
 *      соединения с этим адресом (le_adv_start_add_conn -> bt_conn_exists_le),
 *      и отказывает с -EINVAL. Объект в состоянии DISCONNECTED, на который
 *      ещё есть ссылки, считается существующим;
 *   3. ссылку держит поток нотификаций ZMK: bt_gatt_notify(NULL, ...) через
 *      notify_cb берёт соединение и не отпускает, пока gatt_notify ждёт буфер
 *      с K_FOREVER. То есть ссылка жива ровно тогда, когда линк перед
 *      разрывом стоял;
 *   4. рекламу ZMK перезапускает из disconnected() через системную очередь,
 *      а она приоритетнее потока нотификаций — реклама стартует первой, пока
 *      ссылка жива, и отказ детерминирован;
 *   5. advertising_cb на ошибке только пишет в лог и больше не пробует. Нет
 *      повтора и в ZMK main.
 *
 * Здесь, пока связи нет, раз в RETRY_PERIOD запускается та же
 * low-duty-направленная реклама, в которую ZMK переходит сам после high-duty.
 * Если реклама уже идёт, Zephyr отвечает -EALREADY и ничего не происходит —
 * лишнего расхода нет. Как только объект старого соединения освободится,
 * очередная попытка пройдёт.
 */

#include <zephyr/bluetooth/bluetooth.h>
#include <zephyr/bluetooth/conn.h>
#include <zephyr/kernel.h>
#include <zephyr/logging/log.h>
#include <zephyr/sys/iterable_sections.h>

#include <zmk/event_manager.h>
#include <zmk/events/split_peripheral_status_changed.h>
#include <zmk/split/transport/peripheral.h>

LOG_MODULE_DECLARE(zmk, CONFIG_ZMK_LOG_LEVEL);

/*
 * Больше high-duty окна направленной рекламы (1.28 с): сначала даём ZMK
 * отработать самому, и в обычном случае каждая попытка здесь упирается в
 * -EALREADY.
 */
#define RETRY_PERIOD K_SECONDS(2)

/*
 * Пишется из слушателя событий ZMK (контекст колбэков BT), читается из
 * системной очереди. Одиночный bool, и худшее, что даёт гонка, — одна лишняя
 * попытка, на которую Zephyr ответит -EALREADY.
 */
static bool connected;

static void each_bond(const struct bt_bond_info *info, void *user_data) {
    bt_addr_le_t *addr = user_data;

    if (bt_addr_le_cmp(&info->addr, BT_ADDR_LE_NONE) != 0) {
        bt_addr_le_copy(addr, &info->addr);
    }
}

/*
 * Выключенный транспорт ZMK выключил намеренно — при выборе между проводным и
 * радийным сплитом, — и рекламировать поперёк него нельзя. У транспорта без
 * get_status ZMK сам считает его всегда доступным (split/peripheral.c), здесь
 * так же.
 */
static bool transport_enabled(void) {
    STRUCT_SECTION_FOREACH(zmk_split_transport_peripheral, t) {
        if (t->api->get_status == NULL || t->api->get_status().enabled) {
            return true;
        }
    }

    return false;
}

static void readvertise(struct k_work *work);

static K_WORK_DELAYABLE_DEFINE(readvertise_work, readvertise);

static void readvertise(struct k_work *work) {
    ARG_UNUSED(work);

    if (connected || !transport_enabled()) {
        return;
    }

    bt_addr_le_t central = bt_addr_le_none;

    bt_foreach_bond(BT_ID_DEFAULT, each_bond, &central);

    /* Без бонда ZMK рекламирует ненаправленно, и проверка на старое
       соединение с конкретным адресом его не касается. */
    if (bt_addr_le_cmp(&central, BT_ADDR_LE_NONE) == 0) {
        return;
    }

    const int err = bt_le_adv_start(BT_LE_ADV_CONN_DIR_LOW_DUTY(&central), NULL, 0, NULL, 0);

    if (err == 0) {
        LOG_WRN("readvertise: реклама ZMK не шла, перезапущена здесь");
    } else if (err != -EALREADY) {
        LOG_DBG("readvertise: пока не выходит (%d), повторю", err);
    }

    k_work_reschedule(&readvertise_work, RETRY_PERIOD);
}

static int readvertise_listener(const zmk_event_t *eh) {
    const struct zmk_split_peripheral_status_changed *ev =
        as_zmk_split_peripheral_status_changed(eh);

    if (ev == NULL) {
        return ZMK_EV_EVENT_BUBBLE;
    }

    connected = ev->connected;

    /*
     * Событие с connected=false приходит и на разрыв, и на истечение
     * high-duty-рекламы (connected() с BT_HCI_ERR_ADV_TIMEOUT), так что
     * наблюдение взводится в обоих случаях.
     */
    if (connected) {
        k_work_cancel_delayable(&readvertise_work);
    } else {
        k_work_reschedule(&readvertise_work, RETRY_PERIOD);
    }

    return ZMK_EV_EVENT_BUBBLE;
}

ZMK_LISTENER(split_readvertise, readvertise_listener);
ZMK_SUBSCRIPTION(split_readvertise, zmk_split_peripheral_status_changed);
