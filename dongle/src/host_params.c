/*
 * Просьба к хосту о вменяемых параметрах соединения.
 *
 * Замер на живом устройстве показал, что macOS назначает донглу
 *
 *     interval 12 latency 22 timeout 200
 *
 * то есть разрешает пропускать до 22 событий соединения подряд. При интервале
 * 15 мс это до 330 мс, на которые может опоздать нажатие. CONFIG_BT_PERIPHERAL_
 * PREF_* тут не спасает: это лишь пожелание, а окончательные параметры
 * назначает центральный, которым в нашем случае является мак.
 *
 * Периферия вправе попросить другие параметры уже после подключения — этим и
 * пользуемся. Значения подобраны под требования Apple к аксессуарам, иначе
 * запрос просто отклонят:
 *
 *   - интервал не меньше 15 мс;
 *   - разница между минимумом и максимумом не меньше 15 мс;
 *   - latency не больше 30;
 *   - таймаут не больше 6 с и больше (1 + latency) * максимальный интервал * 2.
 *
 * Просим latency 0: экономия на ней для донгла всё равно упирается в то, что
 * он центральный для половинок и обязан дежурить в эфире постоянно.
 */

#include <zephyr/bluetooth/conn.h>
#include <zephyr/kernel.h>
#include <zephyr/logging/log.h>
#include <zephyr/sys/atomic.h>

LOG_MODULE_DECLARE(zmk, CONFIG_ZMK_LOG_LEVEL);

/* Единицы по 1.25 мс: 12 = 15 мс, 24 = 30 мс. */
#define HOST_INTERVAL_MIN 12
#define HOST_INTERVAL_MAX 24
#define HOST_LATENCY 0
/* Единицы по 10 мс. */
#define HOST_TIMEOUT 400

BUILD_ASSERT(HOST_INTERVAL_MAX - HOST_INTERVAL_MIN >= 12,
             "Apple требует разницу между минимумом и максимумом не меньше 15 мс");
BUILD_ASSERT(HOST_TIMEOUT * 8 > (1 + HOST_LATENCY) * HOST_INTERVAL_MAX * 2,
             "таймаут меньше допустимого для выбранного интервала");
BUILD_ASSERT(HOST_TIMEOUT <= 600, "Apple не принимает таймаут больше 6 с");

/*
 * Задержка перед запросом. Сразу после коннекта хост занят шифрованием и
 * разбором сервисов и отклоняет запрос, поэтому ждём. Пять секунд не годятся:
 * ровно в этот момент (CONFIG_BT_CONN_PARAM_UPDATE_TIMEOUT) свой автоматический
 * запрос шлёт сам Zephyr, и два запроса гоняются друг с другом. С тех пор как
 * PPCP в sweep_dongle.conf приведён к тем же значениям, автоматический запрос
 * просит то же самое, а этот работает повторной попыткой после него.
 */
#define HOST_PARAM_DELAY K_SECONDS(7)

static void request_params(struct k_work *work);

static K_WORK_DELAYABLE_DEFINE(param_work, request_params);

/*
 * Соединение, которому предстоит отправить запрос.
 *
 * Указатель атомарный не для красоты: пишет его коллбэк bt_conn_cb из потока
 * BT RX, а читает и освобождает работа из системной очереди. На обычном
 * указателе эти двое могли сойтись на одном и том же объекте и снять с него
 * ссылку дважды.
 */
static atomic_ptr_t pending = ATOMIC_PTR_INIT(NULL);

static void request_params(struct k_work *work) {
    struct bt_conn *conn = atomic_ptr_set(&pending, NULL);

    if (conn == NULL) {
        return;
    }

    const struct bt_le_conn_param param = {
        .interval_min = HOST_INTERVAL_MIN,
        .interval_max = HOST_INTERVAL_MAX,
        .latency = HOST_LATENCY,
        .timeout = HOST_TIMEOUT,
    };

    int err = bt_conn_le_param_update(conn, &param);
    if (err != 0 && err != -EALREADY) {
        LOG_WRN("host params: запрос отклонён (%d)", err);
    }

    bt_conn_unref(conn);
}

static void on_connected(struct bt_conn *conn, uint8_t err) {
    struct bt_conn_info info;

    if (err != 0 || bt_conn_get_info(conn, &info) != 0) {
        return;
    }

    /* Только соединение с хостом: для половинок мы центральный и параметры
       назначаем сами при подключении. */
    if (info.role != BT_CONN_ROLE_PERIPHERAL) {
        return;
    }

    struct bt_conn *previous = atomic_ptr_set(&pending, bt_conn_ref(conn));

    if (previous != NULL) {
        bt_conn_unref(previous);
    }

    k_work_reschedule(&param_work, HOST_PARAM_DELAY);
}

/*
 * Хост отвалился раньше, чем дошли руки до запроса: снимаем ссылку сразу, а не
 * держим её ещё несколько секунд на заведомо мёртвом соединении. Сравнение
 * через CAS обязательно — за это время pending мог смениться на другое
 * соединение, и обнулять его вслепую нельзя.
 */
static void on_disconnected(struct bt_conn *conn, uint8_t reason) {
    ARG_UNUSED(reason);

    if (atomic_ptr_cas(&pending, conn, NULL)) {
        k_work_cancel_delayable(&param_work);
        bt_conn_unref(conn);
    }
}

static void on_param_updated(struct bt_conn *conn, uint16_t interval, uint16_t latency,
                             uint16_t timeout) {
    LOG_INF("параметры соединения: интервал %u (%u мс), latency %u, таймаут %u мс", interval,
            interval * 5 / 4, latency, timeout * 10);
}

BT_CONN_CB_DEFINE(host_params_cb) = {
    .connected = on_connected,
    .disconnected = on_disconnected,
    .le_param_updated = on_param_updated,
};
