/*
 * Телеметрия радиолинков донгла — только для отладочной сборки.
 *
 * Отвечает на вопрос «почему одна половинка со временем начинает вязнуть, и
 * буквы с неё встают не на свои места». Снаружи у этого два кандидата, и
 * выглядят они одинаково:
 *
 *   * радио: у дальней половинки мал запас по сигналу (расстояние, металл,
 *     USB 3 рядом с донглом) — видно по RSSI;
 *   * планирование: линк к хосту у донгла периферийный и тикает по часам
 *     мака, сплит-линки центральные и тикают по часам донгла; якорь первого
 *     медленно дрейфует и периодически наезжает на один из сплит-линков,
 *     события которого начинают пропускаться. RSSI при этом нормальный, а
 *     нажатия с одной стороны приходят пачками.
 *
 * Поэтому пишется три вещи:
 *
 *   1. Раз в REPORT_PERIOD по каждому соединению — сторона, интервал,
 *      latency, таймаут и RSSI.
 *   2. Каждый разрыв сплит-линка сразу, с причиной.
 *   4. Направленная реклама, которую видит скан донгла. Отвечает на вопрос
 *      «почему после перезагрузки донгла одна половинка не цепляется сама»:
 *      половинка с бондом рекламирует только направленно, и если её адреса в
 *      этом логе нет — она молчит сама, а донгл тут ни при чём.
 *   6. Путь нажатий к хосту по BLE (app/src/hog.c) с историей С ЗАГРУЗКИ:
 *      максимальная глубина очереди отчётов, самый долгий затык отправки,
 *      число затыков, смены параметров линка к хосту. История нужна потому,
 *      что задержка приходит на батарее, когда лог некуда писать; воткнутый
 *      после этого кабель донгл не перезагружает, и первый же отчёт покажет,
 *      что было.
 *   5. Жизнь каждого линка с момента подключения: сколько он живёт, сколько
 *      с него пришло нажатий и событий батареи, какой уровень шифрования.
 *      Отвечает на «линк есть, а нажатий нет»: после перезагрузки донгла вся
 *      его настройка проходит, пока USB ещё не подключён и логу некуда
 *      писать, так что увидеть её можно только по накопленному итогу.
 *   3. Пачки: события одной половинки, пришедшие не дальше BATCH_GAP_MS друг
 *      от друга. Человек так печатать не может — дребезг одной клавиши 5 мс, —
 *      зато так выглядит линк, который постоял и выплюнул накопленное разом.
 *      Мерится по метке времени, которую ставит транспорт сплита, а не по
 *      моменту прихода в этот слушатель: комбо захватывают и отпускают события
 *      позже, и собственный таймер показал бы пачки там, где их не было.
 *
 * RSSI читается синхронной HCI-командой, поэтому только из своего потока. С
 * программным контроллером Zephyr хост разбирает HCI в контексте bt_recv()
 * потока контроллера (BT_RECV_BLOCKING), и синхронный запрос из колбэка BT
 * повесил бы его навсегда.
 */

#include <string.h>

#include <zephyr/bluetooth/bluetooth.h>
#include <zephyr/bluetooth/conn.h>
#include <zephyr/bluetooth/hci.h>
#include <zephyr/kernel.h>
#include <zephyr/logging/log.h>
#include <zephyr/net/buf.h>
#include <zephyr/sys/byteorder.h>

#include <zmk/event_manager.h>
#include <zmk/events/battery_state_changed.h>
#include <zmk/events/position_state_changed.h>
#include <zmk/split/central.h>

#include "dongle_ui.h"

LOG_MODULE_DECLARE(zmk, CONFIG_ZMK_LOG_LEVEL);

/*
 * Внутренняя функция app/src/split/bluetooth/central.c. Она глобальная, но ни
 * в одном публичном заголовке не объявлена. Для отладочного файла это
 * приемлемо; при обновлении ZMK сверить сигнатуру.
 */
int peripheral_slot_index_for_conn(struct bt_conn *conn);

