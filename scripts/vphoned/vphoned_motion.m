/*
 * vphoned_motion — shake gesture via Mach injection of pure shellcode.
 *
 * Flow on `{"t":"shake"}`:
 *   1. Enumerate running user apps (proc_listpids + path filter), drop the
 *      ones task_for_pid rejects (system apps with get-task-allow=false),
 *      pick the most-foreground one by BKSApplicationStateMonitor state.
 *   2. task_for_pid + mach_vm_allocate a code page (3-stage shellcode), a
 *      data page (resolved symbol/string table) and a stack.
 *   3. thread_create_running runs the OUTER shellcode on a raw Mach thread,
 *      which calls pthread_create_from_mach_thread to spawn an INNER pthread
 *      (raw Mach threads have no TLS, so libdispatch/objc calls would crash).
 *   4. INNER, now on a real pthread, calls dispatch_async_f(main_queue, ...)
 *      to hop the actual UIKit work onto the MAIN thread (UIKit is not
 *      thread-safe; off-main `keyWindow` etc. trip a main-thread assertion).
 *   5. MAIN_WORK runs on the main thread and, purely via objc_msgSend:
 *        app = [UIApplication sharedApplication]
 *        win = [app keyWindow]
 *        fr  = [win valueForKey:@"firstResponder"]   // UIWindow has the ivar
 *        target = fr ?: win
 *        [target motionBegan:UIEventSubtypeMotionShake withEvent:nil]
 *        [target motionEnded:UIEventSubtypeMotionShake withEvent:nil]
 *
 * Why no helper dylib anymore: dlopen()ing a foreign-team dylib into a target
 * that enforces CS_REQUIRE_LV | CS_KILL (any normally-signed third-party app,
 * e.g. App Store builds) is rejected by AMFI library validation and the kernel
 * kills the target before the dylib constructor runs — unless the kernel
 * carries the JB AMFI trustcache/LV patches (Jailbreak firmware variant only).
 * Executing injected (unsigned) code pages, by contrast, is permitted on this
 * research kernel, so doing the whole gesture in shellcode works on every
 * variant. See research/shake_inject_killed_by_library_validation.md.
 *
 * Shellcode uses paciza on the two function pointers it hands to
 * pthread_create_from_mach_thread (start routine) and dispatch_async_f (work
 * fn); both are authenticated by their callee with the IA key / zero
 * discriminator, which paciza matches. Plain `blr` is used for direct calls to
 * shared-cache functions (no authentication needed at the call site).
 */

#import "vphoned_motion.h"
#import "vphoned_protocol.h"
#include <dlfcn.h>
#include <dispatch/dispatch.h>
#include <mach/mach.h>
#include <mach/mach_error.h>
#include <mach-o/dyld_images.h>
#include <objc/message.h>
#include <objc/runtime.h>
#include <stdio.h>
#include <string.h>
#include <errno.h>

// mach_vm_* and libproc prototypes — headers aren't exported in iOS SDK.
extern kern_return_t mach_vm_allocate(vm_map_t, mach_vm_address_t *, mach_vm_size_t, int);
extern kern_return_t mach_vm_write(vm_map_t, mach_vm_address_t, vm_offset_t, mach_msg_type_number_t);
extern kern_return_t mach_vm_protect(vm_map_t, mach_vm_address_t, mach_vm_size_t, boolean_t, vm_prot_t);
extern kern_return_t mach_vm_read_overwrite(vm_map_t, mach_vm_address_t, mach_vm_size_t, mach_vm_address_t, mach_vm_size_t *);

#define PROC_PIDPATHINFO_MAXSIZE  (4 * 1024)
#define PROC_ALL_PIDS              1
extern int proc_pidpath(int pid, void *buffer, uint32_t buffersize);
extern int proc_listpids(uint32_t type, uint32_t typeinfo, void *buffer, int buffersize);

// MARK: - Logging

static void diag(const char *fmt, ...) __attribute__((format(printf, 1, 2)));

static void diag(const char *fmt, ...) {
    char buf[1024];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    NSLog(@"[vphone_motion] %s", buf);
    FILE *fp = fopen("/tmp/vp_motion.log", "a");
    if (fp) { fprintf(fp, "%s\n", buf); fclose(fp); }
}

