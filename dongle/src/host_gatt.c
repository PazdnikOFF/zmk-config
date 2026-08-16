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

#include "host_proto.h"

LOG_MODULE_DECLARE(zmk, CONFIG_ZMK_LOG_LEVEL);

/* f1ef61b7-9c57-4cb7-904a-d76a71836d4c — сервис метрик хоста. */
#define SWEEP_HOST_SERVICE_UUID                                                                    \
    BT_UUID_128_ENCODE(0xf1ef61b7, 0x9c57, 0x4cb7, 0x904a, 0xd76a71836d4c)

/* a336bc14-26b6-4cb1-93b0-a6a0d71e9275 — характеристика, куда пишет агент. */
#define SWEEP_HOST_METRICS_UUID                                                                    \
    BT_UUID_128_ENCODE(0xa336bc14, 0x26b6, 0x4cb1, 0x93b0, 0xa6a0d71e9275)

static const struct bt_uuid_128 host_service_uuid = BT_UUID_INIT_128(SWEEP_HOST_SERVICE_UUID);
static const struct bt_uuid_128 host_metrics_uuid = BT_UUID_INIT_128(SWEEP_HOST_METRICS_UUID);

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

BT_GATT_SERVICE_DEFINE(sweep_host_svc, BT_GATT_PRIMARY_SERVICE(&host_service_uuid),
                       BT_GATT_CHARACTERISTIC(&host_metrics_uuid.uuid,
                                              BT_GATT_CHRC_WRITE |
                                                  BT_GATT_CHRC_WRITE_WITHOUT_RESP,
                                              BT_GATT_PERM_WRITE_ENCRYPT, NULL, write_metrics,
                                              NULL));
