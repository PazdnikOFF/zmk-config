/*
 * Состояние, которое донгл показывает на экране.
 */

#pragma once

#include <stdbool.h>
#include <stdint.h>

/* Всё, что присылает агент на маке. */
struct dongle_host_state {
    bool valid; /* пришла хотя бы одна корректная строка */
    char layout[8];
    uint8_t cpu_pct;
    uint8_t mem_pct;
    uint16_t disk_free_gb;
    uint8_t batt_pct;
    bool charging;
};

/*
 * Положить новое состояние и перерисовать экран. Можно звать из любого
 * потока: внутри копия под мьютексом и k_work в очередь дисплея — LVGL
 * трогается только из неё.
 */
void dongle_ui_set_host(const struct dongle_host_state *st);

/*
 * Слепок состояния для чтения снаружи — его отдаёт GATT-характеристика
 * состояния, по которой строится меню в строке состояния macOS.
 *
 * Только чтение и никаких уведомлений: любой обмен по радио конкурирует с
 * нажатиями, а агент читает это лишь в паузах печати и при открытии меню.
 *
 * Раскладка полей зафиксирована и разбирается агентом побайтно, поэтому
 * структура упакована и начинается с версии: добавлять поля можно только в
 * конец и с ростом версии.
 */
#define DONGLE_STATE_VERSION 2
#define DONGLE_BATT_UNKNOWN 0xFF

#define DONGLE_BT_CONNECTED BIT(0)
#define DONGLE_BT_OPEN BIT(1)
#define DONGLE_BT_USB BIT(2)

struct dongle_public_state {
    uint8_t version;
    uint8_t layer;
    uint8_t batt_left;
    uint8_t batt_right;
    uint8_t batt_dongle;
    uint8_t bt_profile; /* нумерация с единицы, как на экране */
    uint8_t bt_flags;
    /*
     * Какой слот периферии признан левой половиной. Нужен не для показа, а
     * чтобы расхождение между панелью и меню можно было увидеть, а не
     * гадать о нём: 0xFF означает, что сторона ещё не определена.
     */
    uint8_t left_slot;
} __packed;

void dongle_ui_fill_state(struct dongle_public_state *out);
