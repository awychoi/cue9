/* pip_live — Pip procedural renderer on the real ESP-VoCat.
 *
 * One 320-row body buffer (no seam through face or keyboard), a 40-row bottom
 * strip cleared to the same background colour, and a second-core scene builder
 * that runs while the panel DMA blocks. Every body write starts on the panel's
 * TE edge. Flash/RAM only. No eFuse operations.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <math.h>

#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "freertos/semphr.h"
#include "driver/gpio.h"
#include "driver/i2c_master.h"
#include "driver/spi_master.h"
#include "driver/usb_serial_jtag.h"
#include "esp_lcd_panel_io.h"
#include "esp_lcd_panel_ops.h"
#include "esp_lcd_st77916.h"
#include "esp_heap_caps.h"
#include "esp_timer.h"
#include "esp_attr.h"
#include "esp_system.h"
#include "esp_sleep.h"
#include "esp_log.h"

#include "raster.h"
#include "pip_scene.h"
#include "ambient.h"
#include "shake.h"
#include "stroke.h"
#include "cue9_config.h"
#include "cue9_wifi.h"
#include "bmi270_api.h"

#define TAG "PIPLIVE"
#define BODY_ROWS 360
#define STAGE_ROWS 90   /* internal DMA bounce for the PSRAM body */

#define PIN_PCLK   18
#define PIN_CS     14
#define PIN_D0     46
#define PIN_D1     13
#define PIN_D2     11
#define PIN_D3     12
#define PIN_RST     3
#define PIN_BL     44
#define PIN_PWR     9
#define PIN_TE      8   /* LCD_TE on the core board; ST77916 tearing-effect output */

#include "vendor_init.h"

static esp_lcd_panel_handle_t s_panel;
static esp_lcd_panel_io_handle_t s_io;
static r_dl s_dl;
static pip_scene s_scene;
static pip_opts s_opt;
static uint16_t *s_body;
static uint16_t *s_stage;
static volatile uint32_t s_done;

/* Panel tearing-effect (TE) sync. The ST77916 drives GPIO8 high at the start
 * of vertical blanking; a frame is only written after a fresh edge. */
static SemaphoreHandle_t s_te_sem;
static volatile uint32_t s_te_seq;
static volatile int64_t s_te_last_us;
static volatile int64_t s_te_period_us;
static volatile bool s_te_on;

static TaskHandle_t s_build_task;
static volatile bool s_build_done;
static volatile bool s_build_reset;
static volatile int s_build_state;
static volatile int s_build_page;
static volatile float s_build_t;
static volatile float s_build_dt;
static volatile int64_t s_build_us;

/* Demo agent count: 0..19 coloured keys. Replace with the real session count. */
static volatile int s_agent_count;

/* Local demo tour is explicit; boot and link loss show hub instead. */
static volatile bool s_demo;

#define BOOT_MAGIC 0xC09B0075u
#define LOW_BATT_MAGIC 0xC09B0002u
RTC_NOINIT_ATTR static uint32_t s_boot_magic;
RTC_NOINIT_ATTR static uint32_t s_boot_count;
RTC_NOINIT_ATTR static uint32_t s_low_batt_sleep;

/* USB command plane: the Mac plugin switches animation and agent count. */
static volatile bool s_remote;
static volatile int s_cmd_state;
static volatile uint32_t s_cmd_seq;
static volatile uint32_t s_refresh_seq;
static volatile int64_t s_last_cmd_us;

/* Runtime per-animation colours. A COLOR/BG command stages a pending colour;
 * the colour is committed only when that animation actually starts. */
static volatile uint32_t s_color_pending[PIP_NSTATE];
static volatile bool s_color_pending_set[PIP_NSTATE];
static uint32_t s_color_active[PIP_NSTATE];
static bool s_color_active_set[PIP_NSTATE];
static volatile uint32_t s_bg_pending[PIP_NSTATE];
static volatile bool s_bg_pending_set[PIP_NSTATE];
static uint32_t s_bg_active[PIP_NSTATE];
static bool s_bg_active_set[PIP_NSTATE];

/* Colours are session state: the plugin re-sends the full palette and
 * background set whenever the bridge connects. */

/* BQ27220 gauge snapshot, written by the gauge task, read by the builder. */
typedef struct {
    int soc;              /* % */
    int current_ma;       /* signed; positive = charging */
    int voltage_mv;
    uint16_t status;      /* BatteryStatus() */
    bool charging;        /* current above threshold, debounced, not full */
    bool full;            /* FC flag, or 99 % and no current */
    bool valid;
    uint8_t fail_count;   /* consecutive failed I2C reads; hold the last good value briefly */
} gauge_state;

static gauge_state s_gauge;
static portMUX_TYPE s_gauge_mux = portMUX_INITIALIZER_UNLOCKED;

/* One I2C0 master bus for the gauge, touch controller and IMU. The current
 * i2c_master driver serialises its own transactions, so no mutex is needed. */
static i2c_master_bus_handle_t s_i2c_bus;
static i2c_master_dev_handle_t s_gauge_dev;
static i2c_master_dev_handle_t s_touch_dev;

/* BMI270 at 0x68. Six alternating swings post a timestamp; the frame loop
 * turns that into a local dizzy scene. Absent IMU means this stays inert. */
static bmi270_handle_t s_bmi;
static volatile int64_t s_shake_us;
static shake_detector s_shake;
#define DIZZY_DEFAULT_US 6000000LL   /* three ~2 s wobble loops */
#define HAPPY_DEFAULT_US 2400000LL
#define CRITICAL_SOC 5

/* Runtime behaviour, set by the plugin's BEHAVIOUR line. Sensitivity 1..5
 * raises or lowers the dynamic-acceleration threshold. */
static volatile int64_t s_dizzy_us = DIZZY_DEFAULT_US;
static volatile int64_t s_happy_us = HAPPY_DEFAULT_US;

static volatile int64_t s_stroke_us;
static volatile float s_stroke_x;
#define STROKE_REFRESH_US 250000LL

#define CST816_ADDR 0x15
#define CST816_REG_POINTS 0x02
#define CST816_REG_CHIP_ID 0xA7
#define CST816_REG_DIS_AUTOSLEEP 0xFE
static volatile int s_touch_nav;   /* +1 next page, -1 previous, 0 none */

#define BQ27220_ADDR 0x55
#define REG_TEMPERATURE 0x06
#define REG_VOLTAGE 0x08
#define REG_BATTERY_STATUS 0x0A
#define REG_CURRENT 0x0C
#define REG_STATE_OF_CHARGE 0x2C

static esp_err_t bq_read16(uint8_t reg, uint16_t *out)
{
    uint8_t b[2];
    esp_err_t e = i2c_master_transmit_receive(s_gauge_dev, &reg, 1, b, 2, 50);
    if (e != ESP_OK) return e;
    *out = (uint16_t)b[0] | ((uint16_t)b[1] << 8);
    return ESP_OK;
}

/* A glitched BQ27220 read must not look like a flat cell. Reject zero volts,
 * a nonsensical SOC, or 0-5 % at a healthy pack voltage. */
static bool gauge_plausible(uint16_t soc, uint16_t volt)
{
    if (soc > 100) return false;
    if (volt < 2500 || volt > 4500) return false;
    if (soc <= CRITICAL_SOC && volt > 3800) return false;
    return true;
}

