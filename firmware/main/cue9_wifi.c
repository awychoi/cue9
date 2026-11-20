/* cue9 Wi-Fi link: station mode plus a mutual-TLS client to cue9-moted.
 *
 * One task owns both the socket and the parser, so mbedTLS is never touched
 * from two tasks. Reads block; a dead peer is caught by the pinned heartbeat
 * timeout in the render loop, not by a socket poll. The only outbound bytes
 * after connect are PONG replies.
 */
#include "cue9_wifi.h"

#include <string.h>
#include <sys/time.h>

#include "esp_event.h"
#include "esp_log.h"
#include "esp_netif.h"
#include "esp_system.h"
#include "esp_tls.h"
#include "esp_wifi.h"
#include "freertos/FreeRTOS.h"
#include "freertos/event_groups.h"
#include "freertos/task.h"
#include "lwip/sockets.h"
#include "nvs_flash.h"

#include "cue9_config.h"

#define TAG "cue9wifi"
#define WIFI_BIT BIT0

static EventGroupHandle_t s_events;
static volatile bool s_link;
static volatile int s_rssi;

static void on_event(void *arg, esp_event_base_t base, int32_t id, void *data)
{
    (void)arg;
    if (base == WIFI_EVENT && id == WIFI_EVENT_STA_START) {
        ESP_LOGI(TAG, "station started");
    } else if (base == WIFI_EVENT && id == WIFI_EVENT_STA_CONNECTED) {
        ESP_LOGI(TAG, "associated");
    } else if (base == WIFI_EVENT && id == WIFI_EVENT_STA_DISCONNECTED) {
        const wifi_event_sta_disconnected_t *d = (const wifi_event_sta_disconnected_t *)data;
        ESP_LOGW(TAG, "disconnected reason=%d", d == NULL ? -1 : (int)d->reason);
        s_link = false;
        xEventGroupClearBits(s_events, WIFI_BIT);
    } else if (base == IP_EVENT && id == IP_EVENT_STA_GOT_IP) {
        const ip_event_got_ip_t *e = (const ip_event_got_ip_t *)data;
        ESP_LOGI(TAG, "ip " IPSTR, IP2STR(&e->ip_info.ip));
        xEventGroupSetBits(s_events, WIFI_BIT);
    }
}

static void tune_socket(esp_tls_t *tls)
{
    int fd = -1;
    if (esp_tls_get_conn_sockfd(tls, &fd) != ESP_OK || fd < 0) return;
    struct timeval tv = { .tv_sec = 0, .tv_usec = 0 };
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    int on = 1;
    setsockopt(fd, SOL_SOCKET, SO_KEEPALIVE, &on, sizeof(on));
#ifdef TCP_KEEPIDLE
    int idle = 20, intvl = 5, cnt = 3;
    setsockopt(fd, IPPROTO_TCP, TCP_KEEPIDLE, &idle, sizeof(idle));
    setsockopt(fd, IPPROTO_TCP, TCP_KEEPINTVL, &intvl, sizeof(intvl));
    setsockopt(fd, IPPROTO_TCP, TCP_KEEPCNT, &cnt, sizeof(cnt));
#endif
}

