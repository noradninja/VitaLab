#ifndef VITALAB_PROTOCOL_H
#define VITALAB_PROTOCOL_H

#include <stddef.h>

#define VITALAB_PROTOCOL_VERSION 1
#define VITALAB_MAX_LINE 255

int vitalab_protocol_reply(const char *line, char *reply, size_t reply_size);

#endif
