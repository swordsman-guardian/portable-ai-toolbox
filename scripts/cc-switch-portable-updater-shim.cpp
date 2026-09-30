#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <shellapi.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

// In-memory-only interception for the owned CC Switch child process. The on-disk
// upstream executable is never patched. The parent provides an absolute mailbox
// filename ending in "portable-update.request" and a per-launch nonce.
static const wchar_t kUpdateUrl[] = L"https://github.com/farion1231/cc-switch/releases/latest";
static wchar_t g_mailbox[32768] = {};
static wchar_t g_nonce[33] = {};
static wchar_t g_ownedNtRoot[32768] = {};
static wchar_t g_ownedDosRoot[32768] = {};
static wchar_t g_expectedNtExe[32768] = {};
static wchar_t g_expectedDosExe[32768] = {};
static wchar_t g_expectedAcTemp[32768] = {};
static void WriteFixedDiagnostic(const wchar_t* leaf);

typedef BOOL (WINAPI *ShellExecuteExWFn)(SHELLEXECUTEINFOW*);
typedef HINSTANCE (WINAPI *ShellExecuteWFn)(HWND, LPCWSTR, LPCWSTR, LPCWSTR, LPCWSTR, INT);
typedef BOOL (WINAPI *CreateProcessWFn)(LPCWSTR, LPWSTR, LPSECURITY_ATTRIBUTES, LPSECURITY_ATTRIBUTES, BOOL, DWORD, LPVOID, LPCWSTR, LPSTARTUPINFOW, LPPROCESS_INFORMATION);
typedef DWORD (WINAPI *GetFinalPathNameByHandleWFn)(HANDLE, LPWSTR, DWORD, DWORD);
static ShellExecuteExWFn g_original = nullptr;
static ShellExecuteWFn g_originalShellExecuteW = nullptr;
static CreateProcessWFn g_originalCreateProcessW = nullptr;
static GetFinalPathNameByHandleWFn g_originalFinalPath = nullptr;
static volatile LONG g_installed = 0;
static volatile LONG g_createProcessPatched = 0;
static volatile LONG g_finalPathPatched = 0;
static wchar_t g_noopExe[32768] = {};

static bool IsUnderOwnedRoot(const wchar_t* value, const wchar_t* root) {
  const size_t n=wcslen(root);
  if(wcslen(value)<n) return false;
  return _wcsnicmp(value,root,n)==0 && (value[n]==L'\\' || value[n]==0);
}

static bool IsOwnedTempTreePlain() {
  if(wcsncmp(g_ownedDosRoot,L"\\\\?\\",4)!=0)return false;
  const wchar_t* root=g_ownedDosRoot+4;
  if(!IsUnderOwnedRoot(g_expectedAcTemp,root))return false;
  wchar_t current[32768]={};
  if(wcscpy_s(current,ARRAYSIZE(current),g_expectedAcTemp)!=0)return false;
  for(;;) {
    DWORD attributes=GetFileAttributesW(current);
    if(attributes==INVALID_FILE_ATTRIBUTES || !(attributes&FILE_ATTRIBUTE_DIRECTORY) || (attributes&FILE_ATTRIBUTE_REPARSE_POINT))return false;
    if(_wcsicmp(current,root)==0)return true;
    wchar_t* slash=wcsrchr(current,L'\\');
    if(!slash || slash<current+2)return false;
    *slash=0;
    if(!IsUnderOwnedRoot(current,root))return false;
  }
}