static void gauge_update(void)
{
    uint16_t soc = 0, cur = 0, volt = 0, status = 0;
    bool ok = (bq_read16(REG_STATE_OF_CHARGE, &soc) == ESP_OK) &&
              (bq_read16(REG_CURRENT, &cur) == ESP_OK) &&
              (bq_read16(REG_VOLTAGE, &volt) == ESP_OK) &&
              (bq_read16(REG_BATTERY_STATUS, &status) == ESP_OK);
    if (ok && !gauge_plausible(soc, volt)) {
        ESP_LOGW(TAG, "gauge reject soc=%d%% %dmV st=0x%04x",
                 (int)soc, (int)volt, (unsigned)status);
        ok = false;
    }
    if (ok) {
        int ma = (int)(int16_t)cur;
        bool fc = (status & (1u << 9)) != 0;      /* full-charged detected */
        bool dsg = (status & (1u << 0)) != 0;     /* discharging */
        bool full = fc || (soc >= 99 && ma <= 20);
        bool raw_chg = (ma > 20) && !full && !dsg;
        static int chg_count;
        chg_count = raw_chg ? chg_count + 1 : 0;
        portENTER_CRITICAL(&s_gauge_mux);
        s_gauge.soc = soc > 100 ? 100 : (int)soc;
        s_gauge.current_ma = ma;
        s_gauge.voltage_mv = (int)volt;
        s_gauge.status = status;
        s_gauge.full = full;
        s_gauge.charging = chg_count >= 2;
        s_gauge.valid = true;
        s_gauge.fail_count = 0;
        portEXIT_CRITICAL(&s_gauge_mux);
        ESP_LOGI(TAG, "gauge soc=%d%% %dmV %+dmA st=0x%04x chg=%d full=%d dsg=%d",
                 (int)soc, (int)volt, ma, (unsigned)status,
                 (int)s_gauge.charging, (int)full, (int)dsg);
    } else {
        uint8_t fails;
        portENTER_CRITICAL(&s_gauge_mux);
        /* A single failed poll is usually bus noise or a gauge wake-up; keep
         * the last good values on screen until the failure persists. */
        if (s_gauge.fail_count < 255) s_gauge.fail_count++;
        if (s_gauge.fail_count >= 10) s_gauge.valid = false;
        fails = s_gauge.fail_count;
        portEXIT_CRITICAL(&s_gauge_mux);
        ESP_LOGW(TAG, "gauge read failed (%u)", (unsigned)fails);
    }
}

static void gauge_task(void *arg)
{
    (void)arg;
    for (;;) {
        gauge_update();
        vTaskDelay(pdMS_TO_TICKS(2000));
    }
}

/* Core 0: BMI270 shake. Samples at the sensor's 100 Hz rate and feeds the
 * dynamic-acceleration detector: alternating swings trigger dizzy.
 * Gravity is removed first, so a shake counts in any direction and the
 * detector re-arms at each reversal instead of waiting for the device to
 * come to rest. */
static void imu_task(void *arg)
{
    (void)arg;
    struct bmi2_sens_data cur = { 0 };
    bool logged = false;
    int fails = 0;
    for (;;) {
        int8_t rslt = bmi2_get_sensor_data(&cur, s_bmi);
        if (rslt != BMI2_OK) {
            if (++fails == 20) {
                fails = 0;
                ESP_LOGW(TAG, "IMU read failed");
            }
            vTaskDelay(pdMS_TO_TICKS(10));
            continue;
        }
        fails = 0;
        if (cur.status & BMI2_DRDY_ACC) {
            int64_t now = esp_timer_get_time();
            if (!logged) {
                logged = true;
                ESP_LOGI(TAG, "IMU acc %d %d %d", (int)cur.acc.x, (int)cur.acc.y,
                         (int)cur.acc.z);
            }
            uint32_t swings_before = s_shake.swing_total;
            if (shake_feed(&s_shake, (int)cur.acc.x, (int)cur.acc.y,
                           (int)cur.acc.z, now)) {
                s_shake_us = now;
                ESP_LOGI(TAG, "shake trigger");
            } else if (s_shake.swing_total != swings_before) {
                ESP_LOGI(TAG, "shake swing %d", s_shake.swing_count);
            }
        }
        vTaskDelay(pdMS_TO_TICKS(10));
    }
}

static bool imu_init(void)
{
    if (s_i2c_bus == NULL) return false;
    esp_err_t e = bmi270_sensor_create_from_master_bus(
        s_i2c_bus, &s_bmi, bmi270_config_file,
        BMI2_GYRO_CROSS_SENS_ENABLE | BMI2_CRT_RTOSK_ENABLE);
    if (e != ESP_OK || s_bmi == NULL) {
        ESP_LOGW(TAG, "BMI270 init failed: %s", esp_err_to_name(e));
        s_bmi = NULL;
        return false;
    }
    const uint8_t sens[] = { BMI2_ACCEL };
    /* Make the shake threshold a known unit: 8192 counts per g. */
    struct bmi2_sens_config cfg = { .type = BMI2_ACCEL };
    if (bmi2_get_sensor_config(&cfg, 1, s_bmi) == BMI2_OK) {
        cfg.cfg.acc.odr = BMI2_ACC_ODR_100HZ;
        cfg.cfg.acc.range = BMI2_ACC_RANGE_4G;
        cfg.cfg.acc.bwp = BMI2_ACC_NORMAL_AVG4;
        cfg.cfg.acc.filter_perf = BMI2_PERF_OPT_MODE;
        bmi2_set_sensor_config(&cfg, 1, s_bmi);
    }
    if (bmi2_sensor_enable(sens, 1, s_bmi) != BMI2_OK) {
        ESP_LOGW(TAG, "BMI270 accel enable failed");
        return false;
    }
    ESP_LOGI(TAG, "BMI270 ready");
    return true;
}

static esp_err_t touch_read(uint8_t reg, uint8_t *buf, size_t len)
{
    return i2c_master_transmit_receive(s_touch_dev, &reg, 1, buf, len, 20);
}

static esp_err_t touch_write(uint8_t reg, uint8_t value)
{
    uint8_t b[2] = { reg, value };
    return i2c_master_transmit(s_touch_dev, b, sizeof(b), 20);
}

/* The CST816S enters standby after 2 s idle and then NACKs its address until
 * a touch wakes it, so a polled read can never see the finger leave. The panel
 * reset shares its line: configure it right after the panel comes up, while
 * the controller is still awake. Disabling auto-sleep costs ~1.6 mA. */
static bool touch_init(void)
{
    if (s_touch_dev == NULL) return false;
    vTaskDelay(pdMS_TO_TICKS(30));
    esp_err_t e = ESP_FAIL;
    for (int i = 0; i < 8; i++) {
        e = touch_write(CST816_REG_DIS_AUTOSLEEP, 0x01);
        if (e == ESP_OK) break;
        vTaskDelay(pdMS_TO_TICKS(20));
    }
    if (e != ESP_OK) {
        ESP_LOGW(TAG, "touch wake failed: %s", esp_err_to_name(e));
        return false;
    }
    uint8_t id = 0;
    if (touch_read(CST816_REG_CHIP_ID, &id, 1) == ESP_OK) {
        ESP_LOGI(TAG, "touch ready id=0x%02x", id);
    } else {
        ESP_LOGI(TAG, "touch ready");
    }
    return true;
}

/* Core 0: CST816S touch. Polls points and x/y; a deliberate back-and-forth
 * rub (stroke.c) posts happy, while a page flick still steps a page. */
static void touch_task(void *arg)
{
    (void)arg;
    if (s_touch_dev == NULL) {
        ESP_LOGW(TAG, "touch device unavailable");
        vTaskDelete(NULL);
        return;
    }
    bool down = false;
    bool stroking = false;
    int x0 = 0, y0 = 0, x1 = 0, y1 = 0;
    int64_t last_stroke_us = 0;
    stroke_detector rub;
    stroke_init(&rub);
    bool logged = false;
    for (;;) {
        uint8_t b[5];
        esp_err_t e = touch_read(CST816_REG_POINTS, b, sizeof(b));
        if (e == ESP_OK) {
            int pts = b[0] & 0x0f;
            int x = ((b[1] & 0x0f) << 8) | b[2];
            int y = ((b[3] & 0x0f) << 8) | b[4];
            int64_t now = esp_timer_get_time();
            if (pts > 0) {
                if (!down) {
                    down = true;
                    stroking = false;
                    last_stroke_us = 0;
                    x0 = x1 = x;
                    y0 = y1 = y;
                    stroke_down(&rub, x, y, now);
                } else if (stroke_feed(&rub, x, y, now)) {
                    /* A continued rub keeps happy alive. Do not rewrite the
                     * timestamp on every 30 ms poll, and let happy fade if
                     * the finger stops moving. */
                    stroking = true;
                    if (last_stroke_us == 0 ||
                        now - last_stroke_us >= STROKE_REFRESH_US) {
                        bool first = last_stroke_us == 0;
                        last_stroke_us = now;
                        s_stroke_x = (float)(x - 180) / 180.f;
                        s_stroke_us = now;
                        if (first) ESP_LOGI(TAG, "stroke (%d,%d)", x, y);
                    }
                }
                x1 = x;
                y1 = y;
                if (!logged) {
                    logged = true;
                    ESP_LOGI(TAG, "touch works (%d,%d)%s", x, y, pts > 1 ? " multi" : "");
                }
            } else if (down) {
                down = false;
                stroke_up(&rub);
                int dx = x1 - x0, dy = y1 - y0;
                if (stroking) {
                    ESP_LOGI(TAG, "stroke end (%d,%d)", x1, y1);
                } else if (abs(dx) >= 40 && abs(dx) > abs(dy)) {
                    s_touch_nav = dx < 0 ? 1 : -1;
                    ESP_LOGI(TAG, "swipe %s (%d,%d)->(%d,%d)", dx < 0 ? "next" : "prev",
                             x0, y0, x1, y1);
                } else {
                    ESP_LOGI(TAG, "tap (%d,%d)", x1, y1);
                }
            }
        }
        vTaskDelay(pdMS_TO_TICKS(30));
    }
}

