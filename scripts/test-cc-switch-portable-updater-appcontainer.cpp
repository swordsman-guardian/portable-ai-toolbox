#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <wchar.h>

int wmain(int argc, wchar_t** argv) {
  if (argc != 2) return 10;
  wchar_t imagePath[32768] = {};
  DWORD imageLength = GetModuleFileNameW(nullptr, imagePath, ARRAYSIZE(imagePath));
  if (!imageLength || imageLength >= ARRAYSIZE(imagePath)) return 18;
  HANDLE image = CreateFileW(imagePath, FILE_READ_ATTRIBUTES, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
      nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (image == INVALID_HANDLE_VALUE) return 19;
  wchar_t finalPath[32768] = {};
  DWORD finalLength = GetFinalPathNameByHandleW(image, finalPath, ARRAYSIZE(finalPath), 0);
  CloseHandle(image);
  if (!finalLength || finalLength >= ARRAYSIZE(finalPath)) return 20;
  wchar_t tempDir[32768]={};DWORD tempLength=GetTempPathW(ARRAYSIZE(tempDir),tempDir);
  if(!tempLength||tempLength>=ARRAYSIZE(tempDir))return 21;
  while(tempLength&&(tempDir[tempLength-1]==L'\\'||tempDir[tempLength-1]==L'/'))tempDir[--tempLength]=0;
  wchar_t batch[MAX_PATH]={};
  if(swprintf_s(batch,ARRAYSIZE(batch),L"%s\\cc_switch_tool_update_%lu.bat",tempDir,(unsigned long)GetCurrentProcessId())<0)return 22;
  HANDLE batchFile=CreateFileW(batch,GENERIC_WRITE,0,nullptr,CREATE_NEW,FILE_ATTRIBUTE_NORMAL,nullptr);
  if(batchFile==INVALID_HANDLE_VALUE)return 23;
  const char batchText[]="@echo off\r\nexit /b 0\r\n";DWORD batchWritten=0;
  BOOL batchOk=WriteFile(batchFile,batchText,sizeof(batchText)-1,&batchWritten,nullptr)&&batchWritten==sizeof(batchText)-1;CloseHandle(batchFile);
  if(!batchOk)return 24;
  wchar_t lifecycleSystemDir[MAX_PATH]={},lifecycleCmd[MAX_PATH]={},lifecycleCommand[32768]={};UINT systemLength=GetSystemDirectoryW(lifecycleSystemDir,ARRAYSIZE(lifecycleSystemDir));
  if(!systemLength||systemLength>=ARRAYSIZE(lifecycleSystemDir)||swprintf_s(lifecycleCmd,ARRAYSIZE(lifecycleCmd),L"%s\\cmd.exe",lifecycleSystemDir)<0||
      swprintf_s(lifecycleCommand,ARRAYSIZE(lifecycleCommand),L"\"%s\" /C \"%s\"",lifecycleCmd,batch)<0)return 25;
  STARTUPINFOW lifecycleStartup={};lifecycleStartup.cb=sizeof(lifecycleStartup);PROCESS_INFORMATION lifecycleProcess={};
  if(!CreateProcessW(lifecycleCmd,lifecycleCommand,nullptr,nullptr,FALSE,CREATE_NO_WINDOW,nullptr,nullptr,&lifecycleStartup,&lifecycleProcess))return 26;
  if(WaitForSingleObject(lifecycleProcess.hProcess,10000)!=WAIT_OBJECT_0){TerminateProcess(lifecycleProcess.hProcess,1);return 27;}
  DWORD lifecycleExit=1;GetExitCodeProcess(lifecycleProcess.hProcess,&lifecycleExit);CloseHandle(lifecycleProcess.hThread);CloseHandle(lifecycleProcess.hProcess);DeleteFileW(batch);
  if(lifecycleExit!=0)return 28;
  const wchar_t* gate = argv[1];
  for (unsigned i = 0; i < 300; ++i) {
    if (GetFileAttributesW(gate) != INVALID_FILE_ATTRIBUTES) break;
    Sleep(100);
    if (i == 299) return 12;
  }
  wchar_t systemDir[MAX_PATH] = {};
  UINT n = GetSystemDirectoryW(systemDir, ARRAYSIZE(systemDir));
  if (!n || n >= ARRAYSIZE(systemDir)) return 13;
  wchar_t cmd[MAX_PATH] = {};
  if (swprintf_s(cmd, ARRAYSIZE(cmd), L"%s\\cmd.exe", systemDir) < 0) return 14;
  wchar_t command[2048] = {};
  if (swprintf_s(command, ARRAYSIZE(command), L"\"%s\" /c start \"\" \"https://github.com/farion1231/cc-switch/releases/latest\"", cmd) < 0) return 15;
  STARTUPINFOW si = {};
  si.cb = sizeof(si);
  PROCESS_INFORMATION pi = {};
  if (!CreateProcessW(cmd, command, nullptr, nullptr, FALSE, CREATE_NO_WINDOW,
      nullptr, nullptr, &si, &pi)) return 16;
  WaitForSingleObject(pi.hProcess, 10000);
  DWORD exitCode = 1;
  GetExitCodeProcess(pi.hProcess, &exitCode);
  CloseHandle(pi.hThread);
  CloseHandle(pi.hProcess);
  if (exitCode != 0) return 17;
  Sleep(1000); // Keep parent alive while the owner validates its one-shot mailbox.
  return 0;
}