static DWORD WINAPI HookGetFinalPathNameByHandleW(HANDLE file, LPWSTR path, DWORD pathChars, DWORD flags) {
  if (!g_originalFinalPath) { SetLastError(ERROR_PROC_NOT_FOUND); return 0; }
  DWORD result=g_originalFinalPath(file,path,pathChars,flags);
  if (result!=0 || flags!=0 || GetLastError()!=ERROR_ACCESS_DENIED) return result;
  const DWORD originalError=ERROR_ACCESS_DENIED;
  wchar_t actualNt[32768]={};
  DWORD ntChars=g_originalFinalPath(file,actualNt,ARRAYSIZE(actualNt),VOLUME_NAME_NT);
  if (!ntChars || ntChars>=ARRAYSIZE(actualNt) || !IsUnderOwnedRoot(actualNt,g_ownedNtRoot) ||
      _wcsicmp(actualNt,g_expectedNtExe)!=0 || !IsUnderOwnedRoot(g_expectedDosExe,g_ownedDosRoot)) {
    SetLastError(originalError); return 0;
  }
  const wchar_t* relative=actualNt+wcslen(g_ownedNtRoot);
  if (!*relative || *relative!=L'\\') { SetLastError(originalError); return 0; }
  wchar_t mapped[32768]={};
  if (swprintf_s(mapped,ARRAYSIZE(mapped),L"%s%s",g_ownedDosRoot,relative)<0 ||
      _wcsicmp(mapped,g_expectedDosExe)!=0) { SetLastError(originalError); return 0; }
  const DWORD chars=(DWORD)wcslen(mapped);
  if (!path || pathChars<=chars) { SetLastError(ERROR_SUCCESS); return chars+1; }
  memcpy(path,mapped,(chars+1)*sizeof(wchar_t));
  WriteFixedDiagnostic(L"finalpath-owned-fallback.hit");
  SetLastError(ERROR_SUCCESS);
  return chars;
}

static bool ValidHexNonce(const wchar_t* value) {
  if (wcslen(value) != 32) return false;
  for (const wchar_t* p = value; *p; ++p) {
    if (!((*p >= L'0' && *p <= L'9') || (*p >= L'a' && *p <= L'f'))) return false;
  }
  return true;
}

static bool WriteRequestMailbox() {
  if (!g_mailbox[0] || !ValidHexNonce(g_nonce)) {
    SetLastError(ERROR_INVALID_PARAMETER);
    return false;
  }
  const size_t pathLen = wcslen(g_mailbox);
  const wchar_t suffix[] = L"portable-update.request";
  const size_t suffixLen = ARRAYSIZE(suffix) - 1;
  if (pathLen <= suffixLen || _wcsicmp(g_mailbox + pathLen - suffixLen, suffix) != 0) {
    SetLastError(ERROR_INVALID_NAME);
    return false;
  }

  HANDLE file = CreateFileW(g_mailbox, GENERIC_WRITE, 0, nullptr, CREATE_NEW,
                            FILE_ATTRIBUTE_NORMAL | FILE_FLAG_WRITE_THROUGH, nullptr);
  if (file == INVALID_HANDLE_VALUE) return false;

  char event[256] = {};
  char nonceAscii[33] = {};
  for (size_t i = 0; i < 32; ++i) nonceAscii[i] = (char)g_nonce[i];
  const int formatted = sprintf_s(event, sizeof(event),
      "{\"schema\":1,\"kind\":\"portableUpdateRequested\",\"pid\":%lu,\"nonce\":\"%s\"}\n",
      (unsigned long)GetCurrentProcessId(), nonceAscii);
  if (formatted <= 0) {
    CloseHandle(file);
    DeleteFileW(g_mailbox);
    SetLastError(ERROR_INVALID_DATA);
    return false;
  }
  DWORD written = 0;
  const DWORD expected = (DWORD)strlen(event);
  const BOOL ok = WriteFile(file, event, expected, &written, nullptr) && written == expected && FlushFileBuffers(file);
  const DWORD error = ok ? ERROR_SUCCESS : GetLastError();
  CloseHandle(file);
  if (!ok) {
    DeleteFileW(g_mailbox);
    SetLastError(error);
    return false;
  }
  SetLastError(ERROR_SUCCESS);
  return true;
}