static void gauge_get(gauge_state *g)
{
    portENTER_CRITICAL(&s_gauge_mux);
    *g = s_gauge;
    portEXIT_CRITICAL(&s_gauge_mux);
}

static bool i2c_devices_init(void)
{
    i2c_master_bus_config_t bus_cfg = {
        .i2c_port = I2C_NUM_0,
        .sda_io_num = 2,
        .scl_io_num = 1,
        .clk_source = I2C_CLK_SRC_DEFAULT,
        .glitch_ignore_cnt = 7,
        .flags.enable_internal_pullup = true,
    };
    i2c_device_config_t dev_cfg = {
        .dev_addr_length = I2C_ADDR_BIT_LEN_7,
        .scl_speed_hz = 400000,
    };
    if (i2c_new_master_bus(&bus_cfg, &s_i2c_bus) != ESP_OK) {
        ESP_LOGE(TAG, "I2C bus init failed");
        s_i2c_bus = NULL;
        return false;
    }
    dev_cfg.device_address = BQ27220_ADDR;
    if (i2c_master_bus_add_device(s_i2c_bus, &dev_cfg, &s_gauge_dev) != ESP_OK) {
        ESP_LOGE(TAG, "gauge device add failed");
        return false;
    }
    dev_cfg.device_address = CST816_ADDR;
    if (i2c_master_bus_add_device(s_i2c_bus, &dev_cfg, &s_touch_dev) != ESP_OK) {
        ESP_LOGW(TAG, "touch device add failed");
        s_touch_dev = NULL;
    }
    return true;
}

static void gauge_init(void)
{
    if (!i2c_devices_init()) return;
    memset(&s_gauge, 0, sizeof(s_gauge));
    /* A single read after deep sleep can still carry the last charging
     * current. Take a few fresh samples so the debounced charging flag is
     * real before the boot guard decides whether to sleep. */
    for (int i = 0; i < 4; i++) {
        gauge_update();
        if (i < 3) vTaskDelay(pdMS_TO_TICKS(150));
    }
    xTaskCreatePinnedToCore(gauge_task, "gauge", 4096, NULL, 3, NULL, 0);
}

/* Below this the cell cannot safely carry the panel and Wi-Fi. Booting anyway
 * gives a brown-out reboot loop when USB power disappears (the KVM case);
 * sleep instead and wake every 30 s to see whether the charger is back. */
static bool battery_critical(const gauge_state *g)
{
    if (!g->valid) return false;
    if (g->soc > CRITICAL_SOC) return false;
    /* A healthy pack voltage cannot belong to a flat cell. This rejects a
     * corrupt SOC read (0 % at 4.1 V) before it can black out the screen. */
    if (g->voltage_mv > 3800) return false;
    if (g->charging || g->current_ma > 20) return false;
    return true;
}

static void low_battery_sleep(const gauge_state *g)
{
    ESP_LOGW(TAG, "battery critical: soc=%d%% %dmV %+dmA; sleep 30 s",
             g->soc, g->voltage_mv, g->current_ma);
    /* Remember why we slept: after a low-battery wake, stay dark until the
     * charger is seen or the gauge has clearly recovered. Otherwise a 6–10 %
     * reading would boot the panel and Wi-Fi again every 30 s. */
    s_low_batt_sleep = LOW_BATT_MAGIC;
    /* Drop the panel rail and backlight before sleeping: at this SOC the boot
     * load is what turns one reset into a loop. */
    gpio_config_t bl = { .pin_bit_mask = 1ULL << PIN_BL, .mode = GPIO_MODE_OUTPUT };
    gpio_config(&bl);
    gpio_set_level(PIN_BL, 0);
    gpio_config_t pwr = { .pin_bit_mask = 1ULL << PIN_PWR, .mode = GPIO_MODE_OUTPUT };
    gpio_config(&pwr);
    gpio_set_level(PIN_PWR, 1);
    esp_sleep_enable_timer_wakeup(30ULL * 1000ULL * 1000ULL);
    esp_deep_sleep_start();
}

static bool on_color_done(esp_lcd_panel_io_handle_t io, esp_lcd_panel_io_event_data_t *edata,
                          void *ctx)
{
    (void)io; (void)edata; (void)ctx;
    s_done++;
    return false;
}

static void IRAM_ATTR te_isr(void *arg)
{
    (void)arg;
    int64_t now = esp_timer_get_time();
    int64_t d = now - s_te_last_us;
    if (d > 3000 && d < 100000) s_te_period_us = d;
    s_te_last_us = now;
    s_te_seq++;
    BaseType_t hp = pdFALSE;
    xSemaphoreGiveFromISR(s_te_sem, &hp);
    portYIELD_FROM_ISR(hp);
}

/* Return true when the caller is at the start of a TE pulse. If the last edge
 * is old, block for the next one; if it just fired, use it rather than losing
 * a whole panel field. On timeout, fall back to free-run writes. */
static bool te_wait(void)
{
    if (!s_te_on) return false;
    uint32_t seq = s_te_seq;
    int64_t now = esp_timer_get_time();
    if (now - s_te_last_us > 2500) {
        while (s_te_seq == seq) {
            if (xSemaphoreTake(s_te_sem, pdMS_TO_TICKS(100)) != pdTRUE) {
                s_te_on = false;
                ESP_LOGW(TAG, "TE timeout on GPIO%d, free-run", PIN_TE);
                return false;
            }
        }
    }
    while (xSemaphoreTake(s_te_sem, 0) == pdTRUE) { }
    return true;
}

static bool te_init(void)
{
    s_te_sem = xSemaphoreCreateBinary();
    if (!s_te_sem) return false;

    gpio_config_t io = {
        .pin_bit_mask = 1ULL << PIN_TE,
        .mode = GPIO_MODE_INPUT,
        .pull_up_en = GPIO_PULLUP_DISABLE,
        .pull_down_en = GPIO_PULLDOWN_ENABLE,
        .intr_type = GPIO_INTR_POSEDGE,
    };
    if (gpio_config(&io) != ESP_OK) return false;
    esp_err_t e = gpio_install_isr_service(0);
    if (e != ESP_OK && e != ESP_ERR_INVALID_STATE) {
        ESP_LOGE(TAG, "gpio isr init: %s", esp_err_to_name(e));
        return false;
    }
    e = gpio_isr_handler_add(PIN_TE, te_isr, NULL);
    if (e != ESP_OK) {
        ESP_LOGE(TAG, "TE isr add: %s", esp_err_to_name(e));
        return false;
    }

    /* 0x35 TEON, mode 0: pulse on V-blanking only. QSPI commands use the
     * same 32-bit opcode/cmd framing as the ST77916 driver (0x02 0x35 0x00 0x00). */
    uint8_t mode = 0;
    int teon = (0x02 << 24) | (0x35 << 8);
    e = esp_lcd_panel_io_tx_param(s_io, teon, &mode, 1);
    if (e != ESP_OK) {
        ESP_LOGE(TAG, "TEON failed: %s", esp_err_to_name(e));
        return false;
    }

    s_te_last_us = esp_timer_get_time();
    if (xSemaphoreTake(s_te_sem, pdMS_TO_TICKS(200)) != pdTRUE) {
        ESP_LOGW(TAG, "no TE edges on GPIO%d; free-run", PIN_TE);
        gpio_isr_handler_remove(PIN_TE);
        return false;
    }
    s_te_on = true;
    ESP_LOGI(TAG, "TE sync on GPIO%d", PIN_TE);
    return true;
}

static void board_power_and_backlight(void)
{
    gpio_config_t pwr = { .pin_bit_mask = 1ULL << PIN_PWR, .mode = GPIO_MODE_OUTPUT };
    ESP_ERROR_CHECK(gpio_config(&pwr));
    gpio_set_level(PIN_PWR, 0);
    vTaskDelay(pdMS_TO_TICKS(20));

    gpio_config_t bl = { .pin_bit_mask = 1ULL << PIN_BL, .mode = GPIO_MODE_OUTPUT };
    ESP_ERROR_CHECK(gpio_config(&bl));
    gpio_set_level(PIN_BL, 1);
}

