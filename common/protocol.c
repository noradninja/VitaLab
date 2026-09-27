#include "protocol.h"

#include <stdio.h>
#include <string.h>

#ifndef VITALAB_VERSION
#define VITALAB_VERSION "0.0.0"
#endif

#ifndef VITALAB_GIT_COMMIT
#define VITALAB_GIT_COMMIT "unknown"
#endif

#ifndef VITALAB_BUILD_ID
#define VITALAB_BUILD_ID "unknown"
#endif

int vitalab_protocol_reply(const char *line, char *reply, size_t reply_size) {
  if (line == NULL || reply == NULL || reply_size == 0) {
    return -1;
  }

  if (strcmp(line, "HELLO") == 0) {
    return snprintf(reply, reply_size, "VITALAB/%d READY\n", VITALAB_PROTOCOL_VERSION);
  }
  if (strcmp(line, "PING") == 0) {
    return snprintf(reply, reply_size, "PONG\n");
  }
  if (strcmp(line, "INFO") == 0) {
    return snprintf(reply, reply_size,
      "VITALAB/%d INFO version=%s platform=psvita build=%s commit=%s\n",
      VITALAB_PROTOCOL_VERSION, VITALAB_VERSION, VITALAB_BUILD_ID,
      VITALAB_GIT_COMMIT);
  }

  return snprintf(reply, reply_size, "ERR UNKNOWN_COMMAND\n");
}