static void WriteFixedDiagnostic(const wchar_t* leaf) {
  const wchar_t suffix[] = L"portable-update.request";
  const size_t pathLen = wcslen(g_mailbox), suffixLen = ARRAYSIZE(suffix) - 1;
  if (pathLen <= suffixLen) return;
  wchar_t path[32768] = {};
  const size_t directoryLen = pathLen - suffixLen;
  if (directoryLen + wcslen(leaf) + 1 >= ARRAYSIZE(path)) return;
  memcpy(path, g_mailbox, directoryLen * sizeof(wchar_t));
  wcscpy_s(path + directoryLen, ARRAYSIZE(path) - directoryLen, leaf);
  HANDLE file = CreateFileW(path, GENERIC_WRITE, FILE_SHARE_READ, nullptr, CREATE_NEW,
                            FILE_ATTRIBUTE_NORMAL | FILE_FLAG_WRITE_THROUGH, nullptr);
  if (file == INVALID_HANDLE_VALUE) return;
  static const char marker[] = "hook-v1\n";
  DWORD written = 0;
  WriteFile(file, marker, sizeof(marker) - 1, &written, nullptr);
  FlushFileBuffers(file);
  CloseHandle(file);
}

static BOOL WINAPI HookShellExecuteExW(SHELLEXECUTEINFOW* info) {
  if (info && info->lpFile && _wcsicmp(info->lpFile, kUpdateUrl) == 0) {
    if (!WriteRequestMailbox()) return FALSE;
    info->hInstApp = (HINSTANCE)(INT_PTR)33;
    info->hProcess = nullptr;
    SetLastError(ERROR_SUCCESS);
    return TRUE;
  }
  return g_original ? g_original(info) : FALSE;
}

static HINSTANCE WINAPI HookShellExecuteW(HWND window, LPCWSTR verb, LPCWSTR file,
                                         LPCWSTR parameters, LPCWSTR directory, INT show) {
  if (file && _wcsicmp(file, kUpdateUrl) == 0) {
    if (!WriteRequestMailbox()) return (HINSTANCE)(INT_PTR)SE_ERR_ACCESSDENIED;
    SetLastError(ERROR_SUCCESS);
    return (HINSTANCE)(INT_PTR)33;
  }
  return g_originalShellExecuteW ? g_originalShellExecuteW(window, verb, file, parameters, directory, show) :
                                  (HINSTANCE)(INT_PTR)SE_ERR_DLLNOTFOUND;
}

static bool IsWhitespace(wchar_t c) { return c == L' ' || c == L'\t'; }

static LPCWSTR SkipWhitespace(LPCWSTR p) { while (*p && IsWhitespace(*p)) ++p; return p; }

static bool MatchToken(LPCWSTR* cursor, LPCWSTR expected) {
  LPCWSTR p = SkipWhitespace(*cursor);
  LPCWSTR start = p;
  if (*p == L'"') {
    ++p; start = p;
    while (*p && *p != L'"') ++p;
    if (*p != L'"') return false;
    size_t n = (size_t)(p - start);
    if (wcslen(expected) != n || _wcsnicmp(start, expected, n) != 0) return false;
    ++p;
  } else {
    while (*p && !IsWhitespace(*p)) ++p;
    size_t n = (size_t)(p - start);
    if (wcslen(expected) != n || _wcsnicmp(start, expected, n) != 0) return false;
  }
  if (*p && !IsWhitespace(*p)) return false;
  *cursor = p;
  return true;
}

static bool IsExpectedSystemCmd(LPCWSTR application) {
  wchar_t systemDir[MAX_PATH] = {};
  UINT length = GetSystemDirectoryW(systemDir, ARRAYSIZE(systemDir));
  if (!length || length >= ARRAYSIZE(systemDir)) return false;
  wchar_t expectedCmd[MAX_PATH] = {};
  if (swprintf_s(expectedCmd, ARRAYSIZE(expectedCmd), L"%s\\cmd.exe", systemDir) < 0 ||
      (application && _wcsicmp(application, expectedCmd) != 0)) return false;
  return true;
}