static void panel_init(void)
{
    spi_bus_config_t bus = {
        .data0_io_num = PIN_D0,
        .data1_io_num = PIN_D1,
        .data2_io_num = PIN_D2,
        .data3_io_num = PIN_D3,
        .sclk_io_num = PIN_PCLK,
        .max_transfer_sz = 360 * 360 * sizeof(uint16_t),
    };
    ESP_ERROR_CHECK(spi_bus_initialize(SPI2_HOST, &bus, SPI_DMA_CH_AUTO));

    esp_lcd_panel_io_spi_config_t io_cfg = {
        .cs_gpio_num = PIN_CS,
        .dc_gpio_num = GPIO_NUM_NC,
        .spi_mode = 0,
                .pclk_hz = 40 * 1000 * 1000,
        .trans_queue_depth = 10,
        .lcd_cmd_bits = 32,
        .lcd_param_bits = 8,
        .flags.quad_mode = true,
    };
    ESP_ERROR_CHECK(esp_lcd_new_panel_io_spi((esp_lcd_spi_bus_handle_t)SPI2_HOST, &io_cfg, &s_io));
    esp_lcd_panel_io_callbacks_t cbs = { .on_color_trans_done = on_color_done };
    ESP_ERROR_CHECK(esp_lcd_panel_io_register_event_callbacks(s_io, &cbs, NULL));

    st77916_vendor_config_t vendor = {
        .init_cmds = vendor_specific_init_yysj,
        .init_cmds_size = sizeof(vendor_specific_init_yysj) / sizeof(st77916_lcd_init_cmd_t),
        .flags.use_qspi_interface = 1,
    };
    esp_lcd_panel_dev_config_t cfg = {
        .reset_gpio_num = PIN_RST,
        .rgb_ele_order = LCD_RGB_ELEMENT_ORDER_RGB,
        .bits_per_pixel = 16,
        .flags.reset_active_high = 0,
        .vendor_config = &vendor,
    };
    ESP_ERROR_CHECK(esp_lcd_new_panel_st77916(s_io, &cfg, &s_panel));
    ESP_ERROR_CHECK(esp_lcd_panel_reset(s_panel));
    ESP_ERROR_CHECK(esp_lcd_panel_init(s_panel));
    ESP_ERROR_CHECK(esp_lcd_panel_disp_on_off(s_panel, true));
    ESP_ERROR_CHECK(esp_lcd_panel_swap_xy(s_panel, false));
    ESP_ERROR_CHECK(esp_lcd_panel_mirror(s_panel, false, false));
}

/* Battery glyph from the real BQ27220. No on-screen text: five SOC segments,
 * green above 3 bars, yellow at 3/2, red at 1/0; the shell and tip take the
 * same colour as the bars so an almost-empty battery still reads as red rather
 * than an empty grey outline. Bolt only while charging. */
static void draw_battery(r_dl *dl, const gauge_state *g, float by)
{
    const float bx = 180.0f;
    int soc = g->valid ? g->soc : 0;
    if (soc < 0) soc = 0;
    if (soc > 100) soc = 100;
    int lit = (soc + 10) / 20;
    if (lit < 0) lit = 0;
    if (lit > 5) lit = 5;
    /* A valid battery is never drawn as an empty shell: 0–9 % keeps one red
     * bar. Unknown stays empty and dim, so a failed I2C read is distinct. */
    if (g->valid && lit < 1) lit = 1;
    r_rgb dim = { 28, 44, 40 };
    r_rgb ink;
    if (lit <= 1) ink = (r_rgb){ 237, 121, 119 };       /* red: 1 or 0 bars */
    else if (lit <= 3) ink = (r_rgb){ 231, 194, 101 };   /* yellow: 3 or 2 */
    else ink = (r_rgb){ 106, 206, 145 };                 /* green: 5 or 4 */
    r_rgb shell = g->valid ? ink : dim;
    r_load_identity(dl);
    r_set_alpha(dl, 255);
    r_set_glow(dl, 0);
    r_set_color(dl, shell);
    r_fill_rrect(dl, bx - 22, by - 8, 44, 16, 5);
    r_set_color(dl, dl->pal.bg);
    r_fill_rrect(dl, bx - 20, by - 6, 40, 12, 4);
    r_set_color(dl, shell);
    r_fill_rrect(dl, bx + 22, by - 3, 4, 6, 1);
    if (g->valid) {
        r_set_color(dl, ink);
        for (int i = 0; i < lit; i++)
            r_fill_rrect(dl, bx - 17 + i * 7, by - 4, 5, 8, 1.5f);
    }
    if (g->valid && g->charging) {
        const float bolt[12] = {
            bx + 3, by - 13,
            bx - 7, by - 1,
            bx - 1, by - 1,
            bx - 4, by + 11,
            bx + 8, by - 3,
            bx + 2, by - 3
        };
        r_set_color(dl, (r_rgb){ 255, 226, 120 });
        r_fill_poly(dl, bolt, 6);
    }
}

static int state_index(const char *name)
{
    for (int i = 0; i < PIP_NSTATE; i++) {
        if (strcmp(name, pip_state_names[i]) == 0) return i;
    }
    return -1;
}

static void color_commit(int state)
{
    if (state < 0 || state >= PIP_NSTATE) return;
    if (s_color_pending_set[state]) {
        s_color_active[state] = s_color_pending[state];
        s_color_active_set[state] = true;
        s_color_pending_set[state] = false;
    }
    if (s_bg_pending_set[state]) {
        s_bg_active[state] = s_bg_pending[state];
        s_bg_active_set[state] = true;
        s_bg_pending_set[state] = false;
    }
}

static void color_bind(int state)
{
    if (state >= 0 && state < PIP_NSTATE && s_color_active_set[state]) {
        s_opt.has_color = true;
        s_opt.color = (r_rgb){
            (uint8_t)((s_color_active[state] >> 16) & 0xff),
            (uint8_t)((s_color_active[state] >> 8) & 0xff),
            (uint8_t)(s_color_active[state] & 0xff),
        };
    } else {
        s_opt.has_color = false;
    }
    if (state >= 0 && state < PIP_NSTATE && s_bg_active_set[state]) {
        s_opt.has_bg = true;
        s_opt.bg = (r_rgb){
            (uint8_t)((s_bg_active[state] >> 16) & 0xff),
            (uint8_t)((s_bg_active[state] >> 8) & 0xff),
            (uint8_t)(s_bg_active[state] & 0xff),
        };
    } else {
        s_opt.has_bg = false;
    }
}

/* Ambient pages. The Pi (or a Mac on USB) pushes wall-clock time and weather.
 * These lines are data, not agent state: they deliberately skip the Mac
 * liveness clock below, or the hub fallback would never fire. */
static portMUX_TYPE s_amb_mux = portMUX_INITIALIZER_UNLOCKED;
static int64_t s_time_epoch;      /* UTC seconds at sync */
static int64_t s_time_sync_us;    /* esp_timer_get_time() at sync */
static int32_t s_time_tz_min;
static int32_t s_time_fmt24;
static bool s_time_set;
static amb_wx s_wx;

static volatile int s_page_cmd = -1;      /* PAGE n from the host */
static volatile uint32_t s_page_cmd_seq;

static bool parse_ll(const char **pp, long long *out)
{
    char *end = NULL;
    long long v = strtoll(*pp, &end, 10);
    if (end == *pp) return false;
    *pp = end;
    *out = v;
    return true;
}

static void handle_time(char *args)
{
    const char *p = args;
    long long epoch = 0, off = 0, fmt = 12;
    if (!parse_ll(&p, &epoch) || !parse_ll(&p, &off)) {
        ESP_LOGW(TAG, "bad time line");
        return;
    }
    if (!parse_ll(&p, &fmt)) fmt = 12;
    if (fmt != 24) fmt = 12;
    int64_t now = esp_timer_get_time();
    portENTER_CRITICAL(&s_amb_mux);
    s_time_epoch = (int64_t)epoch;
    s_time_sync_us = now;
    s_time_tz_min = (int32_t)off;
    s_time_fmt24 = (fmt == 24);
    s_time_set = true;
    portEXIT_CRITICAL(&s_amb_mux);
    static int64_t last_log;
    if (now - last_log > 60000000LL) {
        last_log = now;
        ESP_LOGI(TAG, "time %lld tz=%lld fmt=%lld", epoch, off, fmt);
    }
}

