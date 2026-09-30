#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdio.h>
#include <string.h>

typedef BOOL (WINAPI *InstallFn)(void*);
struct HookConfigHeader { DWORD byteSize, counts[8]; };

static bool FinalPath(const wchar_t* path,DWORD flags,wchar_t* out,DWORD cap,bool directory) {
  HANDLE h=CreateFileW(path,FILE_READ_ATTRIBUTES,FILE_SHARE_READ|FILE_SHARE_WRITE|FILE_SHARE_DELETE,nullptr,OPEN_EXISTING,
      directory?FILE_FLAG_BACKUP_SEMANTICS:0,nullptr);
  if(h==INVALID_HANDLE_VALUE)return false;
  DWORD n=GetFinalPathNameByHandleW(h,out,cap,flags);CloseHandle(h);return n>0&&n<cap;
}

static bool ReadAll(const wchar_t* path, char* out, DWORD cap, DWORD* length) {
  HANDLE f = CreateFileW(path, GENERIC_READ, FILE_SHARE_READ, nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (f == INVALID_HANDLE_VALUE) return false;
  DWORD got = 0;
  BOOL ok = ReadFile(f, out, cap - 1, &got, nullptr);
  CloseHandle(f);
  if (!ok) return false;
  out[got] = 0;
  *length = got;
  return true;
}

int wmain(int argc, wchar_t** argv) {
  if (argc != 4) return 10;
  const bool invalidPath = _wcsicmp(argv[2], L"invalid-path") == 0;
  const bool invalidNonce = _wcsicmp(argv[2], L"invalid-nonce") == 0;
  const bool nonmatching = _wcsicmp(argv[2], L"nonmatching") == 0;
  const bool lifecycle = _wcsicmp(argv[2], L"lifecycle") == 0;
  wchar_t root[MAX_PATH] = {};
  if (wcscpy_s(root, argv[3]) != 0) return 11;
  wchar_t app[MAX_PATH] = {}, runtime[MAX_PATH] = {}, updates[MAX_PATH] = {};
  wchar_t mailbox[MAX_PATH] = {}, noop[MAX_PATH] = {}, dosRoot[32768]={},ntRoot[32768]={},dosExe[32768]={},ntExe[32768]={},acTemp[32768]={};
  swprintf_s(app, ARRAYSIZE(app), L"%s\\app", root);
  swprintf_s(runtime, ARRAYSIZE(runtime), L"%s\\runtime", root);
  swprintf_s(updates, ARRAYSIZE(updates), L"%s\\runtime\\updates", root);
  swprintf_s(acTemp,ARRAYSIZE(acTemp),L"%s\\ac-temp",root);
  swprintf_s(mailbox, ARRAYSIZE(mailbox), L"%s\\runtime\\updates\\%s", root,
      invalidPath ? L"wrong-name" : L"portable-update.request");
  swprintf_s(noop, ARRAYSIZE(noop), L"%s\\app\\cc-switch-portable-update-noop.exe", root);
  CreateDirectoryW(root, nullptr); CreateDirectoryW(app, nullptr); CreateDirectoryW(runtime, nullptr); CreateDirectoryW(updates, nullptr);CreateDirectoryW(acTemp,nullptr);
  if (GetFileAttributesW(noop) == INVALID_FILE_ATTRIBUTES) return 12;
  if(!FinalPath(root,0,dosRoot,ARRAYSIZE(dosRoot),true) || !FinalPath(root,2,ntRoot,ARRAYSIZE(ntRoot),true))return 13;
  swprintf_s(dosExe,ARRAYSIZE(dosExe),L"%s\\app\\cc-switch.exe",dosRoot);
  swprintf_s(ntExe,ARRAYSIZE(ntExe),L"%s\\app\\cc-switch.exe",ntRoot);

  const wchar_t nonce[] = L"0123456789abcdef0123456789abcdef";
  const wchar_t badNonce[] = L"not-a-valid-nonce";
  const wchar_t* configuredNonce = invalidNonce ? badNonce : nonce;
  HMODULE shim = LoadLibraryW(argv[1]);
  if (!shim) return 14;
  auto install = (InstallFn)GetProcAddress(shim, "CCSU_InstallOpenerHook");
  const wchar_t* strings[8]={mailbox,configuredNonce,noop,dosRoot,ntRoot,dosExe,ntExe,acTemp};
  DWORD counts[8]={};for(unsigned i=0;i<8;i++)counts[i]=(DWORD)wcslen(strings[i])+1;
  const size_t configSize = sizeof(HookConfigHeader) + sizeof(wchar_t) * (counts[0]+counts[1]+counts[2]+counts[3]+counts[4]+counts[5]+counts[6]+counts[7]);
  BYTE* configMemory = new BYTE[configSize]();
  auto config = (HookConfigHeader*)configMemory;
  config->byteSize = (DWORD)configSize;
  for(unsigned i=0;i<8;i++)config->counts[i]=counts[i];
  wchar_t* values = (wchar_t*)(configMemory + sizeof(HookConfigHeader));
  size_t offset=0;for(unsigned i=0;i<8;i++){wcscpy_s(values+offset,config->counts[i],strings[i]);offset+=config->counts[i];}
  if (!install) return 15;
  if (invalidNonce || invalidPath) {
    const BOOL accepted = install(config);
    delete[] configMemory;
    if (accepted || GetFileAttributesW(mailbox) != INVALID_FILE_ATTRIBUTES) return 20;
    wprintf(L"PASS: malformed nonce/path rejected during hook setup.\n");
    return 0;
  }
  if (!install(config)) return 15;
  delete[] configMemory;
  HANDLE image=CreateFileW(argv[0],FILE_READ_ATTRIBUTES,FILE_SHARE_READ|FILE_SHARE_WRITE|FILE_SHARE_DELETE,nullptr,OPEN_EXISTING,FILE_ATTRIBUTE_NORMAL,nullptr);
  if(image==INVALID_HANDLE_VALUE)return 16;
  wchar_t finalPath[32768]={};DWORD finalLength=GetFinalPathNameByHandleW(image,finalPath,ARRAYSIZE(finalPath),0);CloseHandle(image);
  if(!finalLength||finalLength>=ARRAYSIZE(finalPath))return 17;

  wchar_t systemDir[MAX_PATH] = {}, cmd[MAX_PATH] = {}, line[2048] = {};
  UINT n = GetSystemDirectoryW(systemDir, ARRAYSIZE(systemDir));
  if (!n || n >= ARRAYSIZE(systemDir)) return 21;
  swprintf_s(cmd, ARRAYSIZE(cmd), L"%s\\cmd.exe", systemDir);
  if (nonmatching) swprintf_s(line, ARRAYSIZE(line), L"\"%s\" /c exit 0", cmd);
  else swprintf_s(line, ARRAYSIZE(line), L"cmd /c start \"\" \"https://github.com/farion1231/cc-switch/releases/latest\"");
  if(lifecycle) {
    if(!SetEnvironmentVariableW(L"TEMP",acTemp)||!SetEnvironmentVariableW(L"TMP",acTemp))return 28;
    wchar_t actualTemp[MAX_PATH]={};DWORD tn=GetTempPathW(ARRAYSIZE(actualTemp),actualTemp);if(!tn||tn>=ARRAYSIZE(actualTemp))return 29;
    while(tn&&(actualTemp[tn-1]==L'\\'||actualTemp[tn-1]==L'/'))actualTemp[--tn]=0;
    if(_wcsicmp(actualTemp,acTemp)!=0)return 30;
    wchar_t batch[MAX_PATH]={};swprintf_s(batch,ARRAYSIZE(batch),L"%s\\cc_switch_tool_update_%lu.bat",acTemp,(unsigned long)GetCurrentProcessId());
    HANDLE bf=CreateFileW(batch,GENERIC_WRITE,0,nullptr,CREATE_NEW,FILE_ATTRIBUTE_NORMAL,nullptr);if(bf==INVALID_HANDLE_VALUE)return 31;
    const char body[]="@echo off\r\nexit /b 0\r\n";DWORD wrote=0;BOOL written=WriteFile(bf,body,sizeof(body)-1,&wrote,nullptr)&&wrote==sizeof(body)-1;CloseHandle(bf);if(!written)return 32;
    swprintf_s(line,ARRAYSIZE(line),L"\"%s\" /C \"%s\"",cmd,batch);
  }
  STARTUPINFOW si = {}; si.cb = sizeof(si);
  PROCESS_INFORMATION pi = {};
  if (!CreateProcessW(cmd, line, nullptr, nullptr, FALSE, CREATE_NO_WINDOW, nullptr, nullptr, &si, &pi)) return 22;
  if (WaitForSingleObject(pi.hProcess, 10000) != WAIT_OBJECT_0) { TerminateProcess(pi.hProcess, 1); return 23; }
  DWORD exitCode = 1; GetExitCodeProcess(pi.hProcess, &exitCode);
  CloseHandle(pi.hThread); CloseHandle(pi.hProcess);
  if (exitCode != 0) return 24;
  if(lifecycle) {
    wchar_t marker[MAX_PATH]={};swprintf_s(marker,ARRAYSIZE(marker),L"%s\\native-lifecycle-call.hit",updates);
    if(GetFileAttributesW(marker)==INVALID_FILE_ATTRIBUTES)return 33;
    DeleteFileW(marker);
    wchar_t batch[MAX_PATH]={};swprintf_s(batch,ARRAYSIZE(batch),L"%s\\cc_switch_tool_update_%lu.bat",acTemp,(unsigned long)GetCurrentProcessId());DeleteFileW(batch);
    wprintf(L"PASS: exact owned-temp lifecycle batch was rewritten to the bounded cmd call form.\n");return 0;
  }
  if (nonmatching) {
    if (GetFileAttributesW(mailbox) != INVALID_FILE_ATTRIBUTES) return 25;
    wprintf(L"PASS: unrelated cmd command passed through without an updater event.\n");
    return 0;
  }
  char actual[512] = {}; DWORD size = 0;
  if (!ReadAll(mailbox, actual, sizeof(actual), &size)) return 26;
  char expected[256] = {};
  sprintf_s(expected, sizeof(expected), "{\"schema\":1,\"kind\":\"portableUpdateRequested\",\"pid\":%lu,\"nonce\":\"0123456789abcdef0123456789abcdef\"}\n", (unsigned long)GetCurrentProcessId());
  if (size != strlen(expected) || memcmp(actual, expected, strlen(expected)) != 0) return 27;
  wprintf(L"PASS: exact cmd opener command emitted a one-shot request and spawned the inert child.\n");
  return 0;
}