static bool IsFixedUpdaterCommand(LPCWSTR application, LPCWSTR commandLine, bool* appCmd, bool* hasC, bool* hasUrl) {
  if (appCmd) *appCmd = IsExpectedSystemCmd(application);
  if (hasC) *hasC = false;
  if (hasUrl) *hasUrl = commandLine && wcsstr(commandLine, kUpdateUrl) != nullptr;
  if (!commandLine || (application && !IsExpectedSystemCmd(application))) return false;
  wchar_t systemDir[MAX_PATH] = {};
  UINT length = GetSystemDirectoryW(systemDir, ARRAYSIZE(systemDir));
  if (!length || length >= ARRAYSIZE(systemDir)) return false;
  wchar_t expectedCmd[MAX_PATH] = {};
  if (swprintf_s(expectedCmd, ARRAYSIZE(expectedCmd), L"%s\\cmd.exe", systemDir) < 0) return false;
  LPCWSTR p = commandLine;
  if (!MatchToken(&p, expectedCmd) && !MatchToken(&p, L"cmd.exe") && !MatchToken(&p, L"cmd")) return false;
  if (hasC) *hasC = MatchToken(&p, L"/c");
  else if (!MatchToken(&p, L"/c")) return false;
  if (!hasC || *hasC) {
    if (
      !MatchToken(&p, L"start") || !MatchToken(&p, L"") ||
      !MatchToken(&p, kUpdateUrl)) return false;
    return *SkipWhitespace(p) == 0;
  }
  return false;
}

static bool ReadToken(LPCWSTR* cursor, wchar_t* output, size_t capacity) {
  LPCWSTR p=SkipWhitespace(*cursor); size_t n=0;
  if(*p==L'"') { ++p; while(*p && *p!=L'"') { if(n+1>=capacity)return false; output[n++]=*p++; } if(*p!=L'"')return false; ++p; }
  else { while(*p && !IsWhitespace(*p)) { if(n+1>=capacity)return false; output[n++]=*p++; } }
  output[n]=0; if(*p && !IsWhitespace(*p))return false; *cursor=p; return n>0;
}

static bool IsFixedLifecycleCommand(LPCWSTR application,LPCWSTR commandLine,wchar_t* batchPath,size_t capacity) {
  if(!application || !commandLine || !IsExpectedSystemCmd(application) || !batchPath || capacity<2)return false;
  wchar_t systemDir[MAX_PATH]={},expectedCmd[MAX_PATH]={}; UINT n=GetSystemDirectoryW(systemDir,ARRAYSIZE(systemDir));
  if(!n || n>=ARRAYSIZE(systemDir) || swprintf_s(expectedCmd,ARRAYSIZE(expectedCmd),L"%s\\cmd.exe",systemDir)<0)return false;
  LPCWSTR p=commandLine; wchar_t token[32768]={};
  if(!ReadToken(&p,token,ARRAYSIZE(token)) || (_wcsicmp(token,expectedCmd)!=0 && _wcsicmp(token,L"cmd.exe")!=0 && _wcsicmp(token,L"cmd")!=0))return false;
  if(!MatchToken(&p,L"/c"))return false;
  if(!ReadToken(&p,batchPath,capacity) || *SkipWhitespace(p)!=0)return false;
  if(wcspbrk(batchPath,L"%\r\n\"")!=nullptr)return false;
  wchar_t processTemp[32768]={}; DWORD got=GetTempPathW(ARRAYSIZE(processTemp),processTemp);
  if(!got || got>=ARRAYSIZE(processTemp))return false;
  while(got && (processTemp[got-1]==L'\\' || processTemp[got-1]==L'/'))processTemp[--got]=0;
  if(_wcsicmp(processTemp,g_expectedAcTemp)!=0 || !IsOwnedTempTreePlain())return false;
  DWORD pathAttrs=GetFileAttributesW(batchPath);
  if(pathAttrs==INVALID_FILE_ATTRIBUTES || (pathAttrs&FILE_ATTRIBUTE_DIRECTORY) || (pathAttrs&FILE_ATTRIBUTE_REPARSE_POINT))return false;
  const wchar_t* leaf=wcsrchr(batchPath,L'\\'); if(!leaf)return false; ++leaf;
  wchar_t expected[128]={}; DWORD pid=GetCurrentProcessId();
  if(swprintf_s(expected,ARRAYSIZE(expected),L"cc_switch_tool_install_%lu.bat",(unsigned long)pid)<0 &&
     swprintf_s(expected,ARRAYSIZE(expected),L"cc_switch_tool_update_%lu.bat",(unsigned long)pid)<0)return false;
  bool nameOk=false;
  if(_wcsicmp(leaf,expected)==0)nameOk=true;
  if(!nameOk && swprintf_s(expected,ARRAYSIZE(expected),L"cc_switch_tool_update_%lu.bat",(unsigned long)pid)>=0 && _wcsicmp(leaf,expected)==0)nameOk=true;
  if(!nameOk && swprintf_s(expected,ARRAYSIZE(expected),L"cc_switch_tool_install_%lu.bat",(unsigned long)pid)>=0 && _wcsicmp(leaf,expected)==0)nameOk=true;
  wchar_t expectedPath[32768]={};
  return nameOk && swprintf_s(expectedPath,ARRAYSIZE(expectedPath),L"%s\\%s",g_expectedAcTemp,leaf)>=0 && _wcsicmp(batchPath,expectedPath)==0;
}

