# Модуль подключается ко ВСЕМ сборкам этого репозитория, включая половины
# клавиатуры, поэтому исходники цепляются только под своим symbol'ом.
if(CONFIG_SWEEP_DONGLE_UI)
  zephyr_library()
  # ZMK цепляет свой include/ только к таргету app (PRIVATE), внешним
  # библиотекам он не виден — а нам нужен zmk/display.h.
  zephyr_library_include_directories(${APPLICATION_SOURCE_DIR}/include)
  zephyr_library_sources(src/screen.c)
  zephyr_library_sources(src/host_proto.c)
  zephyr_library_sources_ifdef(CONFIG_SWEEP_DONGLE_TYPING_SPEED src/typing_speed.c)
  zephyr_library_sources_ifdef(CONFIG_ZMK_BLE src/host_params.c)
  zephyr_library_sources_ifdef(CONFIG_SWEEP_DONGLE_IDLE_SLOW_SPLIT src/power.c)
  zephyr_library_sources_ifdef(CONFIG_SWEEP_DONGLE_HOST_LINK_CDC src/host_link.c)
  zephyr_library_sources_ifdef(CONFIG_SWEEP_DONGLE_HOST_LINK_GATT src/host_gatt.c)
  zephyr_library_sources_ifdef(CONFIG_SWEEP_DONGLE_DEBUG_RESET_REASON src/reset_reason.c)
  zephyr_library_sources_ifdef(CONFIG_SWEEP_DONGLE_DEBUG_LINKS src/link_stats.c)
endif()

# Половинки. Библиотека названа явно: блок выше создаёт безымянную
# zephyr_library(), и в одной сборке двух с одинаковым именем быть не должно.
# Сейчас блоки взаимоисключающие (донгл против половинок), но полагаться на
# это ни к чему.
if(CONFIG_SWEEP_SPLIT_READVERTISE OR CONFIG_SWEEP_HALF_DEBUG_STATS)
  zephyr_library_named(sweep_split_half)
  zephyr_library_include_directories(${APPLICATION_SOURCE_DIR}/include)
  zephyr_library_sources_ifdef(CONFIG_SWEEP_SPLIT_READVERTISE src/split_readvertise.c)
  # reset_reason.c от донгла не зависит, половинке он нужен тот же.
  zephyr_library_sources_ifdef(CONFIG_SWEEP_HALF_DEBUG_STATS src/half_stats.c src/reset_reason.c)
endif()
