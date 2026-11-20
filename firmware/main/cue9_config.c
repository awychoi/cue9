#include "cue9_config.h"

#include <stdlib.h>
#include <string.h>

#include "cJSON.h"
#include "esp_heap_caps.h"
#include "esp_log.h"
#include "esp_partition.h"

#define TAG "cue9cfg"
#define CFG_MAGIC "CUE9CFG1"
#define CFG_SIZE 16384

static cue9_config s_cfg;

static void copy_str(char *dst, size_t size, const char *src)
{
    if (src == NULL) {
        dst[0] = 0;
        return;
    }
    snprintf(dst, size, "%s", src);
}

static char *dup_str(const char *src)
{
    if (src == NULL) return NULL;
    size_t n = strlen(src) + 1;
    char *out = malloc(n);
    if (out != NULL) memcpy(out, src, n);
    return out;
}

static const char *field(const cJSON *root, const char *name)
{
    return cJSON_GetStringValue(cJSON_GetObjectItemCaseSensitive(root, name));
}

const cue9_config *cue9_config_get(void)
{
    return &s_cfg;
}

bool cue9_config_load(void)
{
    memset(&s_cfg, 0, sizeof(s_cfg));
    s_cfg.port = 7777;

    const esp_partition_t *part = esp_partition_find_first(
        ESP_PARTITION_TYPE_DATA, (esp_partition_subtype_t)0x40, "cue9cfg");
    if (part == NULL) {
        ESP_LOGW(TAG, "no cue9cfg partition; usb only");
        return false;
    }

    char *blob = heap_caps_malloc(CFG_SIZE + 1, MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT);
    if (blob == NULL) {
        ESP_LOGE(TAG, "no memory for config");
        return false;
    }
    esp_err_t err = esp_partition_read(part, 0, blob, CFG_SIZE);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "partition read: %s", esp_err_to_name(err));
        free(blob);
        return false;
    }
    blob[CFG_SIZE] = 0;

    if (strncmp(blob, CFG_MAGIC, strlen(CFG_MAGIC)) != 0) {
        ESP_LOGW(TAG, "config is empty; usb only");
        free(blob);
        return false;
    }

    cJSON *root = cJSON_Parse(blob + strlen(CFG_MAGIC));
    free(blob);
    if (root == NULL) {
        ESP_LOGE(TAG, "config json did not parse");
        return false;
    }

    const cJSON *wifi = cJSON_GetObjectItemCaseSensitive(root, "wifi");
    copy_str(s_cfg.ssid, sizeof(s_cfg.ssid),
             cJSON_GetStringValue(cJSON_GetObjectItemCaseSensitive(wifi, "ssid")));
    copy_str(s_cfg.psk, sizeof(s_cfg.psk),
             cJSON_GetStringValue(cJSON_GetObjectItemCaseSensitive(wifi, "psk")));
    copy_str(s_cfg.host, sizeof(s_cfg.host), field(root, "host"));

    const cJSON *port = cJSON_GetObjectItemCaseSensitive(root, "port");
    if (cJSON_IsNumber(port) && port->valueint > 0 && port->valueint < 65536) {
        s_cfg.port = port->valueint;
    }

    s_cfg.ca = dup_str(field(root, "ca"));
    s_cfg.cert = dup_str(field(root, "cert"));
    s_cfg.key = dup_str(field(root, "key"));
    cJSON_Delete(root);

    s_cfg.loaded = s_cfg.ssid[0] != 0 && s_cfg.host[0] != 0 && s_cfg.port > 0 &&
                   s_cfg.ca != NULL && s_cfg.cert != NULL && s_cfg.key != NULL;
    ESP_LOGI(TAG, "config %s: ssid=%s host=%s:%d",
             s_cfg.loaded ? "ok" : "incomplete",
             s_cfg.ssid, s_cfg.host, s_cfg.port);
    return s_cfg.loaded;
}