static BOOL WINAPI HookCreateProcessW(LPCWSTR application, LPWSTR commandLine,
    LPSECURITY_ATTRIBUTES processAttributes, LPSECURITY_ATTRIBUTES threadAttributes,
    BOOL inheritHandles, DWORD creationFlags, LPVOID environment, LPCWSTR currentDirectory,
    LPSTARTUPINFOW startupInfo, LPPROCESS_INFORMATION processInfo) {
  bool appCmd=false, hasC=false, hasUrl=false;
  const bool fixedUpdate = IsFixedUpdaterCommand(application, commandLine, &appCmd, &hasC, &hasUrl);
  wchar_t diagnostic[64] = {};
  swprintf_s(diagnostic, ARRAYSIZE(diagnostic), L"createprocess-a%d-c%d-u%d.hit", appCmd?1:0, hasC?1:0, hasUrl?1:0);
  WriteFixedDiagnostic(diagnostic);
  wchar_t lifecycleBatch[32768]={};
  if(IsFixedLifecycleCommand(application,commandLine,lifecycleBatch,ARRAYSIZE(lifecycleBatch))) {
    wchar_t rewritten[32768]={};
    if(swprintf_s(rewritten,ARRAYSIZE(rewritten),L"\"%s\" /D /S /C call \"%s\"",application,lifecycleBatch)<0) { SetLastError(ERROR_INSUFFICIENT_BUFFER); return FALSE; }
    if(!g_originalCreateProcessW) { SetLastError(ERROR_PROC_NOT_FOUND); return FALSE; }
    BOOL ok=g_originalCreateProcessW(application,rewritten,processAttributes,threadAttributes,inheritHandles,creationFlags,environment,currentDirectory,startupInfo,processInfo);
    if(ok) WriteFixedDiagnostic(L"native-lifecycle-call.hit");
    return ok;
  }
  if (!fixedUpdate)
    return g_originalCreateProcessW ? g_originalCreateProcessW(application, commandLine,
      processAttributes, threadAttributes, inheritHandles, creationFlags, environment,
      currentDirectory, startupInfo, processInfo) : FALSE;

  if (!processInfo || !g_noopExe[0]) { SetLastError(ERROR_INVALID_PARAMETER); return FALSE; }
  DWORD attributes = GetFileAttributesW(g_noopExe);
  if (attributes == INVALID_FILE_ATTRIBUTES || (attributes & FILE_ATTRIBUTE_DIRECTORY) || (attributes & FILE_ATTRIBUTE_REPARSE_POINT)) {
    SetLastError(ERROR_BAD_PATHNAME); return FALSE;
  }
  STARTUPINFOW si = {};
  si.cb = sizeof(si);
  si.dwFlags = STARTF_USESHOWWINDOW;
  si.wShowWindow = SW_HIDE;
  PROCESS_INFORMATION child = {};
  wchar_t childCommand[32768] = {};
  if (swprintf_s(childCommand, ARRAYSIZE(childCommand), L"\"%s\"", g_noopExe) < 0) {
    SetLastError(ERROR_INSUFFICIENT_BUFFER); return FALSE;
  }
  // Start a trusted, inert sibling process so Rust receives genuine process and
  // thread handles. It inherits the current AppContainer and Job membership.
  if (!g_originalCreateProcessW(g_noopExe, childCommand, nullptr, nullptr, FALSE,
      CREATE_NO_WINDOW, nullptr, nullptr, &si, &child)) return FALSE;
  if (!WriteRequestMailbox()) {
    DWORD error = GetLastError();
    TerminateProcess(child.hProcess, 1);
    CloseHandle(child.hThread); CloseHandle(child.hProcess);
    SetLastError(error); return FALSE;
  }
  WriteFixedDiagnostic(L"native-opener-command.hit");
  *processInfo = child;
  SetLastError(ERROR_SUCCESS);
  return TRUE;
}

