#include <stdlib.h>
#include <string.h>

#include <zephyr/kernel.h>
#include <zephyr/logging/log.h>

#include "dongle_ui.h"
#include "host_proto.h"

LOG_MODULE_DECLARE(zmk, CONFIG_ZMK_LOG_LEVEL);

/*
 * Состояние накапливается между строками: агент может прислать только то, что
 * изменилось, и терять остальное из-за этого не хочется. Мьютекс нужен потому,
 * что каналов два и они живут в разных контекстах — поток CDC и BT RX.
 */
K_MUTEX_DEFINE(proto_mutex);
static struct dongle_host_state accumulated;

void dongle_host_proto_feed(char *line) {
    struct dongle_host_state snapshot;

    k_mutex_lock(&proto_mutex, K_FOREVER);

    char *save = NULL;
    for (char *tok = strtok_r(line, " \t", &save); tok != NULL;
         tok = strtok_r(NULL, " \t", &save)) {
        char *eq = strchr(tok, '=');
        if (eq == NULL) {
            continue;
        }

        *eq = '\0';
        const char *key = tok;
        const char *val = eq + 1;

        if (strcmp(key, "layout") == 0) {
            strncpy(accumulated.layout, val, sizeof(accumulated.layout) - 1);
            accumulated.layout[sizeof(accumulated.layout) - 1] = '\0';
        } else if (strcmp(key, "cpu") == 0) {
            accumulated.cpu_pct = (uint8_t)atoi(val);
        } else if (strcmp(key, "mem") == 0) {
            accumulated.mem_pct = (uint8_t)atoi(val);
        } else if (strcmp(key, "disk") == 0) {
            accumulated.disk_free_gb = (uint16_t)atoi(val);
        } else if (strcmp(key, "batt") == 0) {
            accumulated.batt_pct = (uint8_t)atoi(val);
        } else if (strcmp(key, "chg") == 0) {
            accumulated.charging = (atoi(val) != 0);
        }
    }

    accumulated.valid = true;
    snapshot = accumulated;

    k_mutex_unlock(&proto_mutex);

    dongle_ui_set_host(&snapshot);
}
