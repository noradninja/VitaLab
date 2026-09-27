#include <psp2/ctrl.h>
#include <psp2/kernel/modulemgr.h>
#include <psp2/kernel/processmgr.h>
#include <psp2/kernel/threadmgr.h>
#include <psp2/net/net.h>
#include <psp2/sysmodule.h>

#include "debugScreen.h"

#define printf psvDebugScreenPrintf
#define NET_MEMORY_SIZE (1024 * 1024)

static unsigned char g_net_memory[NET_MEMORY_SIZE] __attribute__((aligned(64)));

static void wait_for_cross(void) {
  SceCtrlData pad;
  sceCtrlSetSamplingMode(SCE_CTRL_MODE_DIGITAL);
  for (;;) {
    sceCtrlPeekBufferPositive(0, &pad, 1);
    if ((pad.buttons & SCE_CTRL_CROSS) != 0) {
      return;
    }
    sceKernelDelayThread(50 * 1000);
  }
}

int main(void) {
  SceNetInitParam net_init = {
    .memory = g_net_memory,
    .size = sizeof(g_net_memory),
    .flags = 0,
  };
  SceUID module_id = -1;
  int load_status = 0;
  int load_result;
  int net_result;
  int sysmodule_result;

  psvDebugScreenInit();
  printf("VitaLab user-plugin safety test\n\n");
  printf("This app does not modify taiHEN config.txt.\n\n");

  sysmodule_result = sceSysmoduleLoadModule(SCE_SYSMODULE_NET);
  printf("SceNet module:  0x%08X\n", (unsigned int)sysmodule_result);
  if (sysmodule_result < 0) {
    printf("FAILED before loading the VitaLab plugin.\n");
    printf("\nPress X to exit.\n");
    wait_for_cross();
    sceKernelExitProcess(1);
  }

  net_result = sceNetInit(&net_init);
  printf("SceNet init:    0x%08X\n", (unsigned int)net_result);
  if (net_result < 0) {
    printf("FAILED before loading the VitaLab plugin.\n");
    printf("\nPress X to exit.\n");
    wait_for_cross();
    sceKernelExitProcess(1);
  }

  load_result = sceKernelLoadStartModule("app0:vitalab.suprx", 0, NULL,
    0, NULL, &load_status);
  if (load_result >= 0) {
    module_id = load_result;
  }
  printf("Plugin module:  0x%08X\n", (unsigned int)load_result);
  printf("Start status:   0x%08X\n", (unsigned int)load_status);

  if (module_id >= 0 && load_status >= 0) {
    printf("\nLOADED: wait five seconds, then run the host test.\n");
    printf("The TCP listener should be on port 19600.\n");
  } else {
    printf("\nFAILED: plugin did not start.\n");
  }

  printf("\nPress X to unload the plugin and exit.\n");
  wait_for_cross();

  if (module_id >= 0) {
    int stop_status = 0;
    int stop_result = sceKernelStopUnloadModule(module_id, 0, NULL, 0,
      NULL, &stop_status);
    printf("Unload result:  0x%08X\n", (unsigned int)stop_result);
    printf("Stop status:    0x%08X\n", (unsigned int)stop_status);
  }
  sceNetTerm();
  sceSysmoduleUnloadModule(SCE_SYSMODULE_NET);
  sceKernelExitProcess(0);
  return 0;
}