static bool PatchImportSlot(IMAGE_THUNK_DATA* slot, PVOID replacement) {
  DWORD oldProtect = 0;
  if (!VirtualProtect(&slot->u1.Function, sizeof(void*), PAGE_READWRITE, &oldProtect)) return false;
  InterlockedExchangePointer((PVOID volatile*)&slot->u1.Function, replacement);
  DWORD ignored = 0;
  VirtualProtect(&slot->u1.Function, sizeof(void*), oldProtect, &ignored);
  return true;
}

static bool PatchModule(HMODULE module) {
  if (!module) return false;
  auto base = (BYTE*)module;
  auto dos = (IMAGE_DOS_HEADER*)base;
  if (dos->e_magic != IMAGE_DOS_SIGNATURE) return false;
  auto nt = (IMAGE_NT_HEADERS*)(base + dos->e_lfanew);
  if (nt->Signature != IMAGE_NT_SIGNATURE) return false;
  const auto& dir = nt->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_IMPORT];
  if (!dir.VirtualAddress || !dir.Size) return false;
  auto desc = (IMAGE_IMPORT_DESCRIPTOR*)(base + dir.VirtualAddress);
  bool changed = false;
  for (; desc->Name; ++desc) {
    const char* dllName = (const char*)(base + desc->Name);
    const bool shellImport = _stricmp(dllName, "shell32.dll") == 0;
    const bool kernelImport = _stricmp(dllName, "kernel32.dll") == 0 || _stricmp(dllName, "kernelbase.dll") == 0;
    if ((!shellImport && !kernelImport) || !desc->OriginalFirstThunk || !desc->FirstThunk) continue;
    auto names = (IMAGE_THUNK_DATA*)(base + desc->OriginalFirstThunk);
    auto slots = (IMAGE_THUNK_DATA*)(base + desc->FirstThunk);
    for (; names->u1.AddressOfData; ++names, ++slots) {
      if (IMAGE_SNAP_BY_ORDINAL(names->u1.Ordinal)) continue;
      auto import = (IMAGE_IMPORT_BY_NAME*)(base + names->u1.AddressOfData);
      const char* function = (const char*)import->Name;
      if (shellImport && strcmp(function, "ShellExecuteExW") == 0) changed = PatchImportSlot(slots, (PVOID)HookShellExecuteExW) || changed;
      else if (shellImport && strcmp(function, "ShellExecuteW") == 0) changed = PatchImportSlot(slots, (PVOID)HookShellExecuteW) || changed;
      else if (kernelImport && strcmp(function, "CreateProcessW") == 0) {
        const bool slotPatched = PatchImportSlot(slots, (PVOID)HookCreateProcessW);
        if (slotPatched) InterlockedExchange(&g_createProcessPatched, 1);
        changed = slotPatched || changed;
      }
      else if (kernelImport && strcmp(function, "GetFinalPathNameByHandleW") == 0) {
        const bool slotPatched = PatchImportSlot(slots, (PVOID)HookGetFinalPathNameByHandleW);
        if (slotPatched) InterlockedExchange(&g_finalPathPatched, 1);
        changed = slotPatched || changed;
      }
    }
  }
  return changed;
}