// MARK: - Shellcode
//
// One code page, three entry points:
//   +0x000  OUTER     (raw Mach thread)  — bootstraps a pthread
//   +0x080  INNER     (pthread)          — dispatch_async_f to main queue
//   +0x100  MAIN_WORK (main thread)      — the objc_msgSend gesture
//
// All inputs come from the data page whose address is passed in x0 to every
// stage (OUTER passes it on as the pthread arg, INNER passes it on as the
// dispatch context). Layout of that page (`struct shake_args`) is below.
__attribute__((naked, noinline, used))
static void shake_shellcode(void) {
    asm volatile(
        // PAC mnemonics aren't in baseline arm64; enable for this block only.
        // On non-PAC CPUs the encoded bytes decode as NOP / plain BLR.
        ".arch_extension pauth   \n"

        // === OUTER (offset 0x000) — x0 = args ===
        "mov  x19, x0            \n"
        "ldr  x20, [x19, #0x18]  \n"   // pthread_create_from_mach_thread
        "ldr  x21, [x19, #0x28]  \n"   // INNER (raw)
        "paciza x21              \n"   // sign as start_routine (IA, disc 0)
        "sub  sp, sp, #16        \n"   // pthread_t storage
        "mov  x0, sp             \n"
        "mov  x1, #0             \n"   // attr = NULL
        "mov  x2, x21            \n"   // start_routine
        "mov  x3, x19            \n"   // arg = args
        "blr  x20                \n"   // pthread_create_from_mach_thread
        "add  sp, sp, #16        \n"
        // This raw Mach thread has no valid return frame and cannot be cleanly
        // self-terminated (thread_terminate on a thread_create_running thread
        // takes the whole task down on this kernel). Park it in a *blocking*
        // pause() instead of a busy `b .` loop so it costs 0 CPU. It stays
        // resident (one idle thread per shake) but never spins.
        "ldr  x16, [x19, #0x88]  \n"   // pause
        "blr  x16                \n"
        "1: b 1b                 \n"   // safety park (unreachable)

        ".balign 128             \n"
        // === INNER (offset 0x080) — runs on real pthread, x0 = args ===
        // A real pthread: do the dispatch, then RETURN so libpthread reaps it
        // (no spinning thread left behind). x19/x20 are callee-saved.
        "stp  x29, x30, [sp, #-0x20]! \n"
        "stp  x19, x20, [sp, #0x10]   \n"
        "mov  x29, sp            \n"
        "mov  x19, x0            \n"
        "ldr  x20, [x19, #0x20]  \n"   // dispatch_async_f
        "ldr  x0,  [x19, #0x30]  \n"   // main queue
        "mov  x1,  x19           \n"   // context = args
        "ldr  x2,  [x19, #0x38]  \n"   // MAIN_WORK (raw)
        "paciza x2               \n"   // sign as dispatch work fn (IA, disc 0)
        "blr  x20                \n"   // dispatch_async_f(main_q, args, MAIN_WORK)
        "ldp  x19, x20, [sp, #0x10]   \n"
        "ldp  x29, x30, [sp], #0x20   \n"
        "ret                     \n"

        ".balign 256             \n"
        // === MAIN_WORK (offset 0x100) — runs on main thread, x0 = args ===
        "stp  x29, x30, [sp, #-0x60]! \n"
        "stp  x19, x20, [sp, #0x10]   \n"
        "stp  x21, x22, [sp, #0x20]   \n"
        "stp  x23, x24, [sp, #0x30]   \n"
        "stp  x25, x26, [sp, #0x40]   \n"
        "mov  x29, sp            \n"
        "mov  x19, x0            \n"   // x19 = args (callee-saved across msgSend)
        // app = objc_getClass("UIApplication") -> [cls sharedApplication]
        "ldr  x16, [x19, #0x00]  \n"   // objc_getClass
        "ldr  x0,  [x19, #0x40]  \n"   // "UIApplication"
        "blr  x16                \n"
        "mov  x20, x0            \n"
        "ldr  x16, [x19, #0x08]  \n"   // sel_registerName
        "ldr  x0,  [x19, #0x48]  \n"   // "sharedApplication"
        "blr  x16                \n"
        "mov  x1,  x0            \n"
        "ldr  x16, [x19, #0x10]  \n"   // objc_msgSend
        "mov  x0,  x20           \n"
        "blr  x16                \n"
        "mov  x21, x0            \n"   // x21 = app
        // win = [app keyWindow]
        "ldr  x16, [x19, #0x08]  \n"
        "ldr  x0,  [x19, #0x50]  \n"   // "keyWindow"
        "blr  x16                \n"
        "mov  x1,  x0            \n"
        "ldr  x16, [x19, #0x10]  \n"
        "mov  x0,  x21           \n"
        "blr  x16                \n"
        "str  x0,  [x19, #0xA0]  \n"   // diag: keyWindow
        "mov  x22, x0            \n"   // x22 = win
        // fr = [win valueForKey:[NSString stringWithUTF8String:"firstResponder"]]
        "ldr  x16, [x19, #0x00]  \n"   // objc_getClass
        "ldr  x0,  [x19, #0x68]  \n"   // "NSString"
        "blr  x16                \n"
        "mov  x23, x0            \n"
        "ldr  x16, [x19, #0x08]  \n"
        "ldr  x0,  [x19, #0x70]  \n"   // "stringWithUTF8String:"
        "blr  x16                \n"
        "mov  x1,  x0            \n"
        "ldr  x16, [x19, #0x10]  \n"
        "mov  x0,  x23           \n"
        "ldr  x2,  [x19, #0x80]  \n"   // "firstResponder" (C string)
        "blr  x16                \n"
        "mov  x24, x0            \n"   // x24 = @"firstResponder"
        "ldr  x16, [x19, #0x08]  \n"
        "ldr  x0,  [x19, #0x78]  \n"   // "valueForKey:"
        "blr  x16                \n"
        "mov  x1,  x0            \n"
        "ldr  x16, [x19, #0x10]  \n"
        "mov  x0,  x22           \n"   // win
        "mov  x2,  x24           \n"
        "blr  x16                \n"
        "str  x0,  [x19, #0xA8]  \n"   // diag: firstResponder
        "mov  x25, x0            \n"   // x25 = fr
        "cmp  x25, #0            \n"
        "csel x26, x25, x22, ne  \n"   // target = fr ?: win
        // [target motionBegan:1 withEvent:nil]
        "ldr  x16, [x19, #0x08]  \n"
        "ldr  x0,  [x19, #0x58]  \n"   // "motionBegan:withEvent:"
        "blr  x16                \n"
        "mov  x1,  x0            \n"
        "ldr  x16, [x19, #0x10]  \n"
        "mov  x0,  x26           \n"
        "mov  x2,  #1            \n"   // UIEventSubtypeMotionShake
        "mov  x3,  #0            \n"   // event = nil
        "blr  x16                \n"
        // [target motionEnded:1 withEvent:nil]
        "ldr  x16, [x19, #0x08]  \n"
        "ldr  x0,  [x19, #0x60]  \n"   // "motionEnded:withEvent:"
        "blr  x16                \n"
        "mov  x1,  x0            \n"
        "ldr  x16, [x19, #0x10]  \n"
        "mov  x0,  x26           \n"
        "mov  x2,  #1            \n"
        "mov  x3,  #0            \n"
        "blr  x16                \n"
        "ldp  x25, x26, [sp, #0x40]   \n"
        "ldp  x23, x24, [sp, #0x30]   \n"
        "ldp  x21, x22, [sp, #0x20]   \n"
        "ldp  x19, x20, [sp, #0x10]   \n"
        "ldp  x29, x30, [sp], #0x60   \n"
        "ret                     \n"
    );
}
#define SHELLCODE_INNER_OFFSET   0x080
#define SHELLCODE_MAIN_OFFSET    0x100
// Generous upper bound on the bytes to copy out of our own __text. Covers all
// three stages; copying a little past MAIN_WORK into adjacent code is harmless
// because only offsets 0x000 / 0x080 / 0x100 are ever branched to.
static const size_t kShellcodeSize = 0x280;

