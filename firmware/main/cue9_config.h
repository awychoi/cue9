#pragma once

#include <stdbool.h>

/* Provisioned into the cue9cfg partition over USB. PEM strings are heap
 * copies owned by cue9_config.c; nothing here is secret to the device. */
typedef struct {
    char ssid[33];
    char psk[65];
    char host[64];
    int port;
    char *ca;
    char *cert;
    char *key;
    bool loaded;
} cue9_config;

const cue9_config *cue9_config_get(void);
bool cue9_config_load(void);
