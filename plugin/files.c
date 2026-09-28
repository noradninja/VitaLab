#include "files.h"

#include <psp2/io/fcntl.h>
#include <psp2/io/dirent.h>
#include <psp2/io/stat.h>
#include <psp2/net/net.h>

#define FILE_ROOT "ux0:data/vitalab/files/"
#define FILE_ROOT_DIRECTORY "ux0:data/vitalab/files"
#define MAX_RELATIVE_PATH 128
#define MAX_FULL_PATH 192
#define MAX_FILE_SIZE (256 * 1024 * 1024)
#define IO_BUFFER_SIZE 4096

static int starts_with(const char *text, const char *prefix) {
  while (*prefix != '\0') {
    if (*text++ != *prefix++) {
      return 0;
    }
  }
  return 1;
}

static int text_equals(const char *left, const char *right) {
  while (*left != '\0' && *right != '\0') {
    if (*left++ != *right++) return 0;
  }
  return *left == *right;
}

static int ends_with(const char *text, const char *suffix) {
  int text_length = 0;
  int suffix_length = 0;
  int index;
  while (text[text_length] != '\0') ++text_length;
  while (suffix[suffix_length] != '\0') ++suffix_length;
  if (suffix_length > text_length) return 0;
  for (index = 0; index < suffix_length; ++index) {
    if (text[text_length - suffix_length + index] != suffix[index]) return 0;
  }
  return 1;
}

static int append_text(char *output, int size, int position,
    const char *text) {
  while (*text != '\0') {
    if (position + 1 >= size) {
      return -1;
    }
    output[position++] = *text++;
  }
  output[position] = '\0';
  return position;
}

static int append_unsigned(char *output, int size, int position,
    unsigned int value) {
  char digits[10];
  int count = 0;
  do {
    digits[count++] = (char)('0' + (value % 10));
    value /= 10;
  } while (value != 0 && count < (int)sizeof(digits));
  while (count > 0) {
    char character[2];
    character[0] = digits[--count];
    character[1] = '\0';
    position = append_text(output, size, position, character);
    if (position < 0) {
      return -1;
    }
  }
  return position;
}

static int append_hex_error(char *output, int size, int position, int error) {
  static const char hex[] = "0123456789ABCDEF";
  unsigned int value = (unsigned int)error;
  int shift;
  position = append_text(output, size, position, "0x");
  if (position < 0 || position + 9 >= size) {
    return -1;
  }
  for (shift = 28; shift >= 0; shift -= 4) {
    output[position++] = hex[(value >> shift) & 0xF];
  }
  output[position] = '\0';
  return position;
}

static int send_all(int client, const void *data, int length) {
  const char *bytes = (const char *)data;
  int sent = 0;
  while (sent < length) {
    int result = sceNetSend(client, bytes + sent,
      (unsigned int)(length - sent), 0);
    if (result <= 0) {
      return -1;
    }
    sent += result;
  }
  return sent;
}

static int send_text(int client, const char *text) {
  int length = 0;
  while (text[length] != '\0') {
    ++length;
  }
  return send_all(client, text, length);
}

static int send_file_error(int client, int error) {
  char reply[32];
  int position = append_text(reply, sizeof(reply), 0, "ERR FILE ");
  if (position >= 0) {
    position = append_hex_error(reply, sizeof(reply), position, error);
  }
  if (position >= 0) {
    position = append_text(reply, sizeof(reply), position, "\n");
  }
  return position < 0 ? -1 : send_all(client, reply, position);
}