/*
 * Путь нажатий к хосту по BLE, app/src/hog.c. Отчёт кладётся в очередь
 * zmk_hog_keyboard_msgq (CONFIG_ZMK_BLE_KEYBOARD_REPORT_QUEUE_SIZE, 20), работа
 * hog_keyboard_work в своей очереди отправляет его через bt_gatt_notify_cb, а
 * тот ждёт буфер без таймаута. Встал линк к хосту — очередь растёт, работа
 * висит: снаружи это «текст выводится с задержкой с обеих половинок». Оба
 * объекта глобальные (K_MSGQ_DEFINE и K_WORK_DEFINE не делают static), но в
 * заголовках не объявлены.
 */
extern struct k_msgq zmk_hog_keyboard_msgq;
extern struct k_work hog_keyboard_work;

#define REPORT_PERIOD K_SECONDS(10)
#define BATCH_GAP_MS 1

#define SLOTS ZMK_SPLIT_CENTRAL_PERIPHERAL_COUNT

/*
 * Что известно о каждом слоте с момента подключения.
 *
 * К моменту нашего колбэка disconnected ZMK уже освободил слот: его колбэк
 * зарегистрирован через bt_conn_cb_register, а Zephyr зовёт такие раньше
 * статических BT_CONN_CB_DEFINE. Поэтому слот запоминается при подключении.
 * Указатель хранится без ссылки — он только сравнивается и стирается на
 * разрыве, пока объект соединения ещё жив. Счётчики под stats_lock.
 */
static struct {
    const struct bt_conn *conn;
    int8_t slot;
    char addr[BT_ADDR_LE_STR_LEN];
    int64_t up_ms;
    uint32_t keys;
    uint32_t batt;
    uint8_t sec;
} known[SLOTS];

/* --- путь нажатий к хосту ---------------------------------------------------- */

/*
 * Выборка из таймера (контекст прерывания): чтение счётчика очереди и
 * k_work_busy_get оба безопасны в ISR, общий спинлок тоже. Отправка одного
 * отчёта при живом линке занимает доли миллисекунды, так что работа, занятая
 * дольше HID_STALL_MS, стоит в ожидании буфера — это затык.
 */
#define HID_SAMPLE_MS 20
#define HID_STALL_MS 100

struct hid_stats {
    uint32_t q_max;
    int64_t q_max_at;
    uint32_t q_max_window;
    uint32_t busy_run;
    uint32_t busy_max_ms;
    int64_t busy_max_at;
    uint32_t stalls;
    uint32_t host_updates;
};

static struct hid_stats hid;

static struct k_spinlock stats_lock;

static void hid_sample(struct k_timer *timer) {
    ARG_UNUSED(timer);

    const uint32_t q = k_msgq_num_used_get(&zmk_hog_keyboard_msgq);
    const bool busy = (k_work_busy_get(&hog_keyboard_work) & K_WORK_RUNNING) != 0;
    const int64_t now = k_uptime_get();

    k_spinlock_key_t key = k_spin_lock(&stats_lock);

    if (q > hid.q_max) {
        hid.q_max = q;
        hid.q_max_at = now;
    }
    hid.q_max_window = MAX(hid.q_max_window, q);

    if (busy) {
        hid.busy_run++;
    } else if (hid.busy_run > 0) {
        const uint32_t ms = hid.busy_run * HID_SAMPLE_MS;

        if (ms >= HID_STALL_MS) {
            hid.stalls++;
        }
        if (ms > hid.busy_max_ms) {
            hid.busy_max_ms = ms;
            hid.busy_max_at = now;
        }
        hid.busy_run = 0;
    }

    k_spin_unlock(&stats_lock, key);
}

static K_TIMER_DEFINE(hid_timer, hid_sample, NULL);

/* --- пачки нажатий --------------------------------------------------------- */

struct slot_stats {
    uint32_t keys;
    uint32_t batched;
    uint32_t run;
    uint32_t max_run;
    int64_t last_ms;
};

/* Пишется из системной очереди (там ZMK поднимает события половинок),
   читается и обнуляется из потока отчёта. Спинлок общий, объявлен выше. */
static struct slot_stats stats[SLOTS];
static uint32_t drops[SLOTS];

