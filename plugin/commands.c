#include "commands.h"

#include <psp2/appmgr.h>

#define TITLE_ID_LENGTH 9

static int starts_with(const char *text, const char *prefix) {
  while (*prefix != '\0') {
    if (*text++ != *prefix++) {
      return 0;
    }
  }
  return 1;
}

static int valid_title_id(const char *title_id) {
  int index;
  for (index = 0; index < TITLE_ID_LENGTH; ++index) {
    char value = title_id[index];
    if (!((value >= 'A' && value <= 'Z') ||
          (value >= '0' && value <= '9'))) {
      return 0;
    }
  }
  return title_id[TITLE_ID_LENGTH] == '\0';
}

static int append_text(char *output, size_t size, int position,
    const char *text) {
  while (*text != '\0') {
    if ((size_t)(position + 1) >= size) {
      return -1;
    }
    output[position++] = *text++;
  }
  output[position] = '\0';
  return position;
}

static int success_reply(char *reply, size_t reply_size, const char *action,
    const char *title_id) {
  int position = append_text(reply, reply_size, 0, "OK ");
  if (position >= 0) {
    position = append_text(reply, reply_size, position, action);
  }
  if (position >= 0) {
    position = append_text(reply, reply_size, position, " ");
  }
  if (position >= 0) {
    position = append_text(reply, reply_size, position, title_id);
  }
  if (position >= 0) {
    position = append_text(reply, reply_size, position, "\n");
  }
  return position;
}

static int error_reply(char *reply, size_t reply_size, const char *action,
    int error) {
  static const char hex[] = "0123456789ABCDEF";
  unsigned int value = (unsigned int)error;
  int position = append_text(reply, reply_size, 0, "ERR ");
  int shift;
  if (position >= 0) {
    position = append_text(reply, reply_size, position, action);
  }
  if (position >= 0) {
    position = append_text(reply, reply_size, position, " 0x");
  }
  if (position < 0 || (size_t)(position + 10) > reply_size) {
    return -1;
  }
  for (shift = 28; shift >= 0; shift -= 4) {
    reply[position++] = hex[(value >> shift) & 0xF];
  }
  reply[position++] = '\n';
  reply[position] = '\0';
  return position;
}

static int invalid_title_reply(char *reply, size_t reply_size) {
  return append_text(reply, reply_size, 0, "ERR INVALID_TITLE_ID\n");
}

static int launch_title(const char *title_id, char *reply, size_t reply_size) {
  char uri[29] = "psgm:play?titleid=";
  int index;
  int result;
  for (index = 0; index < TITLE_ID_LENGTH; ++index) {
    uri[18 + index] = title_id[index];
  }
  uri[27] = '\0';
  result = sceAppMgrLaunchAppByUri(0x20000, uri);
  if (result < 0) {
    return error_reply(reply, reply_size, "LAUNCH", result);
  }
  return success_reply(reply, reply_size, "LAUNCH", title_id);
}

static int stop_title(const char *title_id, char *reply, size_t reply_size) {
  int result = sceAppMgrDestroyAppByName(title_id);
  if (result < 0) {
    return error_reply(reply, reply_size, "STOP", result);
  }
  return success_reply(reply, reply_size, "STOP", title_id);
}

int vitalab_command_reply(const char *line, char *reply, size_t reply_size) {
  const char *title_id;
  if (starts_with(line, "LAUNCH ")) {
    title_id = line + 7;
    if (!valid_title_id(title_id)) {
      return invalid_title_reply(reply, reply_size);
    }
    return launch_title(title_id, reply, reply_size);
  }
  if (starts_with(line, "STOP ")) {
    title_id = line + 5;
    if (!valid_title_id(title_id)) {
      return invalid_title_reply(reply, reply_size);
    }
    return stop_title(title_id, reply, reply_size);
  }
  return VITALAB_COMMAND_NOT_HANDLED;
}
