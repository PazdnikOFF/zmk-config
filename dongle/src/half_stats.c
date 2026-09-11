/*
 * Состояние отправки нажатий на половинке — только для отладочной сборки.
 *
 * Сценарий, ради которого файл появился (11.09.2026): после перезагрузки
 * донгла линк к правой поднимается — донгл видит соединение и RSSI, — а
 * нажатий с неё нет, пока её не ресетнуть. С донгла это неотличимо, а причин
 * две:
 *
 *   (A) застряла сама половинка: работа отправки ZMK висит в bt_gatt_notify,
 *       который ждёт буфер с K_FOREVER, и снимки копятся в очереди;
 *   (B) донгл не подписался на её нажатия: отправлять некому, и
 *       bt_gatt_notify уходит в пустоту без всякой ошибки.
 *
 * Раз в SAMPLE_PERIOD снимается: есть ли связь, подписан ли донгл на
 * характеристику нажатий (bt_gatt_is_subscribed), занята ли работа отправки и
 * сколько снимков в очереди. Плюс «пинг» системной очереди: ZMK шлёт из неё
 * заряд батареи через тот же буферный пул, и если встанет она, встанет и
 * перезапуск рекламы. Пишется при каждом изменении и сводкой раз в
 * REPORT_EVERY выборок.
 *
 * Выборка идёт из своего потока, а не из системной очереди: иначе застрявшая
 * системная очередь заодно заткнула бы и сам сэмплер.
 */

#include <zephyr/bluetooth/conn.h>
#include <zephyr/bluetooth/gatt.h>
#include <zephyr/kernel.h>
#include <zephyr/logging/log.h>

#include <zmk/event_manager.h>
#include <zmk/events/split_peripheral_status_changed.h>

LOG_MODULE_DECLARE(zmk, CONFIG_ZMK_LOG_LEVEL);

/*
 * Внутренности app/src/split/bluetooth/service.c. Все три глобальные —
 * BT_GATT_SERVICE_DEFINE, K_WORK_DEFINE и K_MSGQ_DEFINE не делают static, —
 * но ни в одном заголовке не объявлены. Для отладочного файла приемлемо; при
 * обновлении ZMK сверить, что нажатия по-прежнему идут через
 * split_svc.attrs[1].
 */
extern const struct bt_gatt_service_static split_svc;
extern struct k_work service_position_notify_work;
extern struct k_msgq position_state_msgq;

#define SAMPLE_PERIOD K_SECONDS(2)
#define SAMPLE_PERIOD_S 2
#define REPORT_EVERY 5
/* Столько выборок подряд без отклика системной очереди — считаем её вставшей. */
#define SYSWQ_STUCK_SAMPLES 2

struct half_state {
    bool connected;
    bool subscribed;
    bool busy;
    bool syswq_ok;
    uint32_t queued;
};

/* Пишется из слушателя событий ZMK, читается потоком выборки. */
static volatile bool link_up;

static int half_stats_listener(const zmk_event_t *eh) {
    const struct zmk_split_peripheral_status_changed *ev =
        as_zmk_split_peripheral_status_changed(eh);

    if (ev != NULL) {
        link_up = ev->connected;
    }

    return ZMK_EV_EVENT_BUBBLE;
}

ZMK_LISTENER(half_stats, half_stats_listener);
ZMK_SUBSCRIPTION(half_stats, zmk_split_peripheral_status_changed);

/* --- пинг системной очереди ------------------------------------------------ */

static volatile uint32_t ping_sent;
static volatile uint32_t ping_done;

static void ping_handler(struct k_work *work) {
    ARG_UNUSED(work);
    ping_done = ping_sent;
}

static K_WORK_DEFINE(ping_work, ping_handler);

/* --- выборка ---------------------------------------------------------------- */

/* У половинки соединение одно — с донглом, в роли периферии. */
static void find_conn(struct bt_conn *conn, void *data) {
    struct bt_conn **out = data;
    struct bt_conn_info info;

    if (*out == NULL && bt_conn_get_info(conn, &info) == 0 &&
        info.role == BT_CONN_ROLE_PERIPHERAL) {
        *out = bt_conn_ref(conn);
    }
}

static void take(struct half_state *st, uint32_t *syswq_missed) {
    st->connected = link_up;

    struct bt_conn *conn = NULL;

    bt_conn_foreach(BT_CONN_TYPE_LE, find_conn, &conn);

    if (conn != NULL) {
        st->subscribed = bt_gatt_is_subscribed(conn, &split_svc.attrs[1], BT_GATT_CCC_NOTIFY);
        bt_conn_unref(conn);
    } else {
        st->subscribed = false;
    }

    st->busy = (k_work_busy_get(&service_position_notify_work) & K_WORK_RUNNING) != 0;
    st->queued = k_msgq_num_used_get(&position_state_msgq);

    /* Прошлый пинг отработал? Тогда шлём новый; нет — считаем пропуски. */
    if (ping_done == ping_sent) {
        *syswq_missed = 0;
        ping_sent++;
        k_work_submit(&ping_work);
    } else {
        (*syswq_missed)++;
    }

    st->syswq_ok = (*syswq_missed < SYSWQ_STUCK_SAMPLES);
}

static bool differs(const struct half_state *a, const struct half_state *b) {
    return a->connected != b->connected || a->subscribed != b->subscribed || a->busy != b->busy ||
           a->syswq_ok != b->syswq_ok || (a->queued == 0) != (b->queued == 0);
}

static void half_stats_thread(void *p1, void *p2, void *p3) {
    ARG_UNUSED(p1);
    ARG_UNUSED(p2);
    ARG_UNUSED(p3);

    struct half_state last = {0};
    uint32_t n = 0;
    uint32_t busy_run = 0;
    uint32_t syswq_missed = 0;

    while (true) {
        k_sleep(SAMPLE_PERIOD);

        struct half_state now;

        take(&now, &syswq_missed);

        /*
         * Работа отправки в норме живёт миллисекунды. Занята две выборки
         * подряд — значит, висит в bt_gatt_notify в ожидании буфера.
         */
        if (now.busy) {
            busy_run++;
            if (busy_run == 2) {
                LOG_WRN("half: ОТПРАВКА ЗАСТРЯЛА — работа занята дольше %u с, в очереди %u",
                        busy_run * SAMPLE_PERIOD_S, now.queued);
            }
        } else {
            if (busy_run >= 2) {
                LOG_WRN("half: отправка отвисла, простояла ~%u с", busy_run * SAMPLE_PERIOD_S);
            }
            busy_run = 0;
        }

        /* Главный признак варианта (B): связь есть, а подписки нет. */
        if (differs(&now, &last) || ++n % REPORT_EVERY == 0) {
            LOG_WRN("half: conn=%d sub=%d busy=%d queue=%u syswq=%s", now.connected,
                    now.subscribed, now.busy, now.queued, now.syswq_ok ? "ok" : "ВСТАЛА");
        }

        last = now;
    }
}

K_THREAD_DEFINE(half_stats_tid, 1024, half_stats_thread, NULL, NULL, NULL,
                K_LOWEST_APPLICATION_THREAD_PRIO, 0, 0);