static int link_stats_listener(const zmk_event_t *eh) {
    const struct zmk_peripheral_battery_state_changed *bev =
        as_zmk_peripheral_battery_state_changed(eh);

    /* Ноль ZMK шлёт сам на разрыве — это не событие с половинки. */
    if (bev != NULL) {
        if (bev->source < SLOTS && bev->state_of_charge != 0) {
            k_spinlock_key_t key = k_spin_lock(&stats_lock);
            known[bev->source].batt++;
            k_spin_unlock(&stats_lock, key);
        }
        return ZMK_EV_EVENT_BUBBLE;
    }

    const struct zmk_position_state_changed *ev = as_zmk_position_state_changed(eh);

    /* Локальные события (source 255) и чужие источники не интересны. */
    if (ev == NULL || ev->source >= SLOTS) {
        return ZMK_EV_EVENT_BUBBLE;
    }

    k_spinlock_key_t key = k_spin_lock(&stats_lock);
    struct slot_stats *s = &stats[ev->source];

    if (s->keys > 0 && ev->timestamp - s->last_ms <= BATCH_GAP_MS) {
        s->batched++;
        s->run++;
    } else {
        s->run = 1;
    }

    s->max_run = MAX(s->max_run, s->run);
    s->last_ms = ev->timestamp;
    s->keys++;
    known[ev->source].keys++;

    k_spin_unlock(&stats_lock, key);

    return ZMK_EV_EVENT_BUBBLE;
}

ZMK_LISTENER(link_stats, link_stats_listener);
ZMK_SUBSCRIPTION(link_stats, zmk_position_state_changed);
ZMK_SUBSCRIPTION(link_stats, zmk_peripheral_battery_state_changed);

/* --- сторона по слоту ------------------------------------------------------ */

static char side_of_slot(int slot) {
    struct dongle_public_state st;

    dongle_ui_fill_state(&st);

    if (slot < 0 || st.left_slot == 0xFF) {
        return '?';
    }

    return (slot == st.left_slot) ? 'L' : 'R';
}

/* --- подключения и разрывы ------------------------------------------------- */

static const char *reason_name(uint8_t reason) {
    switch (reason) {
    case BT_HCI_ERR_CONN_TIMEOUT:
        return "supervision timeout: связь потеряна";
    case BT_HCI_ERR_REMOTE_USER_TERM_CONN:
        return "разорвала половинка";
    case BT_HCI_ERR_LOCALHOST_TERM_CONN:
        return "разорвал донгл";
    case BT_HCI_ERR_CONN_FAIL_TO_ESTAB:
        return "не установилось";
    case BT_HCI_ERR_LL_RESP_TIMEOUT:
        return "LL response timeout";
    default:
        return "";
    }
}

static void on_connected(struct bt_conn *conn, uint8_t err) {
    struct bt_conn_info info;

    if (err != 0 || bt_conn_get_info(conn, &info) != 0 || info.role != BT_CONN_ROLE_CENTRAL) {
        return;
    }

    const int slot = peripheral_slot_index_for_conn(conn);

    if (slot < 0 || slot >= SLOTS) {
        return;
    }

    known[slot].conn = conn;
    known[slot].slot = slot;
    bt_addr_le_to_str(bt_conn_get_dst(conn), known[slot].addr, sizeof(known[slot].addr));

    k_spinlock_key_t key = k_spin_lock(&stats_lock);
    known[slot].up_ms = k_uptime_get();
    known[slot].keys = 0;
    known[slot].batt = 0;
    known[slot].sec = BT_SECURITY_L1;
    k_spin_unlock(&stats_lock, key);

    LOG_WRN("link %c slot=%d подключена %s", side_of_slot(slot), slot, known[slot].addr);
}

static void on_disconnected(struct bt_conn *conn, uint8_t reason) {
    for (int i = 0; i < SLOTS; i++) {
        if (known[i].conn != conn) {
            continue;
        }

        const int slot = known[i].slot;

        known[i].conn = NULL;

        k_spinlock_key_t key = k_spin_lock(&stats_lock);
        const uint32_t total = ++drops[slot];
        k_spin_unlock(&stats_lock, key);

        LOG_WRN("link %c slot=%d РАЗРЫВ %s reason=0x%02x %s (всего %u)", side_of_slot(slot), slot,
                known[i].addr, reason, reason_name(reason), total);
        return;
    }
}

/* --- что видит скан ------------------------------------------------------- */