/* WX <icon>|<temp>|<hi>|<lo>|<feels>|<CITY> */
static void handle_wx(char *args)
{
    amb_wx w;
    amb_wx_default(&w);
    char *save = NULL;
    char *tok = strtok_r(args, "|", &save);
    int v[4] = { 0, 0, 0, 0 };
    const char *city = "";
    if (tok == NULL) return;
    if (strcmp(tok, "sunny") == 0) w.code = AMB_SUNNY;
    else if (strcmp(tok, "rain") == 0) w.code = AMB_RAIN;
    else if (strcmp(tok, "snow") == 0) w.code = AMB_SNOW;
    else w.code = AMB_PARTLY;
    for (int i = 0; i < 4; i++) {
        tok = strtok_r(NULL, "|", &save);
        if (tok == NULL) return;
        v[i] = atoi(tok);
        if (v[i] < -99) v[i] = -99;
        if (v[i] > 199) v[i] = 199;
    }
    tok = strtok_r(NULL, "|", &save);
    if (tok != NULL && tok[0] != 0 && tok[1] == 0
        && (tok[0] == 'F' || tok[0] == 'C')) {
        w.unit = tok[0];
        tok = strtok_r(NULL, "|", &save);
    }
    if (tok != NULL) city = tok;
    w.valid = true;
    w.temp = v[0];
    w.hi = v[1];
    w.lo = v[2];
    w.feels = v[3];
    snprintf(w.city, sizeof(w.city), "%s", city);
    portENTER_CRITICAL(&s_amb_mux);
    s_wx = w;
    portEXIT_CRITICAL(&s_amb_mux);
    ESP_LOGI(TAG, "wx %d/%d/%d %d %c \"%s\"", w.code, w.temp, w.hi,
             w.feels, w.unit, w.city);
}

static bool amb_clock_now(amb_clock *out)
{
    int64_t epoch, sync;
    int32_t tz, fmt;
    bool set;
    portENTER_CRITICAL(&s_amb_mux);
    epoch = s_time_epoch;
    sync = s_time_sync_us;
    tz = s_time_tz_min;
    fmt = s_time_fmt24;
    set = s_time_set;
    portEXIT_CRITICAL(&s_amb_mux);
    amb_clock_default(out);
    if (!set) return false;
    int64_t now = esp_timer_get_time();
    out->local_epoch = epoch + (now - sync) / 1000000LL + (int64_t)tz * 60;
    out->fmt24 = fmt;
    return true;
}

static void amb_wx_get(amb_wx *out)
{
    portENTER_CRITICAL(&s_amb_mux);
    *out = s_wx;
    portEXIT_CRITICAL(&s_amb_mux);
}

static const char *state_status_label(int state)
{
    switch (state) {
    case PIP_APPROVAL: return "APPROVAL NEEDED";
    case PIP_MCQ:      return "QUESTION WAITING";
    case PIP_HUB:      return "NO LINK";
    case PIP_OFFLINE:  return "OFFLINE";
    case PIP_SLEEP:
    case PIP_IDLE:     return "AGENT IDLE";
    case PIP_THINKING: return "THINKING";
    case PIP_READ:     return "READING";
    case PIP_SEARCH:   return "SEARCHING";
    case PIP_WAIT:     return "WAITING";
    case PIP_CURIOUS:  return "CURIOUS";
    case PIP_WAKE:     return "WAKING";
    case PIP_DONE:     return "DONE";
    case PIP_RETRY:    return "RETRYING";
    default:           return "AGENT WORKING";
    }
}

static r_rgb state_status_ink(int state)
{
    switch (state) {
    case PIP_APPROVAL: return (r_rgb){ 241, 189, 104 };
    case PIP_MCQ:      return (r_rgb){ 255, 145, 184 };
    case PIP_WAIT:
    case PIP_RETRY:    return (r_rgb){ 228, 187, 122 };
    case PIP_DONE:     return (r_rgb){ 165, 230, 155 };
    case PIP_CURIOUS:  return (r_rgb){ 189, 164, 245 };
    case PIP_HUB:
    case PIP_OFFLINE:  return (r_rgb){ 147, 165, 177 };
    case PIP_SLEEP:
    case PIP_IDLE:     return (r_rgb){ 144, 223, 209 };
    default:           return (r_rgb){ 100, 224, 236 };
    }
}

/* One line parser for USB and Wi-Fi. It runs on whichever transport task
 * received the line, so a COLOR and an ANIM never interleave. Returns a reply
 * ("PONG") or NULL. */
const char *cue9_handle_line(char *line)
{
    if (strncmp(line, "TIME ", 5) == 0) {
        handle_time(line + 5);
        return NULL;
    }
    if (strncmp(line, "WX ", 3) == 0) {
        handle_wx(line + 3);
        return NULL;
    }
    s_last_cmd_us = esp_timer_get_time();
    if (strncmp(line, "COLOR ", 6) == 0) {
        char *name = line + 6;
        char *hex = strchr(name, ' ');
        if (hex != NULL) {
            *hex++ = 0;
            int idx = state_index(name);
            char *end = NULL;
            unsigned long value = strtoul(hex, &end, 16);
            if (idx >= 0 && end != hex && *end == 0 && value <= 0xffffffUL) {
                s_color_pending[idx] = (uint32_t)value;
                s_color_pending_set[idx] = true;
                ESP_LOGD(TAG, "cmd color %s #%06lx", name, value);
            } else {
                ESP_LOGW(TAG, "cmd bad color %s %s", name, hex);
            }
        } else {
            ESP_LOGW(TAG, "cmd color missing value");
        }
        return NULL;
    }
    if (strncmp(line, "BG ", 3) == 0) {
        char *name = line + 3;
        char *hex = strchr(name, ' ');
        if (hex != NULL) {
            *hex++ = 0;
            int idx = state_index(name);
            char *end = NULL;
            unsigned long value = strtoul(hex, &end, 16);
            if (idx >= 0 && end != hex && *end == 0 && value <= 0xffffffUL) {
                s_bg_pending[idx] = (uint32_t)value;
                s_bg_pending_set[idx] = true;
                ESP_LOGD(TAG, "cmd bg %s #%06lx", name, value);
            } else {
                ESP_LOGW(TAG, "cmd bad bg %s %s", name, hex);
            }
        } else {
            ESP_LOGW(TAG, "cmd bg missing value");
        }
        return NULL;
    }
    if (strncmp(line, "ANIM ", 5) == 0) {
        int idx = state_index(line + 5);
        if (idx >= 0) {
            s_cmd_state = idx;
            s_remote = true;
            s_demo = false;
            s_cmd_seq++;
            ESP_LOGI(TAG, "cmd anim=%s", pip_state_names[idx]);
        } else {
            ESP_LOGW(TAG, "cmd bad anim %s", line + 5);
        }
    } else if (strncmp(line, "PAGE ", 5) == 0) {
        int v = atoi(line + 5);
        if (v >= 0 && v <= 2) {
            s_page_cmd = v;
            s_page_cmd_seq++;
            ESP_LOGI(TAG, "cmd page=%d", v);
        }
    } else if (strncmp(line, "AGENTS ", 7) == 0) {
        int v = atoi(line + 7);
        if (v < 0) v = 0;
        if (v > 19) v = 19;
        s_agent_count = v;
        ESP_LOGI(TAG, "cmd agents=%d", v);
    } else if (strcmp(line, "REFRESH") == 0) {
        s_refresh_seq++;
        ESP_LOGI(TAG, "cmd refresh");
    } else if (strcmp(line, "DEMO") == 0) {
        s_remote = false;
        s_demo = true;
        ESP_LOGI(TAG, "cmd demo");
    } else if (strcmp(line, "DIZZY") == 0) {
        /* Same path as a shake; useful for checking the page return. */
        s_shake_us = esp_timer_get_time();
        ESP_LOGI(TAG, "cmd dizzy");
    } else if (strcmp(line, "STROKE") == 0) {
        /* Same path as a screen stroke; useful for checking the page return. */
        s_stroke_x = 0.f;
        s_stroke_us = esp_timer_get_time();
        ESP_LOGI(TAG, "cmd stroke");
    } else if (strncmp(line, "BEHAVIOUR ", 10) == 0) {
        const char *bp = line + 10;
        long long level_ll = 0, dizzy_ll = 0, happy_ll = 0;
        if (parse_ll(&bp, &level_ll) && parse_ll(&bp, &dizzy_ll) &&
            parse_ll(&bp, &happy_ll)) {
            int level = (int)level_ll;
            long dizzy_ms = (long)dizzy_ll;
            long happy_ms = (long)happy_ll;
            if (level < 1) level = 1;
            if (level > 5) level = 5;
            if (dizzy_ms < 1000) dizzy_ms = 1000;
            if (dizzy_ms > 15000) dizzy_ms = 15000;
            if (happy_ms < 800) happy_ms = 800;
            if (happy_ms > 8000) happy_ms = 8000;
            shake_set_sensitivity(&s_shake, level);
            s_dizzy_us = (int64_t)dizzy_ms * 1000;
            s_happy_us = (int64_t)happy_ms * 1000;
            ESP_LOGI(TAG, "behaviour level=%d dizzy=%ldms happy=%ldms", level,
                     dizzy_ms, happy_ms);
        } else {
            ESP_LOGW(TAG, "cmd bad behaviour");
        }
    } else if (strcmp(line, "ALIVE") == 0) {
        /* heartbeat only; the timestamp was advanced above */
    } else if (strcmp(line, "PING") == 0) {
        return "PONG";
    } else {
        ESP_LOGW(TAG, "cmd unknown %s", line);
    }
    return NULL;
}

