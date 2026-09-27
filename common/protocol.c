#include "protocol.h"

#ifndef VITALAB_VERSION
#define VITALAB_VERSION "0.0.0"
#endif

#ifndef VITALAB_GIT_COMMIT
#define VITALAB_GIT_COMMIT "unknown"
#endif

#ifndef VITALAB_BUILD_ID
#define VITALAB_BUILD_ID "unknown"
#endif

static int text_equals(const char *left, const char *right) {
  while (*left != '\0' && *right != '\0') {
    if (*left++ != *right++) {
      return 0;
    }
  }
  return *left == *right;
}

static int copy_reply(char *reply, size_t reply_size, const char *text) {
  size_t length = 0;
  while (text[length] != '\0') {
    ++length;
  }
  if (length >= reply_size) {
    return -1;
  }
  {
    size_t index;
    for (index = 0; index <= length; ++index) {
      reply[index] = text[index];
    }
  }
  return (int)length;
}

int vitalab_protocol_reply(const char *line, char *reply, size_t reply_size) {
  static const char info[] =
    "VITALAB/1 INFO version=" VITALAB_VERSION
    " platform=psvita build=" VITALAB_BUILD_ID
    " commit=" VITALAB_GIT_COMMIT "\n";

  if (line == NULL || reply == NULL || reply_size == 0) {
    return -1;
  }
  if (text_equals(line, "HELLO")) {
    return copy_reply(reply, reply_size, "VITALAB/1 READY\n");
  }
  if (text_equals(line, "PING")) {
    return copy_reply(reply, reply_size, "PONG\n");
  }
  if (text_equals(line, "INFO")) {
    return copy_reply(reply, reply_size, info);
  }
  return copy_reply(reply, reply_size, "ERR UNKNOWN_COMMAND\n");
}