/*
 * ZMK пишет увиденное при скане только на уровне DBG, а в отладочной сборке
 * стоит INF. Здесь — только направленная реклама: её шлёт половинка с бондом,
 * и контроллер пропускает лишь адресованную нам, так что посторонних тут почти
 * не бывает. Фильтр дубликатов у скана ZMK включён — каждый адрес появится раз
 * за сеанс скана и лог не зальёт.
 */
static void scan_recv(const struct bt_le_scan_recv_info *info, struct net_buf_simple *buf) {
    ARG_UNUSED(buf);

    if (info->adv_type != BT_GAP_ADV_TYPE_ADV_DIRECT_IND) {
        return;
    }

    char addr[BT_ADDR_LE_STR_LEN];

    bt_addr_le_to_str(info->addr, addr, sizeof(addr));
    LOG_WRN("scan: направленная реклама от %s rssi=%d", addr, info->rssi);
}

static struct bt_le_scan_cb scan_cb = {
    .recv = scan_recv,
};

/* ZMK подписывается на нажатия половинки только после шифрования, так что
   застрявший на L1 линк объясняет «связь есть, нажатий нет» сам по себе. */
static void on_security_changed(struct bt_conn *conn, bt_security_t level,
                                enum bt_security_err err) {
    for (int i = 0; i < SLOTS; i++) {
        if (known[i].conn != conn) {
            continue;
        }

        known[i].sec = level;

        if (err != BT_SECURITY_ERR_SUCCESS) {
            LOG_WRN("link %c slot=%d шифрование не удалось: level %u err %d",
                    side_of_slot(known[i].slot), known[i].slot, level, err);
        }
        return;
    }
}

/* Параметры линка к хосту назначает хост и вправе поменять когда угодно;
   host_params.c просит нужные один раз после подключения. */
static void on_param_updated(struct bt_conn *conn, uint16_t interval, uint16_t latency,
                             uint16_t timeout) {
    struct bt_conn_info info;

    if (bt_conn_get_info(conn, &info) != 0 || info.role != BT_CONN_ROLE_PERIPHERAL) {
        return;
    }

    k_spinlock_key_t key = k_spin_lock(&stats_lock);
    const uint32_t n = ++hid.host_updates;
    k_spin_unlock(&stats_lock, key);

    const uint32_t int_x100 = (uint32_t)interval * 125;

    LOG_WRN("link HOST параметры сменились (%u-й раз): int=%u.%02ums lat=%u to=%ums", n,
            int_x100 / 100, int_x100 % 100, latency, timeout * 10);
}

BT_CONN_CB_DEFINE(link_stats_cb) = {
    .connected = on_connected,
    .disconnected = on_disconnected,
    .security_changed = on_security_changed,
    .le_param_updated = on_param_updated,
};

/* --- периодический отчёт --------------------------------------------------- */

static int read_rssi(struct bt_conn *conn, int8_t *rssi) {
    uint16_t handle;
    int err = bt_hci_get_conn_handle(conn, &handle);

    if (err != 0) {
        return err;
    }

    struct net_buf *buf = bt_hci_cmd_create(BT_HCI_OP_READ_RSSI, sizeof(struct bt_hci_cp_read_rssi));

    if (buf == NULL) {
        return -ENOBUFS;
    }

    struct bt_hci_cp_read_rssi *cp = net_buf_add(buf, sizeof(*cp));

    cp->handle = sys_cpu_to_le16(handle);

    struct net_buf *rsp = NULL;

    err = bt_hci_cmd_send_sync(BT_HCI_OP_READ_RSSI, buf, &rsp);
    if (err != 0) {
        return err;
    }

    *rssi = ((const struct bt_hci_rp_read_rssi *)rsp->data)->rssi;
    net_buf_unref(rsp);

    return 0;
}

struct collect_ctx {
    struct bt_conn *conns[CONFIG_BT_MAX_CONN];
    size_t count;
};

/* Внутри bt_conn_foreach блокирующий HCI не зовём: только собираем ссылки. */
static void collect(struct bt_conn *conn, void *data) {
    struct collect_ctx *ctx = data;

    if (ctx->count < ARRAY_SIZE(ctx->conns)) {
        ctx->conns[ctx->count++] = bt_conn_ref(conn);
    }
}

