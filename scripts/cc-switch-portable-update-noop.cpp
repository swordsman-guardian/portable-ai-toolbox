#define WIN32_LEAN_AND_MEAN
#include <windows.h>

// Deliberately inert, short-lived child used only to satisfy the upstream
// opener's detached-process contract after its exact release URL is captured.
int wmain() {
  return 0;
}
