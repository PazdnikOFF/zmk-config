/*
 * Причина последней перезагрузки донгла.
 *
 * Нужна ровно для одного вопроса: почему при подключении кабеля донгл
 * оказывается в бутлоадере. Бутлоадер Adafruit уходит в UF2 по двойному
 * ресету, поэтому «сразу режим прошивки» означает две перезагрузки подряд —
 * а вот от чего они, снаружи не видно совсем.
 *
 * Регистр причины переживает перезагрузку, но не сброс питания. Значит на
 * втором старте мы читаем причину ПЕРВОЙ перезагрузки, и этого хватает, чтобы
 * разделить два принципиально разных диагноза:
 *
 *   SOFTWARE / LOCKUP / WATCHDOG
 *       прошивка упала и перезапустилась сама (CONFIG_RESET_ON_FATAL_ERROR);
 *       искать надо в коде, и лог падения будет рядом в этом же выводе;
 *
 *   пусто (причин не заявлено)
 *       у nRF52 регистр RESETREAS не имеет битов на подачу питания и просадку:
 *       и то и другое обнуляет его целиком. То есть пустая причина означает,
 *       что питание пропадало физически, а не ошибку прошивки. Смотреть надо на
 *       кабель, порт и поведение без подключённой панели: e-paper запитывается
 *       через ключ EXT_POWER на P0.13 с задержкой 50 мс, ровно когда хост ещё
 *       разбирается с enumeration;
 *
 *   PIN
 *       нажали кнопку (в том числе дважды — это и есть штатный вход в UF2).
 *
 * Список расшифровки ровно тот, который nRF-драйвер hwinfo объявляет
 * поддерживаемым (drivers/hwinfo/hwinfo_nrf.c). RESET_BROWNOUT и RESET_POR он
 * не выдаёт никогда, поэтому их здесь и нет.
 *
 * Значение снимается на старте и печатается с задержкой, а потом ещё
 * повторяется: лог уезжает во второй порт CDC, и хост открывает его не сразу.
 * На живом перетыкании 11.09.2026 порт добрался до сборщика только на 26-й
 * секунде, и единственная печать на 4-й ушла в никуда — а это ровно тот
 * случай, ради которого файл и написан.
 */

#include <zephyr/drivers/hwinfo.h>
#include <zephyr/init.h>
#include <zephyr/kernel.h>
#include <zephyr/logging/log.h>

LOG_MODULE_DECLARE(zmk, CONFIG_ZMK_LOG_LEVEL);

#define REPORT_DELAY K_MSEC(4000)
#define REPORT_REPEAT K_SECONDS(30)
/* 20 раз по 30 секунд — десять минут, дальше лог не засоряем. */
#define REPORT_TIMES 20

static uint32_t cause;
static int cause_err;
static int reports_left = REPORT_TIMES;

static void print_cause(void) {
    if (cause_err != 0) {
        LOG_WRN("reset: причину получить не удалось (%d)", cause_err);
        return;
    }

    if (cause == 0) {
        LOG_WRN("reset: причин не заявлено — питание пропадало физически "
                "(подача питания или просадка рейла), программной причины нет");
        return;
    }

    LOG_WRN("reset: 0x%08x%s%s%s%s%s%s", (unsigned int)cause, (cause & RESET_PIN) ? " PIN" : "",
            (cause & RESET_SOFTWARE) ? " SOFTWARE" : "", (cause & RESET_WATCHDOG) ? " WATCHDOG" : "",
            (cause & RESET_CPU_LOCKUP) ? " LOCKUP" : "", (cause & RESET_DEBUG) ? " DEBUG" : "",
            (cause & RESET_LOW_POWER_WAKE) ? " WAKE" : "");
}

static void report(struct k_work *work) {
    print_cause();

    if (--reports_left > 0) {
        k_work_schedule(k_work_delayable_from_work(work), REPORT_REPEAT);
    }
}

static K_WORK_DELAYABLE_DEFINE(report_work, report);

static int reset_reason_init(void) {
    cause_err = hwinfo_get_reset_cause(&cause);

    /* Иначе следующий старт увидит причину не своей перезагрузки, а этой. */
    if (cause_err == 0) {
        hwinfo_clear_reset_cause();
    }

    k_work_schedule(&report_work, REPORT_DELAY);

    return 0;
}

SYS_INIT(reset_reason_init, APPLICATION, CONFIG_APPLICATION_INIT_PRIORITY);