// Data page layout — every field is a target-process address (or C string).
// Offsets here MUST match the [x19, #...] loads in the shellcode above.
struct shake_args {
    uint64_t objc_getClass;        // +0x00
    uint64_t sel_registerName;     // +0x08
    uint64_t objc_msgSend;         // +0x10
    uint64_t pthread_create_fn;    // +0x18
    uint64_t dispatch_async_f;     // +0x20
    uint64_t inner_entry;          // +0x28
    uint64_t main_queue;           // +0x30
    uint64_t main_entry;           // +0x38
    uint64_t s_UIApplication;      // +0x40
    uint64_t s_sharedApplication;  // +0x48
    uint64_t s_keyWindow;          // +0x50
    uint64_t s_motionBegan;        // +0x58
    uint64_t s_motionEnded;        // +0x60
    uint64_t s_NSString;           // +0x68
    uint64_t s_stringWithUTF8;     // +0x70
    uint64_t s_valueForKey;        // +0x78
    uint64_t s_firstResponder;     // +0x80
    uint64_t pause_fn;             // +0x88  (OUTER parks here, 0 CPU)
    uint64_t _pad[2];              // +0x90..0x98
    uint64_t out_keyWindow;        // +0xA0  (written by MAIN_WORK, diag only)
    uint64_t out_firstResponder;   // +0xA8  (written by MAIN_WORK, diag only)
};
// C strings are appended after the struct at this page offset.
#define STRINGS_OFFSET 0x200

