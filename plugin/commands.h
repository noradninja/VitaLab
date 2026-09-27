#ifndef VITALAB_COMMANDS_H
#define VITALAB_COMMANDS_H

#include <stddef.h>

#define VITALAB_COMMAND_NOT_HANDLED (-2)

int vitalab_command_reply(const char *line, char *reply, size_t reply_size);

#endif
