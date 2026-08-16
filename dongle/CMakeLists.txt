# Модуль подключается ко ВСЕМ сборкам этого репозитория, включая половины
# клавиатуры, поэтому исходники цепляются только под своим symbol'ом.
if(CONFIG_SWEEP_DONGLE_UI)
  zephyr_library()
  # ZMK цепляет свой include/ только к таргету app (PRIVATE), внешним
  # библиотекам он не виден — а нам нужен zmk/display.h.
  zephyr_library_include_directories(${APPLICATION_SOURCE_DIR}/include)
  zephyr_library_sources(src/screen.c)
  zephyr_library_sources(src/host_proto.c)
  zephyr_library_sources_ifdef(CONFIG_SWEEP_DONGLE_HOST_LINK_CDC src/host_link.c)
  zephyr_library_sources_ifdef(CONFIG_SWEEP_DONGLE_HOST_LINK_GATT src/host_gatt.c)
endif()