/* Core 0: USB-Serial-JTAG console. */
static void cmd_task(void *arg)
{
    (void)arg;
    usb_serial_jtag_driver_config_t cfg = {
        .rx_buffer_size = 512,
        .tx_buffer_size = 512,
    };
    ESP_ERROR_CHECK(usb_serial_jtag_driver_install(&cfg));
    char line[96];
    int n = 0;
    for (;;) {
        uint8_t c;
        int r = usb_serial_jtag_read_bytes(&c, 1, pdMS_TO_TICKS(100));
        if (r == 1) {
            if (c == '\n' || c == '\r') {
                line[n] = 0;
                if (n > 0) {
                    const char *reply = cue9_handle_line(line);
                    if (reply != NULL) {
                        printf("%s\n", reply);
                        fflush(stdout);
                    }
                }
                n = 0;
            } else if (n < (int)sizeof(line) - 1) {
                line[n++] = (char)c;
            }
        } else {
            vTaskDelay(pdMS_TO_TICKS(10));
        }
    }
}

/* Core 0: silence USB console logging when no host is attached. A missing
 * host must not let a log write stall the frame loop or trip the watchdog. */
static void log_gate_task(void *arg)
{
    (void)arg;
    bool prev = true;
    for (;;) {
        bool connected = usb_serial_jtag_is_connected() || cue9_wifi_is_connected();
        if (connected != prev) {
            esp_log_level_set("*", connected ? ESP_LOG_INFO : ESP_LOG_NONE);
            /* Polled touch reads would NACK on every attempt if the controller
             * stopped responding; keep that noise out of the console. */
            esp_log_level_set("i2c.master", ESP_LOG_NONE);
            prev = connected;
        }
        vTaskDelay(pdMS_TO_TICKS(250));
    }
}

/* Core 1: build the next display list while core 0 is blocked in panel DMA. */
static void draw_and_wait(int x0, int y0, int x1, int y1, const uint16_t *src) {
    uint32_t before = s_done;
    esp_err_t err = esp_lcd_panel_draw_bitmap(s_panel, x0, y0, x1, y1, src);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "draw %d..%d failed: %s", y0, y1, esp_err_to_name(err));
        return;
    }
    int64_t start = esp_timer_get_time();
    while (s_done == before) {
        if (esp_timer_get_time() - start > 200000) {
            ESP_LOGE(TAG, "draw %d..%d timed out", y0, y1);
            return;
        }
    }
}

/* TE-locked body write. The body lives in PSRAM, which the panel SPI DMA
 * cannot read, so each band is copied to a small internal stage first. */
static void flush_body(void) {
    te_wait();
    for (int y = 0; y < BODY_ROWS; y += STAGE_ROWS) {
        int rows = BODY_ROWS - y;
        if (rows > STAGE_ROWS) rows = STAGE_ROWS;
        memcpy(s_stage, s_body + (size_t)y * 360, (size_t)rows * 360 * sizeof(uint16_t));
        draw_and_wait(0, y, 360, y + rows, s_stage);
    }
}

static void build_worker(void *arg)
{
    (void)arg;
    for (;;) {
        ulTaskNotifyTake(pdTRUE, portMAX_DELAY);
        if (s_build_reset) pip_scene_reset(&s_scene);
        s_opt.agents = s_agent_count;
        r_dl_reset(&s_dl);
        int64_t a = esp_timer_get_time();
        float anim_t = (float)((double)a / 1000000.0);
        if (s_build_page == AMB_PAGE_LIVE) {
            pip_scene_frame(&s_dl, &s_scene, s_build_state, s_build_t, s_build_dt, &s_opt);
        } else if (s_build_page == AMB_PAGE_CLOCK) {
            amb_clock clk;
            amb_wx wx;
            bool have = amb_clock_now(&clk);
            amb_wx_get(&wx);
            amb_clock_frame(&s_dl, &clk, have, &wx, state_status_label(s_build_state),
                            state_status_ink(s_build_state), AMB_PAGE_CLOCK, anim_t);
        } else {
            amb_wx wx;
            amb_wx_get(&wx);
            amb_weather_frame(&s_dl, &wx, AMB_PAGE_WEATHER, anim_t);
        }
        gauge_state g;
        gauge_get(&g);
        /* The clock's ring owns the top edge, so its battery sits inside the
         * ring. Weather's city label owns that space, so it goes bare. */
        if (s_build_page != AMB_PAGE_WEATHER) {
            draw_battery(&s_dl, &g, s_build_page == AMB_PAGE_CLOCK ? 44.0f : 22.0f);
        }
        s_build_us = esp_timer_get_time() - a;
        s_build_done = true;
    }
}

static void wait_build(void)
{
    while (!s_build_done) {
        vTaskDelay(1);
    }
}