// MARK: - Shared cache slide

static uintptr_t get_self_shared_cache_slide(void) {
    struct task_dyld_info info = {0};
    mach_msg_type_number_t count = TASK_DYLD_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_DYLD_INFO, (task_info_t)&info, &count) != KERN_SUCCESS) {
        return 0;
    }
    if (!info.all_image_info_addr) return 0;
    const struct dyld_all_image_infos *aii =
        (const struct dyld_all_image_infos *)(uintptr_t)info.all_image_info_addr;
    return (uintptr_t)aii->sharedCacheSlide;
}

static uintptr_t get_target_shared_cache_slide(task_t task) {
    struct task_dyld_info info = {0};
    mach_msg_type_number_t count = TASK_DYLD_INFO_COUNT;
    if (task_info(task, TASK_DYLD_INFO, (task_info_t)&info, &count) != KERN_SUCCESS) {
        return 0;
    }
    if (!info.all_image_info_addr) return 0;

    uint8_t buf[256] = {0};
    mach_vm_size_t got = 0;
    kern_return_t kr = mach_vm_read_overwrite(
        task, info.all_image_info_addr, sizeof(buf), (mach_vm_address_t)buf, &got);
    if (kr != KERN_SUCCESS || got < 160) {
        diag("  read all_image_infos kr=%d got=%llu", kr, (unsigned long long)got);
        return 0;
    }
    return *(uintptr_t *)(buf + 152);  // sharedCacheSlide (v15+)
}

// MARK: - Foreground discovery via BKSApplicationStateMonitor

static int app_state_for_pid(pid_t pid) {
    Class cls = NSClassFromString(@"BKSApplicationStateMonitor");
    if (!cls) return -1;
    id monitor = ((id(*)(id, SEL))objc_msgSend)(
        ((id(*)(Class, SEL))objc_msgSend)(cls, sel_registerName("alloc")),
        sel_registerName("init"));
    if (!monitor) return -1;
    SEL sel = sel_registerName("mostElevatedApplicationStateForPID:");
    if (![monitor respondsToSelector:sel]) return -2;
    return ((int(*)(id, SEL, pid_t))objc_msgSend)(monitor, sel, pid);
}

static BOOL is_app_path(const char *path) {
    return path && (strstr(path, "/Application/") != NULL ||
                    strstr(path, "/Applications/") != NULL);
}

// Pick the best injection target: user-app pid where task_for_pid works,
// preferring foreground-active state.
static pid_t pick_target_pid(NSMutableDictionary *r) {
    int npids_byte = proc_listpids(PROC_ALL_PIDS, 0, NULL, 0);
    int cap = npids_byte / (int)sizeof(pid_t) + 16;
    pid_t *pids = calloc(cap, sizeof(pid_t));
    int got_byte = proc_listpids(PROC_ALL_PIDS, 0, pids, cap * (int)sizeof(pid_t));
    int npids = got_byte / (int)sizeof(pid_t);

    pid_t best = 0;
    int bestState = INT_MIN;
    NSMutableArray *cands = [NSMutableArray array];

    for (int i = 0; i < npids; i++) {
        pid_t pid = pids[i];
        if (pid <= 1) continue;

        char path[PROC_PIDPATHINFO_MAXSIZE] = {0};
        if (proc_pidpath(pid, path, sizeof(path)) <= 0) continue;
        if (!is_app_path(path)) continue;
        if (strstr(path, ".appex/")) continue;  // skip plugin/extension processes

        task_t task = MACH_PORT_NULL;
        if (task_for_pid(mach_task_self(), pid, &task) != KERN_SUCCESS) continue;
        mach_port_deallocate(mach_task_self(), task);

        int state = app_state_for_pid(pid);
        diag("  candidate pid=%d state=%d path=%s", pid, state, path);
        [cands addObject:@{@"pid": @(pid), @"state": @(state),
                           @"path": [NSString stringWithUTF8String:path]}];
        if (state > bestState) { bestState = state; best = pid; }
    }
    free(pids);

    r[@"candidates"] = cands;
    r[@"selected_pid"] = @(best);
    r[@"selected_state"] = @(bestState);
    return best;
}

