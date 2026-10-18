/* SPDX-License-Identifier: Apache-2.0 */
/* Original Windows ARM64 graphics status UI. No account data, files or network.
 * Public Windows SDK APIs; fixed read-only resolution query from the published
 * VioGpu vendor protocol (Type1, DataLength4). Apply changes only display mode. */
#define WIN32_LEAN_AND_MEAN
#define UNICODE
#define _UNICODE
#define COBJMACROS
#define INITGUID
#include <windows.h>
#include <d3d11.h>
#include <stddef.h>
#include <stdint.h>

void *memset(void *p, int v, size_t n) { unsigned char *a=p; while(n--) *a++=(unsigned char)v; return p; }
void *memcpy(void *p, const void *q, size_t n) { unsigned char *a=p; const unsigned char *b=q; while(n--) *a++=*b++; return p; }
int _fltused;
typedef struct { HDC dc; UINT adapter; LUID luid; UINT source; } MvoOpenAdapter;
typedef struct { UINT adapter, device, type, flags; void *data; UINT size, context; } MvoEscape;
typedef struct { UINT adapter; } MvoCloseAdapter;
_Static_assert(sizeof(MvoOpenAdapter)==24 && offsetof(MvoOpenAdapter,luid)==12, "SDK ARM64 ABI");
_Static_assert(sizeof(MvoEscape)==32 && offsetof(MvoEscape,data)==16, "SDK ARM64 ABI");
typedef LONG (WINAPI *OpenAdapterFn)(MvoOpenAdapter *);
typedef LONG (WINAPI *EscapeFn)(MvoEscape *);
typedef LONG (WINAPI *CloseAdapterFn)(MvoCloseAdapter *);
typedef HRESULT (WINAPI *CreateDeviceFn)(IDXGIAdapter*,D3D_DRIVER_TYPE,HMODULE,UINT,const D3D_FEATURE_LEVEL*,UINT,UINT,ID3D11Device**,D3D_FEATURE_LEVEL*,ID3D11DeviceContext**);
static HWND output;
static WCHAR deviceName[32];
static LONG applyResult=999;
static LONG gdiApplyResult=999;
static LONG raw4kApplyResult=999,restoreResult=999;
static DEVMODEW previousMode;
static WCHAR previousDevice[32];
static BOOL previousModeValid;
static WCHAR reportText[4096];
static WCHAR modeDetails[768];
static unsigned char queryPacket[1024];
static LUID displayLuid;
static UINT displaySource;
static BOOL displayIdentityValid;
static USHORT requestedWidth,requestedHeight;
static DISPLAYCONFIG_PATH_INFO activePaths[16];
static DISPLAYCONFIG_MODE_INFO activeModes[32];
static void appendReport(const WCHAR *extra) {
 size_t at=0;while(at+1<sizeof(reportText)/sizeof(*reportText)&&reportText[at])at++;
 while(at+1<sizeof(reportText)/sizeof(*reportText)&&*extra)reportText[at++]=*extra++;
 reportText[at]=0;
}
static void reportTarget(void) {
 UINT32 paths=0,modes=0;
 LONG status=GetDisplayConfigBufferSizes(QDC_ONLY_ACTIVE_PATHS,&paths,&modes);
 if(status==ERROR_SUCCESS&&paths&&paths<=16&&modes&&modes<=32)
  status=QueryDisplayConfig(QDC_ONLY_ACTIVE_PATHS,&paths,activePaths,&modes,activeModes,NULL);
 else if(status==ERROR_SUCCESS)status=ERROR_INSUFFICIENT_BUFFER;
 if(status==ERROR_SUCCESS&&displayIdentityValid)for(UINT32 i=0;i<paths;i++) {
  DISPLAYCONFIG_PATH_INFO *path=&activePaths[i];
  if(path->sourceInfo.adapterId.LowPart!=displayLuid.LowPart||path->sourceInfo.adapterId.HighPart!=displayLuid.HighPart||path->sourceInfo.id!=displaySource)continue;
  UINT index=path->targetInfo.modeInfoIdx;
  if(index>=modes||activeModes[index].infoType!=DISPLAYCONFIG_MODE_INFO_TYPE_TARGET||activeModes[index].id!=path->targetInfo.id||activeModes[index].adapterId.LowPart!=path->targetInfo.adapterId.LowPart||activeModes[index].adapterId.HighPart!=path->targetInfo.adapterId.HighPart){status=ERROR_BAD_CONFIGURATION;break;}
  DISPLAYCONFIG_VIDEO_SIGNAL_INFO *signal=&activeModes[index].targetMode.targetVideoSignalInfo;
  wsprintfW(modeDetails,L"\r\n\r\nCCD target active: %u x %u, total: %u x %u\r\nPixel clock (hex Hz): 0x%08X%08X\r\nHSync: %u / %u, VSync: %u / %u\r\nPath refresh: %u / %u, scaling: %u\r\nSource index: %u, target index: %u\r\n",
   signal->activeSize.cx,signal->activeSize.cy,signal->totalSize.cx,signal->totalSize.cy,
   (UINT)(signal->pixelRate>>32),(UINT)signal->pixelRate,signal->hSyncFreq.Numerator,signal->hSyncFreq.Denominator,signal->vSyncFreq.Numerator,signal->vSyncFreq.Denominator,
   path->targetInfo.refreshRate.Numerator,path->targetInfo.refreshRate.Denominator,(UINT)path->targetInfo.scaling,path->sourceInfo.modeInfoIdx,index);
  appendReport(modeDetails);return;
 }
 wsprintfW(modeDetails,L"\r\n\r\nCCD target query: %ld (no matched target timing)\r\n",status==ERROR_SUCCESS?ERROR_NOT_FOUND:status);appendReport(modeDetails);
}
/* Original bounded CCD resize. Keep every other active path and require the
 * freshly opened primary adapter/source identity; no private driver mutation. */