static int valid_relative_path(const char *path) {
  int length = 0;
  int segment_length = 0;
  if (*path == '\0' || *path == '/') {
    return 0;
  }
  while (*path != '\0') {
    char value = *path++;
    if (++length > MAX_RELATIVE_PATH) {
      return 0;
    }
    if (value == '/') {
      if (segment_length == 0) {
        return 0;
      }
      segment_length = 0;
      continue;
    }
    if (!((value >= 'A' && value <= 'Z') ||
          (value >= 'a' && value <= 'z') ||
          (value >= '0' && value <= '9') ||
          value == '.' || value == '_' || value == '-')) {
      return 0;
    }
    ++segment_length;
  }
  if (segment_length == 0) {
    return 0;
  }

  path -= length;
  while (*path != '\0') {
    const char *segment = path;
    int segment_size = 0;
    while (*path != '\0' && *path != '/') {
      ++path;
      ++segment_size;
    }
    if ((segment_size == 1 && segment[0] == '.') ||
        (segment_size == 2 && segment[0] == '.' && segment[1] == '.')) {
      return 0;
    }
    if (*path == '/') {
      ++path;
    }
  }
  return 1;
}

static int build_full_path(char *output, int size, const char *relative) {
  int position = append_text(output, size, 0, FILE_ROOT);
  if (position >= 0) {
    position = append_text(output, size, position, relative);
  }
  return position;
}

static void ensure_parent_directories(char *full_path) {
  int index;
  int root_length = (int)sizeof(FILE_ROOT) - 1;
  sceIoMkdir("ux0:data/vitalab", 0777);
  sceIoMkdir(FILE_ROOT_DIRECTORY, 0777);
  for (index = root_length; full_path[index] != '\0'; ++index) {
    if (full_path[index] == '/') {
      full_path[index] = '\0';
      sceIoMkdir(full_path, 0777);
      full_path[index] = '/';
    }
  }
}

static int parse_size(const char *text, unsigned int *size) {
  unsigned int value = 0;
  int digits = 0;
  while (*text != '\0') {
    unsigned int digit;
    if (*text < '0' || *text > '9') {
      return 0;
    }
    digit = (unsigned int)(*text++ - '0');
    if (value > (MAX_FILE_SIZE - digit) / 10) {
      return 0;
    }
    value = value * 10 + digit;
    ++digits;
  }
  if (digits == 0 || value > MAX_FILE_SIZE) {
    return 0;
  }
  *size = value;
  return 1;
}

static int send_transfer_header(int client, const char *verb,
    const char *path, unsigned int size) {
  char reply[192];
  int position = append_text(reply, sizeof(reply), 0, "OK ");
  if (position >= 0) position = append_text(reply, sizeof(reply), position, verb);
  if (position >= 0) position = append_text(reply, sizeof(reply), position, " ");
  if (position >= 0) position = append_text(reply, sizeof(reply), position, path);
  if (position >= 0) position = append_text(reply, sizeof(reply), position, " ");
  if (position >= 0) position = append_unsigned(reply, sizeof(reply), position, size);
  if (position >= 0) position = append_text(reply, sizeof(reply), position, "\n");
  return position < 0 ? -1 : send_all(client, reply, position);
}