// MARK: - Symbol resolution

// Resolve a shared-cache symbol in our process and re-base it into the target.
static uint64_t target_sym(const char *name, uintptr_t self_slide, uintptr_t target_slide) {
    void *p = dlsym(RTLD_DEFAULT, name);
    if (!p) return 0;
    return (uint64_t)((uintptr_t)p - self_slide + target_slide);
}

// MARK: - Mach injection

static BOOL inject_shake(pid_t pid, NSMutableDictionary *r) {
    task_t task = MACH_PORT_NULL;
    kern_return_t kr = task_for_pid(mach_task_self(), pid, &task);
    if (kr != KERN_SUCCESS) {
        diag("  task_for_pid pid=%d kr=%d (%s)", pid, kr, mach_error_string(kr));
        r[@"err"] = @"task_for_pid"; r[@"kr"] = @(kr);
        return NO;
    }

    uintptr_t self_slide = get_self_shared_cache_slide();
    uintptr_t target_slide = get_target_shared_cache_slide(task);

    // Resolve every shared-cache symbol we hand to the shellcode.
    uint64_t objc_getClass_t   = target_sym("objc_getClass", self_slide, target_slide);
    uint64_t sel_registerName_t = target_sym("sel_registerName", self_slide, target_slide);
    uint64_t objc_msgSend_t    = target_sym("objc_msgSend", self_slide, target_slide);
    uint64_t pthread_fn_t      = target_sym("pthread_create_from_mach_thread", self_slide, target_slide);
    uint64_t dispatch_async_f_t = target_sym("dispatch_async_f", self_slide, target_slide);
    uint64_t pause_t           = target_sym("pause", self_slide, target_slide);
    if (!objc_getClass_t || !sel_registerName_t || !objc_msgSend_t ||
        !pthread_fn_t || !dispatch_async_f_t || !pause_t) {
        diag("  symbol resolution failed");
        r[@"err"] = @"sym_missing";
        mach_port_deallocate(mach_task_self(), task);
        return NO;
    }
    // The main queue is a data symbol; rebase the value we hold locally.
    uint64_t main_queue_t =
        (uint64_t)((uintptr_t)dispatch_get_main_queue() - self_slide + target_slide);

    diag("  slides self=0x%lx tgt=0x%lx", self_slide, target_slide);

    // Allocate code, data and stack in the target.
    mach_vm_address_t code_addr = 0, data_addr = 0, stack_addr = 0;
    if (mach_vm_allocate(task, &code_addr, 0x4000, VM_FLAGS_ANYWHERE) != KERN_SUCCESS ||
        mach_vm_allocate(task, &data_addr, 0x4000, VM_FLAGS_ANYWHERE) != KERN_SUCCESS ||
        mach_vm_allocate(task, &stack_addr, 0x8000, VM_FLAGS_ANYWHERE) != KERN_SUCCESS) {
        diag("  alloc failed");
        r[@"err"] = @"alloc";
        mach_port_deallocate(mach_task_self(), task);
        return NO;
    }

    // Write + protect the code page.
    kr = mach_vm_write(task, code_addr, (vm_offset_t)&shake_shellcode,
                       (mach_msg_type_number_t)kShellcodeSize);
    if (kr == KERN_SUCCESS) {
        kr = mach_vm_protect(task, code_addr, 0x4000, FALSE, VM_PROT_READ | VM_PROT_EXECUTE);
    }
    if (kr != KERN_SUCCESS) {
        diag("  write/protect code kr=%d (%s)", kr, mach_error_string(kr));
        r[@"err"] = @"code"; r[@"kr"] = @(kr);
        mach_port_deallocate(mach_task_self(), task);
        return NO;
    }

    // Build the data page locally, then write it in one shot.
    uint8_t page[0x4000] = {0};
    struct shake_args *a = (struct shake_args *)page;
    a->objc_getClass      = objc_getClass_t;
    a->sel_registerName   = sel_registerName_t;
    a->objc_msgSend       = objc_msgSend_t;
    a->pthread_create_fn  = pthread_fn_t;
    a->dispatch_async_f   = dispatch_async_f_t;
    a->inner_entry        = (uint64_t)(code_addr + SHELLCODE_INNER_OFFSET);
    a->main_queue         = main_queue_t;
    a->main_entry         = (uint64_t)(code_addr + SHELLCODE_MAIN_OFFSET);
    a->pause_fn           = pause_t;

    // Append the C strings and point the struct fields at their target addrs.
    const char *strs[] = {
        "UIApplication", "sharedApplication", "keyWindow",
        "motionBegan:withEvent:", "motionEnded:withEvent:",
        "NSString", "stringWithUTF8String:", "valueForKey:", "firstResponder",
    };
    uint64_t *slots[] = {
        &a->s_UIApplication, &a->s_sharedApplication, &a->s_keyWindow,
        &a->s_motionBegan, &a->s_motionEnded,
        &a->s_NSString, &a->s_stringWithUTF8, &a->s_valueForKey, &a->s_firstResponder,
    };
    size_t off = STRINGS_OFFSET;
    for (size_t i = 0; i < sizeof(strs) / sizeof(strs[0]); i++) {
        size_t len = strlen(strs[i]) + 1;
        memcpy(page + off, strs[i], len);
        *slots[i] = (uint64_t)(data_addr + off);
        off += len;
    }

    kr = mach_vm_write(task, data_addr, (vm_offset_t)page, sizeof(page));
    if (kr != KERN_SUCCESS) {
        diag("  write data kr=%d", kr);
        r[@"err"] = @"data"; r[@"kr"] = @(kr);
        mach_port_deallocate(mach_task_self(), task);
        return NO;
    }

    diag("  code=0x%llx data=0x%llx stack=0x%llx",
         (unsigned long long)code_addr, (unsigned long long)data_addr,
         (unsigned long long)stack_addr);

    // Spawn the OUTER stage on a raw Mach thread.
    arm_thread_state64_t state = {0};
    state.__x[0] = (uint64_t)data_addr;
    __darwin_arm_thread_state64_set_pc_fptr(state, (void *)code_addr);
    __darwin_arm_thread_state64_set_sp(state, (void *)(stack_addr + 0x8000 - 512));

    thread_act_t thread = MACH_PORT_NULL;
    kr = thread_create_running(task, ARM_THREAD_STATE64,
                               (thread_state_t)&state, ARM_THREAD_STATE64_COUNT, &thread);
    if (kr != KERN_SUCCESS) {
        diag("  thread_create_running kr=%d (%s)", kr, mach_error_string(kr));
        r[@"err"] = @"thread_create_running"; r[@"kr"] = @(kr);
        mach_port_deallocate(mach_task_self(), task);
        return NO;
    }

    diag("  injected thread=0x%x into pid=%d", thread, pid);
    r[@"injected"] = @YES;
    r[@"method"] = @"shellcode";
    mach_port_deallocate(mach_task_self(), thread);
    mach_port_deallocate(mach_task_self(), task);
    return YES;
}