static LONG applyMode(UINT width,UINT height) {
 if(width<64||height<64||width>8192||height>8192||(uint64_t)width*height>16777216)return ERROR_INVALID_PARAMETER;
 UINT32 paths=0,modes=0;
 if(!displayIdentityValid)return ERROR_INVALID_HANDLE;
 LONG status=GetDisplayConfigBufferSizes(QDC_ONLY_ACTIVE_PATHS,&paths,&modes);
 if(status!=ERROR_SUCCESS)return status;
 if(!paths||paths>16||!modes||modes>32)return ERROR_INSUFFICIENT_BUFFER;
 status=QueryDisplayConfig(QDC_ONLY_ACTIVE_PATHS,&paths,activePaths,&modes,activeModes,NULL);
 if(status!=ERROR_SUCCESS)return status;
 BOOL matched=FALSE;
 for(UINT32 i=0;i<paths;i++) {
  DISPLAYCONFIG_PATH_SOURCE_INFO *source=&activePaths[i].sourceInfo;
  if(source->adapterId.LowPart!=displayLuid.LowPart||source->adapterId.HighPart!=displayLuid.HighPart||source->id!=displaySource)continue;
  UINT index=source->modeInfoIdx;
  if(index>=modes||activeModes[index].infoType!=DISPLAYCONFIG_MODE_INFO_TYPE_SOURCE||activeModes[index].id!=source->id||activeModes[index].adapterId.LowPart!=source->adapterId.LowPart||activeModes[index].adapterId.HighPart!=source->adapterId.HighPart)return ERROR_BAD_CONFIGURATION;
  activeModes[index].sourceMode.width=width;
  activeModes[index].sourceMode.height=height;
  /* Retaining the previous target timing can constrain a new source to the old
   * mode. Ask documented CCD best-mode logic for a matching target, while keeping
   * the requested source exact. Other display paths retain their target modes. */
  activePaths[i].targetInfo.modeInfoIdx=DISPLAYCONFIG_PATH_MODE_IDX_INVALID;
  matched=TRUE;
 }
 if(!matched)return ERROR_NOT_FOUND;
 return SetDisplayConfig(paths,activePaths,modes,activeModes,
  SDC_APPLY|SDC_USE_SUPPLIED_DISPLAY_CONFIG|SDC_FORCE_MODE_ENUMERATION|SDC_NO_OPTIMIZATION);
}
/* Independent public GDI apply, with exact width/height fields and no registry
 * persistence. A zero return alone remains insufficient: refresh reports the
 * actual current mode and the host must separately verify its framebuffer. */