static int handle_put(int client, const char *arguments) {
  char relative[MAX_RELATIVE_PATH + 1];
  char full_path[MAX_FULL_PATH];
  char temporary_path[MAX_FULL_PATH];
  char buffer[IO_BUFFER_SIZE];
  const char *separator = arguments;
  const char *size_text;
  unsigned int expected_size;
  unsigned int received_total = 0;
  int path_length;
  int position;
  SceUID fd;

  while (*separator != '\0' && *separator != ' ') ++separator;
  if (*separator != ' ') return send_text(client, "ERR INVALID_SIZE\n") < 0 ? -1 : 1;
  path_length = (int)(separator - arguments);
  if (path_length <= 0 || path_length > MAX_RELATIVE_PATH) {
    return send_text(client, "ERR INVALID_PATH\n") < 0 ? -1 : 1;
  }
  for (position = 0; position < path_length; ++position) relative[position] = arguments[position];
  relative[path_length] = '\0';
  size_text = separator + 1;
  if (!valid_relative_path(relative)) {
    return send_text(client, "ERR INVALID_PATH\n") < 0 ? -1 : 1;
  }
  if (!parse_size(size_text, &expected_size)) {
    return send_text(client, "ERR INVALID_SIZE\n") < 0 ? -1 : 1;
  }
  if (build_full_path(full_path, sizeof(full_path), relative) < 0) {
    return send_text(client, "ERR INVALID_PATH\n") < 0 ? -1 : 1;
  }
  position = append_text(temporary_path, sizeof(temporary_path), 0, full_path);
  if (position >= 0) position = append_text(temporary_path, sizeof(temporary_path), position, ".part");
  if (position < 0) return send_text(client, "ERR INVALID_PATH\n") < 0 ? -1 : 1;

  ensure_parent_directories(full_path);
  sceIoRemove(temporary_path);
  fd = sceIoOpen(temporary_path, SCE_O_WRONLY | SCE_O_CREAT | SCE_O_TRUNC, 0666);
  if (fd < 0) return send_file_error(client, fd) < 0 ? -1 : 1;
  if (send_transfer_header(client, "READY", relative, expected_size) < 0) {
    sceIoClose(fd);
    sceIoRemove(temporary_path);
    return -1;
  }

  while (received_total < expected_size) {
    unsigned int remaining = expected_size - received_total;
    unsigned int requested = remaining < sizeof(buffer) ? remaining : sizeof(buffer);
    int received = sceNetRecv(client, buffer, requested, 0);
    int written = 0;
    if (received <= 0) {
      sceIoClose(fd);
      sceIoRemove(temporary_path);
      return -1;
    }
    while (written < received) {
      int result = sceIoWrite(fd, buffer + written, (SceSize)(received - written));
      if (result <= 0) {
        sceIoClose(fd);
        sceIoRemove(temporary_path);
        return send_file_error(client, result) < 0 ? -1 : 1;
      }
      written += result;
    }
    received_total += (unsigned int)received;
  }

  position = sceIoSyncByFd(fd, 0);
  if (position < 0) {
    sceIoClose(fd);
    sceIoRemove(temporary_path);
    return send_file_error(client, position) < 0 ? -1 : 1;
  }
  sceIoClose(fd);
  position = sceIoRename(temporary_path, full_path);
  if (position < 0) {
    sceIoRemove(temporary_path);
    return send_file_error(client, position) < 0 ? -1 : 1;
  }
  return send_transfer_header(client, "PUT", relative, expected_size) < 0 ? -1 : 1;
}

static int send_named_file(int client, const char *verb, const char *name,
    const char *full_path);

static int handle_get(int client, const char *relative) {
  char full_path[MAX_FULL_PATH];
  if (!valid_relative_path(relative) ||
      build_full_path(full_path, sizeof(full_path), relative) < 0) {
    return send_text(client, "ERR INVALID_PATH\n") < 0 ? -1 : 1;
  }
  return send_named_file(client, "GET", relative, full_path);
}

static int send_named_file(int client, const char *verb, const char *name,
    const char *full_path) {
  char buffer[IO_BUFFER_SIZE];
  SceIoStat stat;
  SceUID fd;
  unsigned int sent_total = 0;
  int result;

  result = sceIoGetstat(full_path, &stat);
  if (result < 0) return send_file_error(client, result) < 0 ? -1 : 1;
  if (stat.st_size < 0 || stat.st_size > MAX_FILE_SIZE) {
    return send_text(client, "ERR INVALID_SIZE\n") < 0 ? -1 : 1;
  }
  fd = sceIoOpen(full_path, SCE_O_RDONLY, 0);
  if (fd < 0) return send_file_error(client, fd) < 0 ? -1 : 1;
  if (send_transfer_header(client, verb, name,
      (unsigned int)stat.st_size) < 0) {
    sceIoClose(fd);
    return -1;
  }
  while (sent_total < (unsigned int)stat.st_size) {
    unsigned int remaining = (unsigned int)stat.st_size - sent_total;
    unsigned int requested = remaining < sizeof(buffer) ? remaining : sizeof(buffer);
    int read = sceIoRead(fd, buffer, requested);
    if (read <= 0 || send_all(client, buffer, read) < 0) {
      sceIoClose(fd);
      return -1;
    }
    sent_total += (unsigned int)read;
  }
  sceIoClose(fd);
  return 1;
}