// Remote-call ABI: nine DWORDs followed by mailbox, nonce, noop, owned DOS
// root, owned NT root, expected executable DOS path, expected executable NT path, AC temp.
extern "C" __declspec(dllexport) BOOL WINAPI CCSU_InstallOpenerHook(void* config) {
  if (!config) return FALSE;
  const DWORD* header = (const DWORD*)config;
  if (header[1] < 2 || header[1] > ARRAYSIZE(g_mailbox) || header[2] != ARRAYSIZE(g_nonce) ||
      header[3] < 2 || header[3] > ARRAYSIZE(g_noopExe) ||
      header[4] < 2 || header[4] > ARRAYSIZE(g_ownedDosRoot) ||
      header[5] < 2 || header[5] > ARRAYSIZE(g_ownedNtRoot) ||
      header[6] < 2 || header[6] > ARRAYSIZE(g_expectedDosExe) ||
      header[7] < 2 || header[7] > ARRAYSIZE(g_expectedNtExe) ||
      header[8] < 2 || header[8] > ARRAYSIZE(g_expectedAcTemp) ||
      header[0] != 9 * sizeof(DWORD) + 2 * (header[1] + header[2] + header[3] + header[4] + header[5] + header[6] + header[7] + header[8])) return FALSE;
  const wchar_t* values = (const wchar_t*)((const BYTE*)config + 9 * sizeof(DWORD));
  const wchar_t* mailbox = values;
  const wchar_t* nonce = mailbox + header[1];
  const wchar_t* noop = nonce + header[2];
  const wchar_t* dosRoot = noop + header[3];
  const wchar_t* ntRoot = dosRoot + header[4];
  const wchar_t* dosExe = ntRoot + header[5];
  const wchar_t* ntExe = dosExe + header[6];
  const wchar_t* acTemp = ntExe + header[7];
  if (mailbox[header[1] - 1] != 0 || wcsnlen_s(mailbox, header[1]) != header[1] - 1 ||
      nonce[header[2] - 1] != 0 || wcsnlen_s(nonce, header[2]) != header[2] - 1 || !ValidHexNonce(nonce)) return FALSE;
  if (noop[header[3] - 1] != 0 || wcsnlen_s(noop, header[3]) != header[3] - 1) return FALSE;
  if (dosRoot[header[4]-1]!=0 || wcsnlen_s(dosRoot,header[4])!=header[4]-1 ||
      ntRoot[header[5]-1]!=0 || wcsnlen_s(ntRoot,header[5])!=header[5]-1 ||
      dosExe[header[6]-1]!=0 || wcsnlen_s(dosExe,header[6])!=header[6]-1 ||
      ntExe[header[7]-1]!=0 || wcsnlen_s(ntExe,header[7])!=header[7]-1 ||
      acTemp[header[8]-1]!=0 || wcsnlen_s(acTemp,header[8])!=header[8]-1) return FALSE;
  wchar_t expectedNoop[32768] = {};
  size_t mailboxLength = wcslen(mailbox);
  const wchar_t requestSuffix[] = L"runtime\\updates\\portable-update.request";
  const size_t suffixLength = ARRAYSIZE(requestSuffix) - 1;
  if (mailboxLength <= suffixLength || _wcsicmp(mailbox + mailboxLength - suffixLength, requestSuffix) != 0) return FALSE;
  wchar_t fixtureRoot[32768] = {};
  size_t rootLength = mailboxLength - suffixLength;
  if (rootLength + 1 + 4 + wcslen(L"app\\cc-switch-portable-update-noop.exe") >= ARRAYSIZE(fixtureRoot)) return FALSE;
  memcpy(fixtureRoot, mailbox, rootLength * sizeof(wchar_t));
  if (rootLength && (fixtureRoot[rootLength - 1] == L'\\' || fixtureRoot[rootLength - 1] == L'/')) --rootLength;
  fixtureRoot[rootLength] = 0;
  if (swprintf_s(expectedNoop, ARRAYSIZE(expectedNoop), L"%s\\app\\cc-switch-portable-update-noop.exe", fixtureRoot) < 0 ||
      _wcsicmp(noop, expectedNoop) != 0) return FALSE;
  wchar_t expectedRootExe[32768]={};
  if(swprintf_s(expectedRootExe,ARRAYSIZE(expectedRootExe),L"%s\\app\\cc-switch.exe",dosRoot)<0 || _wcsicmp(expectedRootExe,dosExe)!=0 ||
     !IsUnderOwnedRoot(dosExe,dosRoot) || !IsUnderOwnedRoot(ntExe,ntRoot) ||
     wcslen(ntExe)<=wcslen(ntRoot) || ntExe[wcslen(ntRoot)]!=L'\\') return FALSE;
  if (wcscpy_s(g_mailbox, ARRAYSIZE(g_mailbox), mailbox) != 0 ||
      wcscpy_s(g_nonce, ARRAYSIZE(g_nonce), nonce) != 0 ||
      wcscpy_s(g_noopExe, ARRAYSIZE(g_noopExe), noop) != 0 ||
      wcscpy_s(g_ownedDosRoot,ARRAYSIZE(g_ownedDosRoot),dosRoot)!=0 ||
      wcscpy_s(g_ownedNtRoot,ARRAYSIZE(g_ownedNtRoot),ntRoot)!=0 ||
      wcscpy_s(g_expectedDosExe,ARRAYSIZE(g_expectedDosExe),dosExe)!=0 ||
      wcscpy_s(g_expectedNtExe,ARRAYSIZE(g_expectedNtExe),ntExe)!=0 ||
      wcscpy_s(g_expectedAcTemp,ARRAYSIZE(g_expectedAcTemp),acTemp)!=0) return FALSE;
  WriteFixedDiagnostic(L"shim-config-valid.hit");
  if (InterlockedCompareExchange(&g_installed, 1, 0) != 0) return TRUE;
  HMODULE shell32 = GetModuleHandleW(L"shell32.dll");
  HMODULE kernel32 = GetModuleHandleW(L"kernel32.dll");
  g_original = shell32 ? (ShellExecuteExWFn)GetProcAddress(shell32, "ShellExecuteExW") : nullptr;
  g_originalShellExecuteW = shell32 ? (ShellExecuteWFn)GetProcAddress(shell32, "ShellExecuteW") : nullptr;
  g_originalCreateProcessW = kernel32 ? (CreateProcessWFn)GetProcAddress(kernel32, "CreateProcessW") : nullptr;
  g_originalFinalPath = kernel32 ? (GetFinalPathNameByHandleWFn)GetProcAddress(kernel32, "GetFinalPathNameByHandleW") : nullptr;
  if (!g_originalCreateProcessW || !g_originalFinalPath) { WriteFixedDiagnostic(L"shim-apis-missing.hit"); InterlockedExchange(&g_installed, 0); return FALSE; }
  WriteFixedDiagnostic(L"shim-apis-valid.hit");

  // The pinned Rust opener resolves ShellExecuteExW from the main executable's
  // import table. Restrict the patch to that module; do not rewrite system or
  // unrelated plugin import tables.
  bool patched = PatchModule(GetModuleHandleW(nullptr));
  if (!patched || !InterlockedCompareExchange(&g_createProcessPatched, 0, 0) || !InterlockedCompareExchange(&g_finalPathPatched, 0, 0)) { WriteFixedDiagnostic(L"shim-import-missing.hit"); InterlockedExchange(&g_installed, 0); return FALSE; }
  WriteFixedDiagnostic(L"shim-hook-ready.hit");
  return TRUE;
}
