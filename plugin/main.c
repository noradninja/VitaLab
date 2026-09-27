#include "protocol.h"
#include "commands.h"

#include <psp2/io/fcntl.h>
#include <psp2/io/stat.h>
#include <psp2/kernel/modulemgr.h>
#include <psp2/kernel/threadmgr.h>
#include <psp2/net/net.h>

#ifndef VITALAB_PORT
#define VITALAB_PORT 19600
#endif

#define STRINGIFY_INNER(value) #value
#define STRINGIFY(value) STRINGIFY_INNER(value)
#define REPLY_SIZE 256
#define RETRY_DELAY_US (2 * 1000 * 1000)
#define STARTUP_DELAY_US (3 * 1000 * 1000)

static volatile int g_running;
static volatile int g_server = -1;
static volatile int g_client = -1;
static SceUID g_thread = -1;

static int text_length(const char *text) {
  int length = 0;
  while (text[length] != '\0') {
    ++length;
  }
  return length;
}

static void log_record(const char *text, int length) {
  SceUID fd;

  sceIoMkdir("ux0:data/vitalab", 0777);
  fd = sceIoOpen("ux0:data/vitalab/agent.log",
    SCE_O_WRONLY | SCE_O_CREAT | SCE_O_APPEND, 0666);
  if (fd >= 0) {
    sceIoWrite(fd, text, (SceSize)length);
    sceIoClose(fd);
  }
}

static void log_text(const char *text) {
  log_record(text, text_length(text));
}

static void log_error(const char *prefix, int error) {
  static const char hex[] = "0123456789ABCDEF";
  char buffer[96];
  unsigned int value = (unsigned int)error;
  int position = 0;
  int shift;

  while (*prefix != '\0' && position < (int)sizeof(buffer) - 12) {
    buffer[position++] = *prefix++;
  }
  buffer[position++] = '0';
  buffer[position++] = 'x';
  for (shift = 28; shift >= 0; shift -= 4) {
    buffer[position++] = hex[(value >> shift) & 0xF];
  }
  buffer[position++] = '\n';
  log_record(buffer, position);
}

static int send_all(int socket_id, const char *data, int length) {
  int sent = 0;
  while (g_running && sent < length) {
    int result = sceNetSend(socket_id, data + sent,
      (unsigned int)(length - sent), 0);
    if (result <= 0) {
      return result;
    }
    sent += result;
  }
  return sent;
}

static void serve_client(int client) {
  char line[VITALAB_MAX_LINE + 1];
  char reply[REPLY_SIZE];
  int line_length = 0;
  int discarding = 0;

  while (g_running) {
    char input[128];
    int received = sceNetRecv(client, input, sizeof(input), 0);
    int index;
    if (received <= 0) {
      return;
    }

    for (index = 0; index < received; ++index) {
      char character = input[index];
      if (character == '\n') {
        int reply_length;
        if (discarding) {
          static const char too_long[] = "ERR LINE_TOO_LONG\n";
          if (send_all(client, too_long, (int)sizeof(too_long) - 1) <= 0) {
            return;
          }
        } else {
          if (line_length > 0 && line[line_length - 1] == '\r') {
            --line_length;
          }
          line[line_length] = '\0';
          reply_length = vitalab_command_reply(line, reply, sizeof(reply));
          if (reply_length == VITALAB_COMMAND_NOT_HANDLED) {
            reply_length = vitalab_protocol_reply(line, reply, sizeof(reply));
          }
          if (reply_length < 0 || reply_length >= (int)sizeof(reply) ||
              send_all(client, reply, reply_length) <= 0) {
            return;
          }
        }
        line_length = 0;
        discarding = 0;
      } else if (!discarding) {
        if (line_length < VITALAB_MAX_LINE) {
          line[line_length++] = character;
        } else {
          discarding = 1;
        }
      }
    }
  }
}

