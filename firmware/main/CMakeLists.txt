idf_component_register(
    SRCS "main.c"
         "cue9_config.c"
         "cue9_wifi.c"
         "../src/raster.c" "../src/font.c" "../src/font_baked.c" "../src/pip_scene.c"
         "../src/ambient.c"
    INCLUDE_DIRS "." "../src"
    REQUIRES esp_lcd esp_timer driver esp_driver_i2c esp_wifi esp_netif esp-tls mbedtls json nvs_flash
)
