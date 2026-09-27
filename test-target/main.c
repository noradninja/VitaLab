#include <psp2/ctrl.h>
#include <psp2/kernel/processmgr.h>
#include <psp2/kernel/threadmgr.h>

#include "debugScreen.h"

#define printf psvDebugScreenPrintf

int main(void) {
  SceCtrlData pad;
  unsigned int seconds = 0;

  psvDebugScreenInit();
  sceCtrlSetSamplingMode(SCE_CTRL_MODE_DIGITAL);
  printf("VitaLab application-control target\n\n");
  printf("Title ID: VLAB00210\n");
  printf("Waiting for remote STOP...\n");
  printf("Press X to exit manually.\n\n");

  for (;;) {
    sceCtrlPeekBufferPositive(0, &pad, 1);
    if ((pad.buttons & SCE_CTRL_CROSS) != 0) {
      break;
    }
    sceKernelDelayThread(1000 * 1000);
    ++seconds;
    printf("Alive: %u seconds\n", seconds);
  }

  sceKernelExitProcess(0);
  return 0;
}