// MARK: - Load + entry point

static BOOL gLoaded = NO;

BOOL vp_motion_load(void) {
    if (gLoaded) return YES;
    // Need BKSApplicationStateMonitor for foreground filtering.
    dlopen("/System/Library/PrivateFrameworks/BackBoardServices.framework/BackBoardServices", RTLD_NOW);
    diag("vp_motion_load: ready (shellcode shake)");
    gLoaded = YES;
    return YES;
}

BOOL vp_motion_available(void) {
    return gLoaded;
}

NSDictionary *vp_handle_motion_command(NSDictionary *msg) {
    id reqId = msg[@"id"];
    NSMutableDictionary *r = vp_make_response(@"ok", reqId);

    if (!gLoaded) {
        NSMutableDictionary *err = vp_make_response(@"err", reqId);
        err[@"msg"] = @"motion not loaded";
        return err;
    }

    pid_t pid = pick_target_pid(r);
    if (pid <= 0) {
        NSMutableDictionary *err = vp_make_response(@"err", reqId);
        err[@"msg"] = @"no injectable foreground app (no dev-signed user app with task_for_pid access)";
        return err;
    }
    diag("  target pid=%d", pid);

    if (!inject_shake(pid, r)) {
        NSMutableDictionary *err = vp_make_response(@"err", reqId);
        err[@"msg"] = @"injection failed";
        err[@"detail"] = r;
        return err;
    }
    return r;
}
