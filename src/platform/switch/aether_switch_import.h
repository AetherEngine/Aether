#pragma once

#include <stddef.h>
#include <stdbool.h>
#include <switch/types.h>

typedef struct Thread {
    Handle handle;
    bool owns_stack_mem;
    void *stack_mem;
    void *stack_mirror;
    size_t stack_sz;
    void **tls_array;
    struct Thread *next;
    struct Thread **prev_next;
} Thread;

Result threadCreate(Thread *t, ThreadFunc entry, void *arg, void *stack_mem, size_t stack_sz, int prio, int cpuid);
Result threadStart(Thread *t);
Result threadWaitForExit(Thread *t);
Result threadClose(Thread *t);
Handle threadGetCurHandle(void);

Result fsdevMountSdmc(void);
int fsdevUnmountDevice(const char *name);
Result romfsMountSelf(const char *name);
Result romfsUnmount(const char *name);

Result socketInitialize(const void *config);
void socketExit(void);

u64 svcGetSystemTick(void);
void svcSleepThread(s64 nano);
Result svcGetThreadPriority(s32 *priority, Handle handle);
Result svcSetThreadPriority(Handle handle, u32 priority);

bool appletMainLoop(void);

typedef enum {
    AppletOperationMode_Handheld = 0,
    AppletOperationMode_Console = 1,
} AppletOperationMode;

AppletOperationMode appletGetOperationMode(void);

typedef struct HidAnalogStickState {
    s32 x;
    s32 y;
} HidAnalogStickState;

typedef struct HidTouchState {
    u64 delta_time;
    u32 attributes;
    u32 finger_id;
    u32 x;
    u32 y;
    u32 diameter_x;
    u32 diameter_y;
    u32 rotation_angle;
    u32 reserved;
} HidTouchState;

typedef struct HidTouchScreenState {
    u64 sampling_number;
    s32 count;
    u32 reserved;
    HidTouchState touches[16];
} HidTouchScreenState;

typedef struct PadState {
    u8 id_mask;
    u8 active_id_mask;
    bool read_handheld;
    bool active_handheld;
    u32 style_set;
    u32 attributes;
    u64 buttons_cur;
    u64 buttons_old;
    HidAnalogStickState sticks[2];
    u32 gc_triggers[2];
} PadState;

#define HidNpadStyleTag_NpadFullKey  BIT(0)
#define HidNpadStyleTag_NpadHandheld BIT(1)
#define HidNpadStyleTag_NpadJoyDual  BIT(2)
#define HidNpadStyleTag_NpadJoyLeft  BIT(3)
#define HidNpadStyleTag_NpadJoyRight BIT(4)

#define HidNpadIdType_No1      0
#define HidNpadIdType_Handheld 0x20

#define HidNpadButton_A       BITL(0)
#define HidNpadButton_B       BITL(1)
#define HidNpadButton_X       BITL(2)
#define HidNpadButton_Y       BITL(3)
#define HidNpadButton_StickL  BITL(4)
#define HidNpadButton_StickR  BITL(5)
#define HidNpadButton_L       BITL(6)
#define HidNpadButton_R       BITL(7)
#define HidNpadButton_ZL      BITL(8)
#define HidNpadButton_ZR      BITL(9)
#define HidNpadButton_Plus    BITL(10)
#define HidNpadButton_Minus   BITL(11)
#define HidNpadButton_Left    BITL(12)
#define HidNpadButton_Up      BITL(13)
#define HidNpadButton_Right   BITL(14)
#define HidNpadButton_Down    BITL(15)
#define HidNpadButton_LeftSL  BITL(24)
#define HidNpadButton_LeftSR  BITL(25)
#define HidNpadButton_RightSL BITL(26)
#define HidNpadButton_RightSR BITL(27)

#define JOYSTICK_MAX 0x7FFF

Result hidInitialize(void);
void hidExit(void);
void hidInitializeTouchScreen(void);
size_t hidGetTouchScreenStates(HidTouchScreenState *states, size_t count);

void padConfigureInput(u32 max_players, u32 style_set);
void padInitializeWithMask(PadState *pad, u64 mask);
void padUpdate(PadState *pad);

Result swkbdCreate(void *c, s32 max_dictwords);
void swkbdClose(void *c);
void swkbdConfigMakePresetDefault(void *c);
void swkbdConfigSetOkButtonText(void *c, const char *str);
void swkbdConfigSetHeaderText(void *c, const char *str);
void swkbdConfigSetGuideText(void *c, const char *str);
void swkbdConfigSetInitialText(void *c, const char *str);
Result swkbdShow(void *c, char *out_string, size_t out_string_size);

typedef struct AudioOutBuffer AudioOutBuffer;
struct AudioOutBuffer {
    AudioOutBuffer *next;
    void *buffer;
    u64 buffer_size;
    u64 data_size;
    u64 data_offset;
};

Result audoutInitialize(void);
void audoutExit(void);
Result audoutStartAudioOut(void);
Result audoutStopAudioOut(void);
Result audoutAppendAudioOutBuffer(AudioOutBuffer *buffer);
Result audoutGetReleasedAudioOutBuffer(AudioOutBuffer **buffer, u32 *released_count);