static void report_link(struct bt_conn *conn) {
    struct bt_conn_info info;

    if (bt_conn_get_info(conn, &info) != 0) {
        return;
    }

    int8_t rssi = 0;
    const bool have_rssi = (read_rssi(conn, &rssi) == 0);

    /* Интервал в единицах по 1.25 мс, печатаем в сотых долях миллисекунды. */
    const uint32_t int_x100 = (uint32_t)info.le.interval * 125;

    if (info.role == BT_CONN_ROLE_CENTRAL) {
        const int slot = peripheral_slot_index_for_conn(conn);
        uint32_t up_s = 0, keys = 0, batt = 0;
        uint8_t sec = 0;

        if (slot >= 0 && slot < SLOTS && known[slot].conn == conn) {
            k_spinlock_key_t key = k_spin_lock(&stats_lock);
            up_s = (uint32_t)((k_uptime_get() - known[slot].up_ms) / 1000);
            keys = known[slot].keys;
            batt = known[slot].batt;
            sec = known[slot].sec;
            k_spin_unlock(&stats_lock, key);
        }

        LOG_WRN("link %c slot=%d int=%u.%02ums lat=%u to=%ums rssi=%d%s up=%us keys=%u batt=%u sec=%u",
                side_of_slot(slot), slot, int_x100 / 100, int_x100 % 100, info.le.latency,
                info.le.timeout * 10, rssi, have_rssi ? "" : "(нет)", up_s, keys, batt, sec);
    } else {
        LOG_WRN("link HOST int=%u.%02ums lat=%u to=%ums rssi=%d%s", int_x100 / 100, int_x100 % 100,
                info.le.latency, info.le.timeout * 10, rssi, have_rssi ? "" : "(нет)");
    }
}

static void report_hid(void) {
    const int64_t now = k_uptime_get();

    k_spinlock_key_t key = k_spin_lock(&stats_lock);
    const struct hid_stats snap = hid;
    hid.q_max_window = 0;
    k_spin_unlock(&stats_lock, key);

    LOG_WRN("hid: очередь окно=%u макс=%u (%us назад) затык макс=%ums (%us назад) затыков=%u "
            "смен_параметров=%u аптайм=%us",
            snap.q_max_window, snap.q_max,
            snap.q_max ? (uint32_t)((now - snap.q_max_at) / 1000) : 0, snap.busy_max_ms,
            snap.busy_max_ms ? (uint32_t)((now - snap.busy_max_at) / 1000) : 0, snap.stalls,
            snap.host_updates, (uint32_t)(now / 1000));
}

static void report_keys(void) {
    struct slot_stats snap[SLOTS];

    k_spinlock_key_t key = k_spin_lock(&stats_lock);
    memcpy(snap, stats, sizeof(snap));
    for (int i = 0; i < SLOTS; i++) {
        /* last_ms оставляем: иначе первое событие окна сравнилось бы с нулём. */
        stats[i].keys = 0;
        stats[i].batched = 0;
        stats[i].run = 0;
        stats[i].max_run = 0;
    }
    k_spin_unlock(&stats_lock, key);

    for (int i = 0; i < SLOTS; i++) {
        if (snap[i].keys == 0) {
            continue;
        }

        LOG_WRN("keys %c slot=%d n=%u batched=%u maxrun=%u", side_of_slot(i), i, snap[i].keys,
                snap[i].batched, snap[i].max_run);
    }
}

static void link_stats_thread(void *p1, void *p2, void *p3) {
    ARG_UNUSED(p1);
    ARG_UNUSED(p2);
    ARG_UNUSED(p3);

    bt_le_scan_cb_register(&scan_cb);
    k_timer_start(&hid_timer, K_MSEC(HID_SAMPLE_MS), K_MSEC(HID_SAMPLE_MS));

    while (true) {
        k_sleep(REPORT_PERIOD);

        struct collect_ctx ctx = {0};

        bt_conn_foreach(BT_CONN_TYPE_LE, collect, &ctx);

        for (size_t i = 0; i < ctx.count; i++) {
            report_link(ctx.conns[i]);
            bt_conn_unref(ctx.conns[i]);
        }

        report_keys();
        report_hid();
    }
}

K_THREAD_DEFINE(link_stats_tid, 1536, link_stats_thread, NULL, NULL, NULL,
                K_LOWEST_APPLICATION_THREAD_PRIO, 0, 0);