void app_main(void)
{
    /* Touch is polled; if the controller ever stops ACKing, the i2c driver
     * would log an ERROR on every 30 ms attempt. Keep it quiet and report
     * our own touch failures instead. */
    esp_log_level_set("i2c.master", ESP_LOG_NONE);
    esp_reset_reason_t rr = esp_reset_reason();
    if (s_boot_magic != BOOT_MAGIC) {
        s_boot_magic = BOOT_MAGIC;
        s_boot_count = 0;
    }
    s_boot_count++;
    ESP_LOGI(TAG, "reset=%d boot=%u", (int)rr, (unsigned)s_boot_count);
    ESP_LOGI(TAG, "boot heap internal=%u psram=%u",
             (unsigned)heap_caps_get_free_size(MALLOC_CAP_INTERNAL),
             (unsigned)heap_caps_get_free_size(MALLOC_CAP_SPIRAM));

    /* Read the gauge before powering the panel: a nearly empty cell must not
     * be asked to carry a full boot only to brown out and reboot. */
    gauge_init();
    gauge_state boot_gauge;
    gauge_get(&boot_gauge);
    bool low_batt_wake = s_low_batt_sleep == LOW_BATT_MAGIC;
    if (battery_critical(&boot_gauge)) low_battery_sleep(&boot_gauge);
    if (low_batt_wake) {
        /* Keep the panel and Wi-Fi off across the 30 s retry wakes until the
         * charger appears or the gauge is comfortably above the cutoff. */
        if (boot_gauge.charging || boot_gauge.soc > 10) {
            s_low_batt_sleep = 0;
        } else {
            low_battery_sleep(&boot_gauge);
        }
    }

    board_power_and_backlight();
    panel_init();
    touch_init();
    te_init();
    ESP_LOGI(TAG, "panel up internal=%u largest=%u",
             (unsigned)heap_caps_get_free_size(MALLOC_CAP_INTERNAL),
             (unsigned)heap_caps_get_largest_free_block(MALLOC_CAP_INTERNAL));

    size_t body_bytes = (size_t)BODY_ROWS * 360 * sizeof(uint16_t);
    /* The body is 253 KB; keep it in PSRAM so the Wi-Fi/TLS stacks have
     * internal RAM. Every row is drawn: the ambient pages use the bezel. */
    s_body = heap_caps_malloc(body_bytes, MALLOC_CAP_SPIRAM | MALLOC_CAP_DMA);
    if (s_body == NULL) s_body = heap_caps_malloc(body_bytes, MALLOC_CAP_DMA | MALLOC_CAP_INTERNAL);
    s_stage = heap_caps_malloc((size_t)STAGE_ROWS * 360 * sizeof(uint16_t),
                               MALLOC_CAP_DMA | MALLOC_CAP_INTERNAL);
    if (!s_body || !s_stage) {
        ESP_LOGE(TAG, "buffer alloc failed body=%p internal=%u largest=%u",
                 (void *)s_body,
                 (unsigned)heap_caps_get_free_size(MALLOC_CAP_INTERNAL),
                 (unsigned)heap_caps_get_largest_free_block(MALLOC_CAP_INTERNAL));
        while (1) vTaskDelay(pdMS_TO_TICKS(1000));
    }
    memset(s_body, 0, body_bytes);
    ESP_LOGI(TAG, "body %d rows, free internal=%u largest=%u",
             BODY_ROWS,
             (unsigned)heap_caps_get_free_size(MALLOC_CAP_INTERNAL),
             (unsigned)heap_caps_get_largest_free_block(MALLOC_CAP_INTERNAL));

    r_pal pal;
    memset(&pal, 0, sizeof(pal));
    pal.bg = (r_rgb){ 5, 10, 14 };
    pal.ink = pip_state_color(PIP_IDLE);
    r_dl_init(&s_dl, &pal);
    r_set_swap(true);
    r_glow_enable(false);   /* panel glow banding: keep eyes/paws flat */

    pip_scene_init(&s_scene, 1u);
    pip_opts_default(&s_opt);
    shake_init(&s_shake, 3);
    s_opt.rings = false;
    s_opt.njob = 0;
    s_opt.charging = true;
    color_bind(PIP_HUB);
    if (s_opt.has_bg) s_dl.pal.bg = s_opt.bg;

    cue9_config_load();
    cue9_wifi_start();
    xTaskCreatePinnedToCore(cmd_task, "pip_cmd", 4096, NULL, 4, NULL, 0);
    xTaskCreatePinnedToCore(log_gate_task, "pip_log", 2048, NULL, 2, NULL, 0);
    xTaskCreatePinnedToCore(touch_task, "pip_touch", 3072, NULL, 3, NULL, 0);
    if (imu_init()) {
        xTaskCreatePinnedToCore(imu_task, "pip_imu", 4096, NULL, 3, NULL, 0);
    }

    /* The first body flush in the frame loop primes the DMA; nothing on the
     * panel is drawn before that. s_done starts at 0 and the TE wait before
     * each write covers the panel's first field. */
    s_done = 0;

    BaseType_t ok = xTaskCreatePinnedToCore(build_worker, "pip_build", 8192, NULL, 5,
                                            &s_build_task, 1);
    if (ok != pdPASS) {
        ESP_LOGE(TAG, "build task create failed");
        while (1) vTaskDelay(pdMS_TO_TICKS(1000));
    }

    static const int demo_order[] = {
        PIP_WORK, PIP_IDLE, PIP_SLEEP, PIP_OFFLINE, PIP_CURIOUS, PIP_THINKING,
        PIP_SEARCH, PIP_READ, PIP_WAIT, PIP_WAKE, PIP_APPROVAL, PIP_MCQ,
        PIP_RETRY, PIP_DONE, PIP_TOOL_CALL, PIP_RUN_CMD, PIP_HUB
    };
    int oi = 0;
    uint32_t refresh_seen = s_refresh_seq;
    uint32_t cmd_seen = s_cmd_seq;
    int state = PIP_HUB;
    int base_state = PIP_HUB;   /* timeline under a dizzy overlay */
    bool demo_active = false;
    float base_t = 0.0f;
    float since_glow = 0.0f;
    float since_agents = 1.5f;
    uint32_t agent_rng = 0x9e3779b9u;
    bool glow_on = true;
    int frame = 0;
    int page = AMB_PAGE_LIVE;
    int page_seen = -1;
    int resume_page = AMB_PAGE_LIVE;
    bool auto_done = false;
    bool forced_live = false;
    bool was_quiet = false;
    bool was_urgent = false;
    const char *last_clock_label = NULL;
    int64_t quiet_since = 0;
    uint32_t page_cmd_seen = 0;
    /* Sensor reactions (shake -> dizzy, stroke -> happy) take over the page. */
    int reaction_state = -1;
    int64_t reaction_start = 0;
    int64_t reaction_until = 0;
    int reaction_page = AMB_PAGE_LIVE;
    int64_t shake_seen = 0;
    int64_t stroke_seen = 0;
    int64_t acc_render = 0, acc_clear = 0, acc_flush = 0, acc_wait_build = 0;
    int64_t next = esp_timer_get_time();
    int64_t last_frame = next;
    int64_t last_batt_check = next;
    int batt_critical_runs = 0;
    int64_t fps_t0 = next;
    int64_t host_lost_us = 0;
    int fps_frames = 0;
    int rc = R_OK;

    /* First frame: build synchronously through the worker. */
    r_glow_enable(false);   /* work starts glow-off */
    s_build_state = state;
    s_build_t = 0.0f;
    s_build_dt = 1.0f / 30.0f;
    s_build_reset = true;
    s_build_done = false;
    xTaskNotifyGive(s_build_task);
    wait_build();

    while (1) {
        next += 33333;
        int64_t now = esp_timer_get_time();
        float dt = (float)(now - last_frame) / 1000000.0f;
        last_frame = now;
        if (dt > 0.10f) dt = 0.10f;
        if (dt < 0.001f) dt = 0.001f;

        if (now - last_batt_check >= 2000000) {
            last_batt_check = now;
            gauge_state bg;
            gauge_get(&bg);
            if (battery_critical(&bg)) {
                if (++batt_critical_runs >= 2) {
                    low_battery_sleep(&bg);
                } else {
                    ESP_LOGW(TAG, "battery critical sample soc=%d%% %dmV; confirming",
                             bg.soc, bg.voltage_mv);
                }
            } else {
                batt_critical_runs = 0;
            }
        }

        /* No USB host means no Mac bridge. Hold hub rather than dropping into
         * the local demo tour; a returning host re-sends ANIM. */
        bool host_up = usb_serial_jtag_is_connected() || cue9_wifi_is_connected();
        if (host_up) {
            host_lost_us = 0;
        } else if (host_lost_us == 0) {
            host_lost_us = now;
        }
        if (!host_up && host_lost_us != 0 && now - host_lost_us > 2000000
            && (s_remote || s_demo)) {
            s_remote = false;
            s_demo = false;
            ESP_LOGW(TAG, "USB host lost; hub");
        } else if (s_remote && s_last_cmd_us != 0
                   && now - s_last_cmd_us > 8000000) {
            s_remote = false;
            s_demo = false;
            ESP_LOGW(TAG, "no Mac heartbeat; hub");
        }

        r_target target = {
            .px = s_body,
            .stride = 360,
            .win = { .x0 = 0, .y0 = 0, .x1 = 360, .y1 = BODY_ROWS },
        };
        uint16_t bg565 = r_rgb565(s_dl.pal.bg);
        int64_t a = esp_timer_get_time();
        r_clear(&target, bg565);
        int64_t a2 = esp_timer_get_time();
        r_render(&s_dl, &target, NULL, NULL);
        int64_t b = esp_timer_get_time();
        acc_clear += a2 - a;
        acc_render += b - a2;

        /* Explicit demo tour; otherwise remote hold; otherwise hub. This
         * timeline keeps running under a dizzy overlay. */
        int ns = base_state;
        float nt = base_t + dt;
        bool reset = false;
        if (s_demo) {
            if (!demo_active) {
                demo_active = true;
                oi = 0;
                ns = demo_order[0];
                nt = 0.0f;
                reset = true;
            } else {
                since_agents += dt;
                if (since_agents >= 2.0f) {
                    since_agents = 0.0f;
                    agent_rng = agent_rng * 1664525u + 1013904223u;
                    s_agent_count = (int)((agent_rng >> 16) % 20u);
                    ESP_LOGI(TAG, "agents=%d", s_agent_count);
                }
                if (base_t >= ((base_state == PIP_WORK) ? 15.0f : 6.0f)) {
                    oi = (oi + 1) % (int)(sizeof(demo_order) / sizeof(demo_order[0]));
                    ns = demo_order[oi];
                    nt = 0.0f;
                    reset = true;
                    ESP_LOGI(TAG, "state %s", pip_state_names[ns]);
                }
            }
        } else if (s_remote) {
            demo_active = false;
            if (s_refresh_seq != refresh_seen) {
                refresh_seen = s_refresh_seq;
                nt = 0.0f;
                reset = true;
                ESP_LOGI(TAG, "scene refresh");
            } else if (s_cmd_seq != cmd_seen) {
                cmd_seen = s_cmd_seq;
                ns = s_cmd_state;
                nt = 0.0f;
                reset = true;
                ESP_LOGI(TAG, "remote anim %s", pip_state_names[ns]);
            }
        } else {
            demo_active = false;
            if (base_state != PIP_HUB) {
                ns = PIP_HUB;
                nt = 0.0f;
                reset = true;
                s_agent_count = 0;
            }
        }
        base_state = ns;
        base_t = nt;
        int base_ns = ns;
        bool urgent_base = (base_ns == PIP_APPROVAL || base_ns == PIP_MCQ);

        /* Sensor reactions: a shake shows dizzy and a screen rub shows happy.
         * An approval/question outranks both: it cancels a running reaction
         * and ignores new shakes or strokes until DSH answers it. */
        {
            int64_t shake = s_shake_us;
            if (shake != 0 && shake != shake_seen && now - shake < 2000000LL) {
                shake_seen = shake;
                if (urgent_base) {
                    ESP_LOGI(TAG, "shake ignored (urgent)");
                } else {
                    if (reaction_state < 0) reaction_page = page;
                    reaction_state = PIP_DIZZY;
                    reaction_start = shake;
                    reaction_until = shake + s_dizzy_us;
                    reset = true;
                    ESP_LOGI(TAG, "shake -> dizzy (page %d)", reaction_page);
                }
            }
            int64_t stroke = s_stroke_us;
            if (stroke != 0 && stroke != stroke_seen && now - stroke < 2000000LL) {
                stroke_seen = stroke;
                if (urgent_base) {
                    ESP_LOGI(TAG, "stroke ignored (urgent)");
                } else {
                    if (reaction_state < 0) reaction_page = page;
                    if (reaction_state != PIP_STROKED) {
                        /* A rub interrupts dizzy; the startle does not win here. */
                        reaction_state = PIP_STROKED;
                        reaction_start = stroke;
                        reset = true;
                    }
                    reaction_until = stroke + s_happy_us;
                    ESP_LOGI(TAG, "stroke -> happy (page %d)", reaction_page);
                }
            }
            if (urgent_base && reaction_state >= 0) {
                if (!forced_live) {
                    resume_page = reaction_page;
                    forced_live = true;
                }
                ESP_LOGI(TAG, "urgent clears sensor reaction %d", reaction_state);
                reaction_state = -1;
                reaction_until = 0;
            }
        }
        bool reacting = reaction_state >= 0 && now < reaction_until;
        if (reacting) {
            ns = reaction_state;
            nt = (float)((double)(now - reaction_start) / 1000000.0);
        } else if (reaction_state >= 0) {
            int finished = reaction_state;
            page = reaction_page;
            reaction_state = -1;
            /* An approval that arrived during the overlay takes the screen now. */
            if (base_ns == PIP_APPROVAL || base_ns == PIP_MCQ) {
                if (!forced_live) {
                    resume_page = page;
                    forced_live = true;
                }
                page = AMB_PAGE_LIVE;
            }
            ESP_LOGI(TAG, "%s done: page %d",
                     finished == PIP_DIZZY ? "dizzy" : "happy", page);
        }
        since_glow += dt;
        if (since_glow >= 3.0f) {
            since_glow = 0.0f;
            glow_on = !glow_on;
            ESP_LOGI(TAG, "glow=%d", (int)glow_on);
        }
        bool glow_eff = false;   /* disabled: glow produced horizontal bands */
        r_glow_enable(false);

        if (ns != state || reset) color_commit(ns);
        color_bind(ns);

        /* Pages: live face, clock, weather. A swipe or PAGE moves between
         * them and stays put: only an approval or question may take the
         * screen. When that cue clears, the page it interrupted comes back. */
        int page_before = page;
        uint32_t page_cmd_now = s_page_cmd_seq;
        if (page_cmd_now != page_cmd_seen) {
            page_cmd_seen = page_cmd_now;
            if (s_page_cmd >= 0) {
                page = s_page_cmd;
                auto_done = true;
                forced_live = false;   /* the user took the page back */
            }
        }
        int nav = s_touch_nav;
        if (nav != 0) {
            s_touch_nav = 0;
            page = (page + nav + 3) % 3;
            auto_done = true;
            forced_live = false;
        }
        bool quiet = (base_ns == PIP_SLEEP || base_ns == PIP_HUB);
        if (quiet && !was_quiet) {
            quiet_since = now;
            auto_done = false;
        }
        if (!quiet) quiet_since = 0;
        was_quiet = quiet;
        if (quiet && !auto_done && !forced_live && quiet_since != 0
            && now - quiet_since >= 60000000LL) {
            page = AMB_PAGE_CLOCK;
            auto_done = true;
            ESP_LOGI(TAG, "auto clock after 60s quiet");
        }
        bool urgent = urgent_base;
        if (urgent && !was_urgent) {
            if (!forced_live) {
                resume_page = page;
                forced_live = true;
            }
            if (page != AMB_PAGE_LIVE) {
                ESP_LOGI(TAG, "urgent cue: live (was page %d)", resume_page);
                page = AMB_PAGE_LIVE;
            }
        } else if (!urgent && was_urgent) {
            if (forced_live) {
                page = resume_page;
                forced_live = false;
                ESP_LOGI(TAG, "urgent cleared: back to page %d", page);
            }
        }
        was_urgent = urgent;
        if (reacting) {
            if (page != page_before) {
                /* The user paged away mid-reaction: drop the reaction and
                 * leave them on the page they asked for. */
                reaction_state = -1;
                ns = base_ns;
                nt = base_t;
                reset = false;
                ESP_LOGI(TAG, "reaction ended by page change");
            } else {
                page = AMB_PAGE_LIVE;   /* the face is the reaction; page comes back after */
                s_touch_nav = 0;
            }
        }
        if (page == AMB_PAGE_CLOCK) {
            const char *label = state_status_label(ns);
            if (label != last_clock_label) {
                last_clock_label = label;
                ESP_LOGI(TAG, "clock status %s", label);
            }
        } else {
            last_clock_label = NULL;
        }
        if (page != page_seen) {
            ESP_LOGI(TAG, "page %d (%s)", page,
                     page == AMB_PAGE_LIVE ? "live" : page == AMB_PAGE_CLOCK ? "clock" : "weather");
            s_dl.pal.bg = (page == AMB_PAGE_LIVE)
                              ? (s_opt.has_bg ? s_opt.bg : (r_rgb){ 5, 10, 14 })
                              : amb_page_bg(page);
            page_seen = page;
        }

        s_opt.stroke = s_stroke_x;
        s_build_page = page;
        s_build_state = ns;
        s_build_t = nt;
        s_build_dt = dt;
        s_build_reset = reset;
        s_build_done = false;
        xTaskNotifyGive(s_build_task);

        int64_t f0 = esp_timer_get_time();
        flush_body();
        int64_t f1 = esp_timer_get_time();
        acc_flush += f1 - f0;

        int64_t w0 = esp_timer_get_time();
        wait_build();
        acc_wait_build += esp_timer_get_time() - w0;

        state = ns;
        frame++;
        fps_frames++;

        int64_t end = esp_timer_get_time();
        if (end - fps_t0 >= 1000000) {
            ESP_LOGI(TAG, "%s glow=%d f=%d build=%.1f clear=%.1f render=%.1f flush=%.1f waitb=%.1f te=%.2f fps=%.1f rc=%d free=%u",
                     pip_state_names[state], (int)glow_eff, frame,
                     (double)s_build_us / 1000.0, (double)acc_clear / 1000.0,
                     (double)acc_render / 1000.0, (double)acc_flush / 1000.0,
                     (double)acc_wait_build / 1000.0,
                     (double)s_te_period_us / 1000.0,
                     (double)fps_frames * 1000000.0 / (double)(end - fps_t0),
                     rc, (unsigned)heap_caps_get_free_size(MALLOC_CAP_INTERNAL));
            acc_render = acc_clear = acc_flush = acc_wait_build = 0;
            fps_t0 = end;
            fps_frames = 0;
        }

        if (next > end) {
            vTaskDelay(pdMS_TO_TICKS((next - end) / 1000));
        } else {
            next = end;
        }
    }
}
