/*
 * Канал «агент на macOS -> донгл» поверх USB CDC-ACM.
 *
 * Формат — строки вида
 *
 *     layout=RU cpu=23 mem=61 disk=142 batt=87 chg=1
 *
 * Порядок ключей произвольный, незнакомые ключи игнорируются, битая строка
 * не роняет состояние. Частота — раз в 2-5 секунд: чаще e-paper всё равно не
 * перерисуется.
 */

#include <stdlib.h>
#include <string.h>

#include <zephyr/device.h>
#include <zephyr/drivers/uart.h>
#include <zephyr/kernel.h>
#include <zephyr/logging/log.h>

#include "host_proto.h"

LOG_MODULE_DECLARE(zmk, CONFIG_ZMK_LOG_LEVEL);

#define HOST_LINK_NODE DT_NODELABEL(host_cdc)

#if !DT_NODE_HAS_STATUS(HOST_LINK_NODE, okay)
#error "sweep_dongle: в оверлее нет узла host_cdc (zephyr,cdc-acm-uart)"
#endif

#define LINE_MAX HOST_LINE_MAX
#define LINE_QUEUE_DEPTH 4

struct host_line {
    char buf[LINE_MAX];
};

K_MSGQ_DEFINE(host_line_q, sizeof(struct host_line), LINE_QUEUE_DEPTH, 4);

static const struct device *const cdc = DEVICE_DT_GET(HOST_LINK_NODE);

static void host_link_isr(const struct device *dev, void *user_data) {
    static struct host_line line;
    static size_t len;
    uint8_t c;

    ARG_UNUSED(user_data);

    if (!uart_irq_update(dev)) {
        return;
    }

    while (uart_irq_rx_ready(dev)) {
        if (uart_fifo_read(dev, &c, 1) != 1) {
            continue;
        }

        if (c == '\r') {
            continue;
        }

        if (c == '\n') {
            line.buf[len] = '\0';
            if (len > 0) {
                /* Переполнение очереди — не беда: следующая строка придёт
                   через пару секунд и будет свежее. */
                k_msgq_put(&host_line_q, &line, K_NO_WAIT);
            }
            len = 0;
            continue;
        }

        if (len < LINE_MAX - 1) {
            line.buf[len++] = c;
        }
    }
}

static void host_link_thread(void *p1, void *p2, void *p3) {
    struct host_line line;

    ARG_UNUSED(p1);
    ARG_UNUSED(p2);
    ARG_UNUSED(p3);

    /* CDC-ACM появляется только после usb_enable() из SYS_INIT ZMK. */
    k_sleep(K_MSEC(CONFIG_SWEEP_DONGLE_HOST_LINK_STARTUP_DELAY_MS));

    if (!device_is_ready(cdc)) {
        LOG_ERR("host_link: CDC не готов, канал к маку не поднят");
        return;
    }

    uart_irq_callback_user_data_set(cdc, host_link_isr, NULL);
    uart_irq_rx_enable(cdc);
    LOG_INF("host_link: жду данные от агента");

    while (true) {
        k_msgq_get(&host_line_q, &line, K_FOREVER);

        dongle_host_proto_feed(line.buf);
    }
}

K_THREAD_DEFINE(host_link_tid, 1024, host_link_thread, NULL, NULL, NULL, 10, 0, 0);
