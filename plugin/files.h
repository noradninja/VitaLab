#ifndef VITALAB_FILES_H
#define VITALAB_FILES_H

#define VITALAB_FILE_NOT_HANDLED 0
#define VITALAB_FILE_HANDLED 1
#define VITALAB_FILE_CONNECTION_CLOSED (-1)

int vitalab_file_command(int client, const char *line);

#endif
