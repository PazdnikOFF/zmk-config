#!/usr/bin/env bash
#
# Локальная сборка прошивок в контейнере ZMK. Быстрее, чем гонять через
# GitHub Actions: первая сборка ~2 минуты, повторные секунды за счёт ccache.
#
#   tools/build.sh                     # все шилды из build.yaml
#   tools/build.sh sweep_dongle        # только донгл
#   tools/build.sh -p sweep_dongle     # с полной пересборкой
#
# Готовые .uf2 складываются в firmware/.
#
# Первый запуск требует воркспейса west в .zmk:
#   python3 -m venv .zmk/.venv && .zmk/.venv/bin/pip install west
#   cd .zmk && .venv/bin/west update
#
# Внимание: .zmk монтируется в контейнер по тому же абсолютному пути, что и на
# хосте. Иначе ломается симлинк .zmk/config/west.yml, который смотрит на
# config/west.yml репозитория.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE="zmkfirmware/zmk-build-arm:stable"
BOARD="nice_nano_v2"

PRISTINE=""
if [ "${1:-}" = "-p" ]; then
    PRISTINE="-p"
    shift
fi

SHIELDS=("$@")
if [ ${#SHIELDS[@]} -eq 0 ]; then
    SHIELDS=(cradio_left cradio_right settings_reset sweep_dongle)
fi

if [ ! -d "$REPO/.zmk/zephyr" ]; then
    echo "нет $REPO/.zmk/zephyr — сначала west update, см. шапку скрипта" >&2
    exit 1
fi

mkdir -p "$REPO/firmware"

for shield in "${SHIELDS[@]}"; do
    echo "==> $shield"

    extra_west=""
    extra_cmake=""
    # Левая половина собирается со ZMK Studio, как в build.yaml.
    if [ "$shield" = "cradio_left" ]; then
        extra_west="-S studio-rpc-usb-uart"
        extra_cmake="-DCONFIG_ZMK_STUDIO=y"
    fi

    docker run --rm -v "$REPO:$REPO" -w "$REPO/.zmk" "$IMAGE" bash -c "
        set -e
        west zephyr-export >/dev/null

        # Репозиторий сам является zephyr-модулем, поэтому config/ копируется
        # наружу — ровно как это делает build-user-config в CI.
        rm -rf /tmp/zmk-config && mkdir -p /tmp/zmk-config/config
        cp -R '$REPO/config/'* /tmp/zmk-config/config/

        west build -s zmk/app -d '$REPO/.zmk/build/$shield' -b '$BOARD' $PRISTINE $extra_west -- \
            -DZMK_CONFIG=/tmp/zmk-config/config \
            -DZMK_EXTRA_MODULES='$REPO' \
            -DSHIELD='$shield' $extra_cmake
    "

    cp "$REPO/.zmk/build/$shield/zephyr/zmk.uf2" "$REPO/firmware/$shield-$BOARD.uf2"
    echo "    firmware/$shield-$BOARD.uf2"
done