static void wifi_task(void *arg)
{
    (void)arg;
    const cue9_config *cfg = cue9_config_get();
    char line[96];
    char buf[256];

    for (;;) {
        if ((xEventGroupGetBits(s_events) & WIFI_BIT) == 0) {
            esp_err_t err = esp_wifi_connect();
            if (err != ESP_OK) {
                ESP_LOGW(TAG, "connect: %s", esp_err_to_name(err));
            }
            EventBits_t bits = xEventGroupWaitBits(s_events, WIFI_BIT, pdFALSE, pdTRUE,
                                                   pdMS_TO_TICKS(5000));
            if ((bits & WIFI_BIT) == 0) {
                vTaskDelay(pdMS_TO_TICKS(1000));
                continue;
            }
        }

        esp_tls_cfg_t tcfg = { 0 };
        tcfg.cacert_buf = (const unsigned char *)cfg->ca;
        tcfg.cacert_bytes = strlen(cfg->ca) + 1;
        tcfg.clientcert_buf = (const unsigned char *)cfg->cert;
        tcfg.clientcert_bytes = strlen(cfg->cert) + 1;
        tcfg.clientkey_buf = (const unsigned char *)cfg->key;
        tcfg.clientkey_bytes = strlen(cfg->key) + 1;
        tcfg.skip_common_name = true;   /* the CA is pinned per install */
        tcfg.timeout_ms = 15000;

        esp_tls_t *tls = esp_tls_init();
        if (tls == NULL) {
            vTaskDelay(pdMS_TO_TICKS(2000));
            continue;
        }
        int ok = esp_tls_conn_new_sync(cfg->host, strlen(cfg->host), cfg->port, &tcfg, tls);
        if (ok != 1) {
            ESP_LOGW(TAG, "tls connect to %s:%d failed (%d)", cfg->host, cfg->port, ok);
            esp_tls_conn_destroy(tls);
            vTaskDelay(pdMS_TO_TICKS(3000));
            continue;
        }

        tune_socket(tls);
        wifi_ap_record_t ap;
        if (esp_wifi_sta_get_ap_info(&ap) == ESP_OK) s_rssi = ap.rssi;

        char hello[40];
        /* Include the reset reason: the Pi log then tells a KVM USB reset
         * apart from a brownout or watchdog reset without the USB console. */
        int hello_len = snprintf(hello, sizeof(hello), "READY %d %d\n",
                                 s_rssi, (int)esp_reset_reason());
        esp_tls_conn_write(tls, hello, (size_t)hello_len);
        s_link = true;
        ESP_LOGI(TAG, "linked %s:%d rssi=%d reset=%d",
                 cfg->host, cfg->port, s_rssi, (int)esp_reset_reason());

        int used = 0;
        for (;;) {
            int r = esp_tls_conn_read(tls, buf, sizeof(buf));
            if (r == ESP_TLS_ERR_SSL_WANT_READ || r == ESP_TLS_ERR_SSL_WANT_WRITE) {
                continue;
            }
            if (r == 0) {
                ESP_LOGW(TAG, "moted closed the link");
                break;
            }
            if (r < 0) {
                ESP_LOGW(TAG, "read error %d", r);
                break;
            }
            for (int i = 0; i < r; i++) {
                char ch = buf[i];
                if (ch == '\n' || ch == '\r') {
                    if (used > 0) {
                        line[used] = 0;
                        const char *reply = cue9_handle_line(line);
                        if (reply != NULL) {
                            size_t n = strlen(reply);
                            esp_tls_conn_write(tls, reply, n);
                            esp_tls_conn_write(tls, "\n", 1);
                        }
                        used = 0;
                    }
                } else if (used < (int)sizeof(line) - 1) {
                    line[used++] = ch;
                }
            }
        }

        s_link = false;
        esp_tls_conn_destroy(tls);
        vTaskDelay(pdMS_TO_TICKS(1000));
    }
}

void cue9_wifi_start(void)
{
    const cue9_config *cfg = cue9_config_get();
    if (!cfg->loaded) {
        ESP_LOGW(TAG, "not provisioned; usb only");
        return;
    }

    esp_err_t err = nvs_flash_init();
    if (err == ESP_ERR_NVS_NO_FREE_PAGES || err == ESP_ERR_NVS_NEW_VERSION_FOUND) {
        ESP_ERROR_CHECK(nvs_flash_erase());
        err = nvs_flash_init();
    }
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "nvs init: %s", esp_err_to_name(err));
        return;
    }

    s_events = xEventGroupCreate();
    if (s_events == NULL) return;

    ESP_ERROR_CHECK(esp_netif_init());
    ESP_ERROR_CHECK(esp_event_loop_create_default());
    esp_netif_create_default_wifi_sta();

    wifi_init_config_t init = WIFI_INIT_CONFIG_DEFAULT();
    ESP_ERROR_CHECK(esp_wifi_init(&init));
    ESP_ERROR_CHECK(esp_event_handler_instance_register(
        WIFI_EVENT, ESP_EVENT_ANY_ID, on_event, NULL, NULL));
    ESP_ERROR_CHECK(esp_event_handler_instance_register(
        IP_EVENT, IP_EVENT_STA_GOT_IP, on_event, NULL, NULL));

    wifi_config_t wc = { 0 };
    strncpy((char *)wc.sta.ssid, cfg->ssid, sizeof(wc.sta.ssid) - 1);
    strncpy((char *)wc.sta.password, cfg->psk, sizeof(wc.sta.password) - 1);
    wc.sta.threshold.authmode = WIFI_AUTH_WPA2_PSK;
    /* WPA2/WPA3 transition APs: advertise PMF support without requiring it,
     * and allow either SAE PWE derivation. */
    wc.sta.pmf_cfg.capable = true;
    wc.sta.pmf_cfg.required = false;
    wc.sta.sae_pwe_h2e = WPA3_SAE_PWE_BOTH;

    ESP_ERROR_CHECK(esp_wifi_set_mode(WIFI_MODE_STA));
    ESP_ERROR_CHECK(esp_wifi_set_config(WIFI_IF_STA, &wc));
    ESP_ERROR_CHECK(esp_wifi_set_ps(WIFI_PS_MIN_MODEM));
    ESP_ERROR_CHECK(esp_wifi_start());

    ESP_LOGI(TAG, "station %s -> %s:%d", cfg->ssid, cfg->host, cfg->port);
    xTaskCreatePinnedToCore(wifi_task, "cue9wifi", 12288, NULL, 4, NULL, 0);
}

bool cue9_wifi_is_connected(void)
{
    return s_link;
}