static int open_server(void) {
  SceNetSockaddrIn address;
  int server;
  int result;
  int reuse_address = 1;

  server = sceNetSocket("VitaLabAgent", SCE_NET_AF_INET,
    SCE_NET_SOCK_STREAM, 0);
  if (server < 0) {
    return server;
  }

  sceNetSetsockopt(server, SCE_NET_SOL_SOCKET, SCE_NET_SO_REUSEADDR,
    &reuse_address, sizeof(reuse_address));
  {
    unsigned char *bytes = (unsigned char *)&address;
    unsigned int index;
    for (index = 0; index < sizeof(address); ++index) {
      bytes[index] = 0;
    }
  }
  address.sin_len = sizeof(address);
  address.sin_family = SCE_NET_AF_INET;
  address.sin_port = sceNetHtons(VITALAB_PORT);
  address.sin_addr.s_addr = sceNetHtonl(SCE_NET_INADDR_ANY);

  result = sceNetBind(server, (const SceNetSockaddr *)&address,
    sizeof(address));
  if (result < 0) {
    sceNetSocketClose(server);
    return result;
  }
  result = sceNetListen(server, 4);
  if (result < 0) {
    sceNetSocketClose(server);
    return result;
  }
  return server;
}

static int server_thread(SceSize args, void *argp) {
  (void)args;
  (void)argp;

  sceKernelDelayThread(STARTUP_DELAY_US);
  log_text("loading build=" VITALAB_BUILD_ID " commit="
    VITALAB_GIT_COMMIT "\n");
  while (g_running) {
    int server = open_server();
    if (server < 0) {
      log_error("listener error=", server);
      sceKernelDelayThread(RETRY_DELAY_US);
      continue;
    }

    g_server = server;
    log_text("ready protocol=1 port=" STRINGIFY(VITALAB_PORT)
      " build=" VITALAB_BUILD_ID " commit=" VITALAB_GIT_COMMIT "\n");

    while (g_running) {
      int client = sceNetAccept(server, NULL, NULL);
      if (client < 0) {
        if (g_running) {
          log_error("accept error=", client);
        }
        break;
      }
      g_client = client;
      serve_client(client);
      sceNetSocketClose(client);
      g_client = -1;
    }

    sceNetSocketClose(server);
    g_server = -1;
    if (g_running) {
      sceKernelDelayThread(RETRY_DELAY_US);
    }
  }

  log_text("stopped\n");
  return 0;
}

int _start(SceSize argc, const void *args)
  __attribute__((weak, alias("module_start")));

int module_start(SceSize argc, const void *args) {
  int result;
  (void)argc;
  (void)args;

  if (g_running) {
    return SCE_KERNEL_START_SUCCESS;
  }

  g_running = 1;
  g_thread = sceKernelCreateThread("VitaLabServer", server_thread,
    0x40, 0x10000, 0, 0, NULL);
  if (g_thread < 0) {
    g_running = 0;
    return g_thread;
  }

  result = sceKernelStartThread(g_thread, 0, NULL);
  if (result < 0) {
    sceKernelDeleteThread(g_thread);
    g_thread = -1;
    g_running = 0;
    return result;
  }
  return SCE_KERNEL_START_SUCCESS;
}

int module_stop(SceSize argc, const void *args) {
  (void)argc;
  (void)args;

  g_running = 0;
  if (g_client >= 0) {
    sceNetShutdown(g_client, SCE_NET_SHUT_RDWR);
    sceNetSocketClose(g_client);
    g_client = -1;
  }
  if (g_server >= 0) {
    sceNetShutdown(g_server, SCE_NET_SHUT_RDWR);
    sceNetSocketClose(g_server);
    g_server = -1;
  }
  if (g_thread >= 0) {
    sceKernelWaitThreadEnd(g_thread, NULL, NULL);
    sceKernelDeleteThread(g_thread);
    g_thread = -1;
  }
  return SCE_KERNEL_STOP_SUCCESS;
}
