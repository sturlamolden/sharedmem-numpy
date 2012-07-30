
/*   Written by Sturla Molden, 2009
 *   Released under current SciPy licence
 */ 

#include <windows.h>

typedef long NTSTATUS;
typedef unsigned long ULONG;
typedef ULONG *PULONG; 
typedef DWORD ACCESS_MASK;
typedef void *PVOID;

typedef struct {
    ULONG Attributes;
    ACCESS_MASK GrantedAccess;
    ULONG HandleCount;
    ULONG PointerCount;
    ULONG Reserved[10];
} PUBLIC_OBJECT_BASIC_INFORMATION, *PPUBLIC_OBJECT_BASIC_INFORMATION;

typedef int OBJECT_INFORMATION_CLASS;

/* OBJECT_INFORMATION_CLASS ObjectBasicInformation = 0
   typedef NTSTATUS (*NtQueryObject_t)(HANDLE Handle, OBJECT_INFORMATION_CLASS ObjectInformationClass, 
   PVOID ObjectInformation, ULONG ObjectInformationLength, PULONG ReturnLength)
*/

typedef NTSTATUS WINAPI (*NtQueryObject_t)(HANDLE, OBJECT_INFORMATION_CLASS, PVOID, ULONG, PULONG);
static NtQueryObject_t NtQueryObject = NULL;
static HANDLE ntdll = NULL;

int get_reference_count(HANDLE h)
{
    PUBLIC_OBJECT_BASIC_INFORMATION info;
    unsigned long retlen;
    NTSTATUS stat;
    if (ntdll == NULL) {
        ntdll = LoadLibrary("ntdll.dll");
        NtQueryObject = (NtQueryObject_t) GetProcAddress(ntdll, "NtQueryObject");
    }
    stat = (*NtQueryObject)(h, 0, (void *) &info, sizeof(info), &retlen);
    if (stat != 0) 
        return -1;
    else
        return (int) info.HandleCount;
} 

