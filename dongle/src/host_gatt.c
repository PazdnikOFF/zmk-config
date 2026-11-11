/*
 * Канал «агент на macOS -> донгл» поверх BLE.
 *
 * Донгл и так BLE-периферия для хоста (HID-клавиатура), поэтому свой сервис
 * просто добавляется к тому же соединению — отдельная радиосвязь не нужна.
 * Формат данных тот же, что у CDC: одна ASCII-строка на запись.
 *
 * Запись требует шифрования: после сопряжения канал зашифрован, а пускать в
 * характеристику кого попало ни к чему.
 */

#include <string.h>

#include <zephyr/bluetooth/gatt.h>
#include <zephyr/bluetooth/uuid.h>
#include <zephyr/kernel.h>
#include <zephyr/logging/log.h>

#include <zmk/event_manager.h>
#include <zmk/events/layer_state_changed.h>

#include "dongle_ui.h"
#include "host_proto.h"

LOG_MODULE_DECLARE(zmk, CONFIG_ZMK_LOG_LEVEL);

/* f1ef61b7-9c57-4cb7-904a-d76a71836d4c — сервис метрик хоста. */
#define SWEEP_HOST_SERVICE_UUID                                                                    \
    BT_UUID_128_ENCODE(0xf1ef61b7, 0x9c57, 0x4cb7, 0x904a, 0xd76a71836d4c)

/* a336bc14-26b6-4cb1-93b0-a6a0d71e9275 — характеристика, куда пишет агент. */
#define SWEEP_HOST_METRICS_UUID                                                                    \
    BT_UUID_128_ENCODE(0xa336bc14, 0x26b6, 0x4cb1, 0x93b0, 0xa6a0d71e9275)

/* 6c0f2a91-... — состояние донгла, только на чтение. */
#define SWEEP_HOST_STATE_UUID                                                                      \
    BT_UUID_128_ENCODE(0x6c0f2a91, 0x5d3e, 0x4f18, 0x9a72, 0xb84c1e5d70a3)

static const struct bt_uuid_128 host_service_uuid = BT_UUID_INIT_128(SWEEP_HOST_SERVICE_UUID);
static const struct bt_uuid_128 host_metrics_uuid = BT_UUID_INIT_128(SWEEP_HOST_METRICS_UUID);
static const struct bt_uuid_128 host_state_uuid = BT_UUID_INIT_128(SWEEP_HOST_STATE_UUID);

static ssize_t write_metrics(struct bt_conn *conn, const struct bt_gatt_attr *attr, const void *buf,
                             uint16_t len, uint16_t offset, uint8_t flags) {
    ARG_UNUSED(conn);
    ARG_UNUSED(attr);
    ARG_UNUSED(flags);

    /* Строка должна приходить одним куском: делить её между записями незачем,
       она заведомо влезает в один ATT-пакет. */
    if (offset != 0) {
        return BT_GATT_ERR(BT_ATT_ERR_INVALID_OFFSET);
    }

    if (len == 0 || len >= HOST_LINE_MAX) {
        return BT_GATT_ERR(BT_ATT_ERR_INVALID_ATTRIBUTE_LEN);
    }

    char line[HOST_LINE_MAX];
    memcpy(line, buf, len);
    line[len] = '\0';

    /* Перевод строки не обязателен, но если агент его шлёт — не мешает. */
    char *nl = strpbrk(line, "\r\n");
    if (nl != NULL) {
        *nl = '\0';
    }

    dongle_host_proto_feed(line);

    return len;
}

/*
 * Состояние отдаётся по запросу: агент читает его сам и только в паузах печати.
 *
 * Исключение — смена слоя, ради окна подсказок раскладки на маке: ему нужно
 * показать новый слой сразу, а не через паузу в печати. Уведомление уходит
 * только тем, кто включил CCC, а агент включает его лишь пока окно открыто.
 * Цена — один короткий пакет на смену слоя по уже существующему соединению;
 * без окна в эфир по своей инициативе донгл не выходит, как и раньше.
 */
static ssize_t read_state(struct bt_conn *conn, const struct bt_gatt_attr *attr, void *buf,
                          uint16_t len, uint16_t offset) {
    struct dongle_public_state state;

    dongle_ui_fill_state(&state);

    return bt_gatt_attr_read(conn, attr, buf, len, offset, &state, sizeof(state));
}

BT_GATT_SERVICE_DEFINE(sweep_host_svc, BT_GATT_PRIMARY_SERVICE(&host_service_uuid),
                       BT_GATT_CHARACTERISTIC(&host_state_uuid.uuid,
                                              BT_GATT_CHRC_READ | BT_GATT_CHRC_NOTIFY,
                                              BT_GATT_PERM_READ_ENCRYPT, read_state, NULL, NULL),
                       BT_GATT_CCC(NULL, BT_GATT_PERM_READ_ENCRYPT | BT_GATT_PERM_WRITE_ENCRYPT),
                       BT_GATT_CHARACTERISTIC(&host_metrics_uuid.uuid,
                                              BT_GATT_CHRC_WRITE |
                                                  BT_GATT_CHRC_WRITE_WITHOUT_RESP,
                                              BT_GATT_PERM_WRITE_ENCRYPT, NULL, write_metrics,
                                              NULL));

/*
 * Уведомление о смене слоя.
 *
 * Одна смена слоя в ZMK — это пачка событий: &mo поднимает SYM, следом
 * conditional_layers поднимает накладку SYM_W. Отправка вынесена в работу, и
 * вся пачка, пришедшая до её запуска, уходит одним пакетом с итоговой маской.
 *
 * Атрибут значения — третий в сервисе: [0] сервис, [1] объявление
 * характеристики, [2] её значение.
 */
static uint32_t notified_layers = UINT32_MAX;

static void notify_layer_work_cb(struct k_work *work) {
    ARG_UNUSED(work);

    struct dongle_public_state state;

    dongle_ui_fill_state(&state);

    if (state.layer_state == notified_layers) {
        return;
    }

    /* Подписчиков нет — bt_gatt_notify вернёт ошибку, это нормально. */
    if (bt_gatt_notify(NULL, &sweep_host_svc.attrs[2], &state, sizeof(state)) == 0) {
        notified_layers = state.layer_state;
    }
}

static K_WORK_DEFINE(notify_layer_work, notify_layer_work_cb);

static int host_gatt_layer_listener(const zmk_event_t *eh) {
    if (as_zmk_layer_state_changed(eh) != NULL) {
        k_work_submit(&notify_layer_work);
    }

    return ZMK_EV_EVENT_BUBBLE;
}

ZMK_LISTENER(sweep_host_gatt, host_gatt_layer_listener);
ZMK_SUBSCRIPTION(sweep_host_gatt, zmk_layer_state_changed);