static LONG applyGdiMode(UINT width,UINT height) {
 if(!displayIdentityValid)return DISP_CHANGE_BADPARAM;
 if(width<64||height<64||width>8192||height>8192||(uint64_t)width*height>16777216)return DISP_CHANGE_BADPARAM;
 DEVMODEW mode={0};mode.dmSize=sizeof(mode);
 if(!EnumDisplaySettingsW(deviceName,ENUM_CURRENT_SETTINGS,&mode))return DISP_CHANGE_FAILED;
 mode.dmFields=DM_PELSWIDTH|DM_PELSHEIGHT|DM_BITSPERPEL;
 mode.dmPelsWidth=width;mode.dmPelsHeight=height;mode.dmBitsPerPel=32;
 return ChangeDisplaySettingsExW(deviceName,&mode,NULL,0,NULL);
}
/* A separate, explicit virtual-monitor experiment. Select only a complete mode
 * enumerated by the installed driver; never fabricate timing, touch signature
 * enforcement or persist a mode in the registry. Use ordinary documented test
 * and temporary apply flags; a raw list entry alone is not an accepted mode.
 * Firmware display and
 * a previous-mode restore remain available if this test fails to scan out. */
static LONG tryRaw4kMode(void) {
 if(!displayIdentityValid)return DISP_CHANGE_BADPARAM;
 DEVMODEW candidate={0};BOOL found=FALSE;
 for(DWORD i=0;i<4096;i++) {
  DEVMODEW mode={0};mode.dmSize=sizeof(mode);
  if(!EnumDisplaySettingsExW(deviceName,i,&mode,EDS_RAWMODE))break;
  if(mode.dmPelsWidth!=3840||mode.dmPelsHeight!=2160||mode.dmBitsPerPel!=32)continue;
  if(mode.dmDisplayFrequency>120)continue;
  if(!found||mode.dmDisplayFrequency==60){candidate=mode;found=TRUE;}
  if(mode.dmDisplayFrequency==60)break;
 }
 if(!found)return DISP_CHANGE_BADMODE;
 candidate.dmDriverExtra=0;
 LONG test=ChangeDisplaySettingsExW(deviceName,&candidate,NULL,CDS_TEST,NULL);
 if(test!=DISP_CHANGE_SUCCESSFUL)return test;
 if(!previousModeValid) {
  previousMode.dmSize=sizeof(previousMode);
  if(!EnumDisplaySettingsW(deviceName,ENUM_CURRENT_SETTINGS,&previousMode))return DISP_CHANGE_FAILED;
  previousMode.dmDriverExtra=0;
  memcpy(previousDevice,deviceName,sizeof(previousDevice));previousModeValid=TRUE;
 }
 return ChangeDisplaySettingsExW(deviceName,&candidate,NULL,CDS_FULLSCREEN,NULL);
}
static LONG restorePreviousMode(void) {
 if(!previousModeValid||!displayIdentityValid)return DISP_CHANGE_BADPARAM;
 for(UINT i=0;i<32;i++)if(previousDevice[i]!=deviceName[i])return DISP_CHANGE_BADPARAM;
 return ChangeDisplaySettingsExW(previousDevice,&previousMode,NULL,0,NULL);
}
static void refresh(void) {
 DISPLAY_DEVICEW info={0}; info.cb=sizeof(info);
 for(DWORD i=0;EnumDisplayDevicesW(NULL,i,&info,0);i++) {
  if(info.StateFlags & DISPLAY_DEVICE_PRIMARY_DEVICE) break;
  info.cb=sizeof(info);
 }
 memcpy(deviceName,info.DeviceName,sizeof(deviceName));
 DEVMODEW current={0}, native={0};current.dmSize=sizeof(current);native.dmSize=sizeof(native);
 BOOL currentOK=EnumDisplaySettingsW(deviceName,ENUM_CURRENT_SETTINGS,&current);
 native=current;native.dmFields=DM_PELSWIDTH|DM_PELSHEIGHT|DM_BITSPERPEL;
 native.dmPelsWidth=3456;native.dmPelsHeight=2160;native.dmBitsPerPel=32;
 LONG test=ChangeDisplaySettingsExW(deviceName,&native,NULL,CDS_TEST,NULL);
 UINT maxW=0,maxH=0,modes=0;
 for(DWORD i=0;i<4096;i++) { DEVMODEW mode={0};mode.dmSize=sizeof(mode);if(!EnumDisplaySettingsW(deviceName,i,&mode))break;modes++;if(mode.dmPelsWidth>maxW||(mode.dmPelsWidth==maxW&&mode.dmPelsHeight>maxH)){maxW=mode.dmPelsWidth;maxH=mode.dmPelsHeight;} }
 HMODULE gdi=LoadLibraryExW(L"gdi32.dll",NULL,LOAD_LIBRARY_SEARCH_SYSTEM32);
 OpenAdapterFn open=(OpenAdapterFn)(void*)GetProcAddress(gdi,"D3DKMTOpenAdapterFromHdc");
 EscapeFn escape=(EscapeFn)(void*)GetProcAddress(gdi,"D3DKMTEscape");
 CloseAdapterFn close=(CloseAdapterFn)(void*)GetProcAddress(gdi,"D3DKMTCloseAdapter");
 HDC dc=CreateDCW(L"DISPLAY",deviceName,NULL,NULL);MvoOpenAdapter adapter={0};adapter.dc=dc;
 LONG openStatus=0xc0000002L,queryStatus=0xc0000002L;USHORT desiredW=0,desiredH=0;
 if(open&&escape&&close&&dc){openStatus=open(&adapter);if(openStatus>=0){unsigned char *packet=queryPacket;memset(packet,0,sizeof(queryPacket));packet[0]=1;packet[2]=4;MvoEscape request={0};request.adapter=adapter.adapter;request.data=packet;request.size=sizeof(queryPacket);queryStatus=escape(&request);if(queryStatus>=0){desiredW=(USHORT)(packet[4]|(packet[5]<<8));desiredH=(USHORT)(packet[6]|(packet[7]<<8));}MvoCloseAdapter closed={adapter.adapter};close(&closed);}}
 if(dc)DeleteDC(dc);if(gdi)FreeLibrary(gdi);
 displayIdentityValid=openStatus>=0;displayLuid=adapter.luid;displaySource=adapter.source;
 requestedWidth=queryStatus>=0?desiredW:0;requestedHeight=queryStatus>=0?desiredH:0;
 UINT rawMaxW=0,rawMaxH=0,rawModes=0,rawRequested=0,raw120=0,raw4k=0;
 for(DWORD i=0;i<4096;i++){DEVMODEW mode={0};mode.dmSize=sizeof(mode);if(!EnumDisplaySettingsExW(deviceName,i,&mode,EDS_RAWMODE))break;rawModes++;if(mode.dmPelsWidth==requestedWidth&&mode.dmPelsHeight==requestedHeight)rawRequested++;if(mode.dmDisplayFrequency>=120)raw120++;if(mode.dmPelsWidth==3840&&mode.dmPelsHeight==2160&&mode.dmBitsPerPel==32)raw4k++;if(mode.dmPelsWidth>rawMaxW||(mode.dmPelsWidth==rawMaxW&&mode.dmPelsHeight>rawMaxH)){rawMaxW=mode.dmPelsWidth;rawMaxH=mode.dmPelsHeight;}}
 HMODULE d3d=LoadLibraryExW(L"d3d11.dll",NULL,LOAD_LIBRARY_SEARCH_SYSTEM32);
 CreateDeviceFn create=(CreateDeviceFn)(void*)GetProcAddress(d3d,"D3D11CreateDevice");
 ID3D11Device *gpu=NULL;ID3D11DeviceContext *context=NULL;D3D_FEATURE_LEVEL level=0;
 const D3D_FEATURE_LEVEL levels[]={D3D_FEATURE_LEVEL_11_1,D3D_FEATURE_LEVEL_11_0};
 HRESULT gpuStatus=E_FAIL;DXGI_ADAPTER_DESC desc={0};BOOL same=FALSE;
 if(create)gpuStatus=create(NULL,D3D_DRIVER_TYPE_HARDWARE,NULL,0,levels,2,D3D11_SDK_VERSION,&gpu,&level,&context);
 if(gpu){IDXGIDevice *dx=NULL;IDXGIAdapter *a=NULL;if(SUCCEEDED(ID3D11Device_QueryInterface(gpu,&IID_IDXGIDevice,(void**)&dx))){if(SUCCEEDED(IDXGIDevice_GetAdapter(dx,&a))){IDXGIAdapter_GetDesc(a,&desc);same=desc.AdapterLuid.LowPart==adapter.luid.LowPart&&desc.AdapterLuid.HighPart==adapter.luid.HighPart;IDXGIAdapter_Release(a);}IDXGIDevice_Release(dx);}if(context)ID3D11DeviceContext_Release(context);ID3D11Device_Release(gpu);}if(d3d)FreeLibrary(d3d);
 DWORD tdr=0,preemption=0,n=sizeof(DWORD);
 LSTATUS tdrStatus=RegGetValueW(HKEY_LOCAL_MACHINE,L"SYSTEM\\CurrentControlSet\\Control\\GraphicsDrivers",L"TdrDebugMode",RRF_RT_REG_DWORD,NULL,&tdr,&n);
 n=sizeof(DWORD);LSTATUS preemptionStatus=RegGetValueW(HKEY_LOCAL_MACHINE,L"SYSTEM\\CurrentControlSet\\Control\\GraphicsDrivers\\Scheduler",L"EnablePreemption",RRF_RT_REG_DWORD,NULL,&preemption,&n);
 WCHAR *text=reportText;
 wsprintfW(text,L"Primary display: %s\r\nDevice: %s\r\nCurrent mode: %lu x %lu (query %u)\r\nLargest enumerated: %u x %u (%u modes)\r\nPreliminary mode test: %ld (0 is not proof of apply)\r\nCCD apply result: %ld (0 success; 999 not applied)\r\n\r\nDriver resolution query: 0x%08X -> %u x %u\r\nDisplay adapter open: 0x%08X\r\n\r\nHardware D3D11 creation: 0x%08X, feature 0x%X\r\nAdapter: %s\r\nVendor: 0x%X Device: 0x%X\r\nSame display and rendering adapter: %u\r\n\r\nTdrDebugMode: query %ld value %lu\r\nEnablePreemption: query %ld value %lu\r\nRegistry query 2 means unset. No registry values changed.",info.DeviceString,deviceName,current.dmPelsWidth,current.dmPelsHeight,currentOK,maxW,maxH,modes,test,applyResult,(UINT)queryStatus,desiredW,desiredH,(UINT)openStatus,(UINT)gpuStatus,(UINT)level,desc.Description,desc.VendorId,desc.DeviceId,same,tdrStatus,tdr,preemptionStatus,preemption);
 wsprintfW(modeDetails,L"\r\n\r\nGDI apply result: %ld (0 success; 999 not applied)\r\nRaw driver modes: largest %u x %u (%u modes)\r\nRequested viewport in raw list: %u entries\r\nCurrent GDI refresh: %lu Hz; raw modes >=120 Hz: %u\r\nDriver-listed 3840 x 2160 modes: %u\r\nTemporary raw 4K result: %ld; restore result: %ld\r\n",gdiApplyResult,rawMaxW,rawMaxH,rawModes,rawRequested,current.dmDisplayFrequency,raw120,raw4k,raw4kApplyResult,restoreResult);appendReport(modeDetails);
 reportTarget();
 SetWindowTextW(output,text);
}
static LRESULT CALLBACK windowProc(HWND w,UINT m,WPARAM wp,LPARAM lp){
 if(m==WM_CREATE){output=CreateWindowExW(0,L"EDIT",L"",WS_CHILD|WS_VISIBLE|ES_MULTILINE|ES_READONLY|WS_VSCROLL,16,16,1000,620,w,(HMENU)10,NULL,NULL);CreateWindowExW(0,L"BUTTON",L"Refresh status",WS_CHILD|WS_VISIBLE|WS_TABSTOP,16,650,200,42,w,(HMENU)1,NULL,NULL);CreateWindowExW(0,L"BUTTON",L"Apply full display test mode",WS_CHILD|WS_VISIBLE|WS_TABSTOP,230,650,270,42,w,(HMENU)2,NULL,NULL);CreateWindowExW(0,L"BUTTON",L"Apply requested viewport",WS_CHILD|WS_VISIBLE|WS_TABSTOP,520,650,270,42,w,(HMENU)3,NULL,NULL);CreateWindowExW(0,L"BUTTON",L"Try requested GDI mode",WS_CHILD|WS_VISIBLE|WS_TABSTOP,805,650,220,42,w,(HMENU)4,NULL,NULL);CreateWindowExW(0,L"BUTTON",L"Try driver-listed 4K mode",WS_CHILD|WS_VISIBLE|WS_TABSTOP,16,702,300,42,w,(HMENU)5,NULL,NULL);CreateWindowExW(0,L"BUTTON",L"Restore previous mode",WS_CHILD|WS_VISIBLE|WS_TABSTOP,330,702,280,42,w,(HMENU)6,NULL,NULL);refresh();return 0;}
 if(m==WM_COMMAND&&HIWORD(wp)==BN_CLICKED&&LOWORD(wp)>=1&&LOWORD(wp)<=6){refresh();if(LOWORD(wp)==2)applyResult=applyMode(3456,2160);if(LOWORD(wp)==3)applyResult=applyMode(requestedWidth,requestedHeight);if(LOWORD(wp)==4)gdiApplyResult=applyGdiMode(requestedWidth,requestedHeight);if(LOWORD(wp)==5)raw4kApplyResult=tryRaw4kMode();if(LOWORD(wp)==6)restoreResult=restorePreviousMode();refresh();return 0;}
 if(m==WM_DESTROY){PostQuitMessage(0);return 0;}return DefWindowProcW(w,m,wp,lp);
}
void mvo_start(void){SetProcessDPIAware();HINSTANCE instance=GetModuleHandleW(NULL);WNDCLASSW wc={0};wc.lpfnWndProc=windowProc;wc.hInstance=instance;wc.lpszClassName=L"MvoGraphicsStatus";wc.hCursor=LoadCursorW(NULL,IDC_ARROW);RegisterClassW(&wc);HWND w=CreateWindowExW(0,wc.lpszClassName,L"macOpenVM Graphics Diagnostics",WS_OVERLAPPEDWINDOW,100,100,1050,840,NULL,NULL,instance,NULL);ShowWindow(w,SW_SHOW);MSG msg;while(GetMessageW(&msg,NULL,0,0)>0){if(!IsDialogMessageW(w,&msg)){TranslateMessage(&msg);DispatchMessageW(&msg);}}ExitProcess(0);}
