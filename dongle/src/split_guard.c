/*
 * Защита от zmkfirmware/zmk#3522.
 *
 * split_central_disconnected() срабатывает на разрыв ЛЮБОГО соединения, в том
 * числе с хостом, и кладёт событие заряда с source = peripheral_slot_index_for_conn(),
 * а для не-половинки это -EINVAL, то есть 234 после приведения к uint8_t. Дальше
 * split/central.c без проверки пишет peripheral_battery_levels[234].
 *
 * Правим на входе обработчика: линкер (--wrap, см. CMakeLists.txt) направляет сюда
 * вызов из split/bluetooth/central.c. Форк ZMK ради одной проверки не нужен.
 */

#include <errno.h>

#include <zmk/split/central.h>
#include <zmk/split/transport/central.h>

int __real_zmk_split_transport_central_peripheral_event_handler(
    const struct zmk_split_transport_central *transport, uint8_t source,
    struct zmk_split_transport_peripheral_event ev);

int __wrap_zmk_split_transport_central_peripheral_event_handler(
    const struct zmk_split_transport_central *transport, uint8_t source,
    struct zmk_split_transport_peripheral_event ev) {
    if (source >= ZMK_SPLIT_CENTRAL_PERIPHERAL_COUNT) {
        return -EINVAL;
    }

    return __real_zmk_split_transport_central_peripheral_event_handler(transport, source, ev);
}
