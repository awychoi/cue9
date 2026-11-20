#pragma once

#include <stdbool.h>

/* Starts the station + TLS client task when the cue9cfg partition is valid. */
void cue9_wifi_start(void);

/* True once the mTLS link to cue9-moted is up. */
bool cue9_wifi_is_connected(void);

/* main.c: parse one protocol line. Returns a reply ("PONG") or NULL. */
const char *cue9_handle_line(char *line);
