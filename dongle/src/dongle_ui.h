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