static int valid_dump_name(const char *name) {
  const char *cursor = name;
  if (!starts_with(name, "psp2core-") || !ends_with(name, ".psp2dmp")) {
    return 0;
  }
  while (*cursor != '\0') {
    if (*cursor == '/') return 0;
    ++cursor;
  }
  return valid_relative_path(name);
}

static int handle_get_log(int client, const char *name) {
  if (!text_equals(name, "agent.log")) {
    return send_text(client, "ERR INVALID_ARTIFACT\n") < 0 ? -1 : 1;
  }
  return send_named_file(client, "LOG", name,
    "ux0:data/vitalab/agent.log");
}

static int handle_get_dump(int client, const char *name) {
  char full_path[MAX_FULL_PATH];
  int position;
  if (!valid_dump_name(name)) {
    return send_text(client, "ERR INVALID_ARTIFACT\n") < 0 ? -1 : 1;
  }
  position = append_text(full_path, sizeof(full_path), 0, "ux0:data/");
  if (position >= 0) position = append_text(full_path, sizeof(full_path), position, name);
  if (position < 0) return send_text(client, "ERR INVALID_ARTIFACT\n") < 0 ? -1 : 1;
  return send_named_file(client, "DUMP", name, full_path);
}

static int send_dump_entry(int client, const char *name,
    unsigned int size) {
  char reply[192];
  int position = append_text(reply, sizeof(reply), 0, "DUMP ");
  if (position >= 0) position = append_text(reply, sizeof(reply), position, name);
  if (position >= 0) position = append_text(reply, sizeof(reply), position, " ");
  if (position >= 0) position = append_unsigned(reply, sizeof(reply), position, size);
  if (position >= 0) position = append_text(reply, sizeof(reply), position, "\n");
  return position < 0 ? -1 : send_all(client, reply, position);
}

static int handle_list_dumps(int client) {
  SceUID directory = sceIoDopen("ux0:data");
  int result;
  if (directory < 0) return send_file_error(client, directory) < 0 ? -1 : 1;
  if (send_text(client, "OK DUMPS\n") < 0) {
    sceIoDclose(directory);
    return -1;
  }
  for (;;) {
    SceIoDirent entry;
    unsigned int index;
    unsigned char *bytes = (unsigned char *)&entry;
    for (index = 0; index < sizeof(entry); ++index) bytes[index] = 0;
    result = sceIoDread(directory, &entry);
    if (result <= 0) break;
    entry.d_name[sizeof(entry.d_name) - 1] = '\0';
    if (SCE_S_ISREG(entry.d_stat.st_mode) &&
        valid_dump_name(entry.d_name) &&
        entry.d_stat.st_size >= 0 &&
        entry.d_stat.st_size <= MAX_FILE_SIZE) {
      if (send_dump_entry(client, entry.d_name,
          (unsigned int)entry.d_stat.st_size) < 0) {
        sceIoDclose(directory);
        return -1;
      }
    }
  }
  sceIoDclose(directory);
  if (result < 0) return send_file_error(client, result) < 0 ? -1 : 1;
  return send_text(client, "END DUMPS\n") < 0 ? -1 : 1;
}

int vitalab_file_command(int client, const char *line) {
  if (starts_with(line, "PUT ")) return handle_put(client, line + 4);
  if (starts_with(line, "GET LOG ")) return handle_get_log(client, line + 8);
  if (starts_with(line, "GET DUMP ")) return handle_get_dump(client, line + 9);
  if (starts_with(line, "GET ")) return handle_get(client, line + 4);
  if (text_equals(line, "LIST DUMPS")) return handle_list_dumps(client);
  return VITALAB_FILE_NOT_HANDLED;
}
