#import "vphoned_install.h"
#import "vphoned_apps.h"
#import "unarchive.h"

#import <Security/Security.h>
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <mach-o/fat.h>
#include <mach-o/loader.h>
#include <objc/message.h>
#include <signal.h>
#include <spawn.h>
#include <sqlite3.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

#import "vphoned_protocol.h"

typedef struct __SecCode const *SecStaticCodeRef;
typedef CF_OPTIONS(uint32_t, SecCSFlags) {
    kSecCSDefaultFlags = 0
};
#define kSecCSRequirementInformation (1 << 2)

OSStatus SecStaticCodeCreateWithPathAndAttributes(
    CFURLRef path,
    SecCSFlags flags,
    CFDictionaryRef attributes,
    SecStaticCodeRef *staticCode
);
OSStatus SecCodeCopySigningInformation(SecStaticCodeRef code, SecCSFlags flags, CFDictionaryRef *information);
extern CFStringRef kSecCodeInfoEntitlementsDict;

@interface LSApplicationProxy : NSObject
+ (instancetype)applicationProxyForIdentifier:(NSString *)identifier;
@property (nonatomic, readonly) NSString *bundleIdentifier;
@property (nonatomic, readonly) NSURL *bundleURL;
@property (nonatomic, readonly) NSURL *dataContainerURL;
@property (getter=isInstalled, nonatomic, readonly) BOOL installed;
@end

@interface LSApplicationWorkspace : NSObject
+ (instancetype)defaultWorkspace;
- (NSArray *)allInstalledApplications;
- (BOOL)registerApplicationDictionary:(NSDictionary *)dict;
- (BOOL)unregisterApplication:(id)arg1;
@end

@interface LSEnumerator : NSEnumerator
@property (nonatomic, copy) NSPredicate *predicate;
+ (instancetype)enumeratorForApplicationProxiesWithOptions:(NSUInteger)options;
@end

@interface MCMContainer : NSObject
+ (id)containerWithIdentifier:(id)arg1 createIfNecessary:(BOOL)arg2 existed:(BOOL *)arg3 error:(id *)arg4;
@property (nonatomic, readonly) NSURL *url;
@end

@interface MCMContainerManager : NSObject
+ (instancetype)defaultManager;
- (id)containerWithContentClass:(NSInteger)contentClass identifier:(id)identifier error:(id *)error;
- (id)deleteContainers:(NSArray *)containers withCompletion:(id)completion;
@end

static NSString *const VPManagedMarker = @"_VPhone";

static void vp_load_private_frameworks(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        dlopen("/System/Library/PrivateFrameworks/MobileContainerManager.framework/MobileContainerManager", RTLD_NOW);
        dlopen("/System/Library/Frameworks/CoreServices.framework/CoreServices", RTLD_NOW);
    });
}

static NSString *vp_trimmed_output(NSString *string) {
    NSString *trimmed = [string stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trimmed.length > 4000) {
        return [trimmed substringToIndex:4000];
    }
    return trimmed;
}

static NSDictionary *vp_info_dictionary_for_app_path(NSString *appPath) {
    if (appPath.length == 0) return nil;
    return [NSDictionary dictionaryWithContentsOfFile:[appPath stringByAppendingPathComponent:@"Info.plist"]];
}

static NSString *vp_app_id_for_app_path(NSString *appPath) {
    return vp_info_dictionary_for_app_path(appPath)[@"CFBundleIdentifier"];
}

static NSString *vp_app_main_executable_path_for_app_path(NSString *appPath) {
    NSDictionary *info = vp_info_dictionary_for_app_path(appPath);
    NSString *executable = info[@"CFBundleExecutable"];
    if (executable.length == 0) return nil;
    return [appPath stringByAppendingPathComponent:executable];
}

static NSString *vp_find_app_name_in_bundle_path(NSString *bundlePath) {
    NSArray<NSString *> *bundleItems = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:bundlePath error:nil];
    for (NSString *bundleItem in bundleItems) {
        if ([bundleItem.pathExtension isEqualToString:@"app"]) {
            return bundleItem;
        }
    }
    return nil;
}

static NSString *vp_find_app_path_in_bundle_path(NSString *bundlePath) {
    NSString *appName = vp_find_app_name_in_bundle_path(bundlePath);
    if (appName.length == 0) return nil;
    return [bundlePath stringByAppendingPathComponent:appName];
}

static NSURL *vp_find_app_url_in_bundle_url(NSURL *bundleURL) {
    NSString *appName = vp_find_app_name_in_bundle_path(bundleURL.path);
    if (appName.length == 0) return nil;
    return [bundleURL URLByAppendingPathComponent:appName];
}

static BOOL vp_is_macho_file(NSString *filePath) {
    FILE *file = fopen(filePath.fileSystemRepresentation, "r");
    if (!file) return NO;

    uint32_t magic = 0;
    fread(&magic, sizeof(uint32_t), 1, file);
    fclose(file);

    return magic == FAT_MAGIC || magic == FAT_CIGAM || magic == MH_MAGIC_64 || magic == MH_CIGAM_64;
}

static void vp_fix_permissions_of_app_bundle(NSString *appBundlePath) {
    NSURL *fileURL = nil;
    NSDirectoryEnumerator *enumerator = [[NSFileManager defaultManager]
        enumeratorAtURL:[NSURL fileURLWithPath:appBundlePath]
        includingPropertiesForKeys:nil
        options:0
        errorHandler:nil];
    while ((fileURL = [enumerator nextObject])) {
        NSString *filePath = fileURL.path;
        chown(filePath.fileSystemRepresentation, 33, 33);
        chmod(filePath.fileSystemRepresentation, 0644);
    }

    enumerator = [[NSFileManager defaultManager]
        enumeratorAtURL:[NSURL fileURLWithPath:appBundlePath]
        includingPropertiesForKeys:nil
        options:0
        errorHandler:nil];
    while ((fileURL = [enumerator nextObject])) {
        NSString *filePath = fileURL.path;
        BOOL isDir = NO;
        [[NSFileManager defaultManager] fileExistsAtPath:filePath isDirectory:&isDir];
        if (isDir || vp_is_macho_file(filePath)) {
            chmod(filePath.fileSystemRepresentation, 0755);
        }
    }
}

static NSString *vp_read_all_from_fd(int fd) {
    NSMutableData *data = [NSMutableData data];
    uint8_t buf[4096];
    ssize_t n = 0;
    while ((n = read(fd, buf, sizeof(buf))) > 0) {
        [data appendBytes:buf length:(NSUInteger)n];
    }
    if (data.length == 0) return @"";
    NSString *string = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    return string ?: @"";
}

static int vp_run_process_with_output(NSString *path, NSArray<NSString *> *args, NSString **output) {
    NSUInteger argc = args.count + 2;
    char **argv = calloc(argc, sizeof(char *));
    if (!argv) return ENOMEM;

    argv[0] = strdup(path.fileSystemRepresentation);
    for (NSUInteger i = 0; i < args.count; i++) {
        argv[i + 1] = strdup(args[i].fileSystemRepresentation);
    }
    argv[argc - 1] = NULL;

    int pipeFds[2] = {-1, -1};
    if (pipe(pipeFds) != 0) {
        for (NSUInteger i = 0; i < argc - 1; i++) free(argv[i]);
        free(argv);
        return errno;
    }

    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_adddup2(&actions, pipeFds[1], STDOUT_FILENO);
    posix_spawn_file_actions_adddup2(&actions, pipeFds[1], STDERR_FILENO);
    posix_spawn_file_actions_addclose(&actions, pipeFds[0]);

    pid_t pid = 0;
    int spawnError = posix_spawn(&pid, path.fileSystemRepresentation, &actions, NULL, argv, NULL);

    posix_spawn_file_actions_destroy(&actions);
    close(pipeFds[1]);

    NSString *captured = vp_read_all_from_fd(pipeFds[0]);
    close(pipeFds[0]);

    int status = 0;
    if (spawnError == 0 && waitpid(pid, &status, 0) < 0) {
        spawnError = errno;
    }

    for (NSUInteger i = 0; i < argc - 1; i++) free(argv[i]);
    free(argv);

    if (output) *output = captured;

    if (spawnError != 0) return spawnError;
    if (WIFEXITED(status)) return WEXITSTATUS(status);
    if (WIFSIGNALED(status)) return 128 + WTERMSIG(status);
    return -1;
}

static NSString *vp_find_ldid_path(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *path in @[
        @"/var/jb/usr/bin/ldid",
        @"/iosbinpack64/usr/bin/ldid",
        @"/usr/bin/ldid",
    ]) {
        if ([fm isExecutableFileAtPath:path]) {
            return path;
        }
    }
    return nil;
}


static SecStaticCodeRef vp_get_static_code_ref(NSString *binaryPath) {
    if (binaryPath.length == 0) return NULL;

    CFURLRef binaryURL = CFURLCreateWithFileSystemPath(
        kCFAllocatorDefault,
        (__bridge CFStringRef)binaryPath,
        kCFURLPOSIXPathStyle,
        false
    );
    if (binaryURL == NULL) return NULL;

    SecStaticCodeRef codeRef = NULL;
    OSStatus result = SecStaticCodeCreateWithPathAndAttributes(binaryURL, kSecCSDefaultFlags, NULL, &codeRef);
    CFRelease(binaryURL);
    if (result != errSecSuccess) {
        return NULL;
    }
    return codeRef;
}

static NSDictionary *vp_dump_entitlements_from_binary_at_path(NSString *binaryPath) {
    SecStaticCodeRef codeRef = vp_get_static_code_ref(binaryPath);
    if (codeRef == NULL) return nil;

    CFDictionaryRef signingInfo = NULL;
    OSStatus result = SecCodeCopySigningInformation(codeRef, kSecCSRequirementInformation, &signingInfo);
    CFRelease(codeRef);
    if (result != errSecSuccess || signingInfo == NULL) {
        if (signingInfo) CFRelease(signingInfo);
        return nil;
    }

    NSDictionary *entitlementsNSDict = nil;
    CFDictionaryRef entitlements = CFDictionaryGetValue(signingInfo, kSecCodeInfoEntitlementsDict);
    if (entitlements && CFGetTypeID(entitlements) == CFDictionaryGetTypeID()) {
        entitlementsNSDict = [(__bridge NSDictionary *)entitlements copy];
    }

    CFRelease(signingInfo);
    return entitlementsNSDict;
}

static int vp_sign_binary(
    NSString *filePath,
    NSDictionary *entitlements,
    NSString *certPath,
    NSString *ldidPath,
    NSString **errorOutput
) {
    if (ldidPath.length == 0) {
        if (errorOutput) *errorOutput = @"ldid not found in guest or uploaded payload";
        return ENOENT;
    }

    NSString *entitlementsPath = nil;
    NSMutableArray<NSString *> *args = [NSMutableArray array];
    if (entitlements) {
        NSData *entitlementsXML = [NSPropertyListSerialization
            dataWithPropertyList:entitlements
            format:NSPropertyListXMLFormat_v1_0
            options:0
            error:nil];
        if (entitlementsXML) {
            entitlementsPath = [[NSTemporaryDirectory() stringByAppendingPathComponent:[NSUUID UUID].UUIDString]
                stringByAppendingPathExtension:@"plist"];
            [entitlementsXML writeToFile:entitlementsPath atomically:NO];
            [args addObject:[@"-S" stringByAppendingString:entitlementsPath]];
        } else {
            [args addObject:@"-S"];
        }
    } else {
        [args addObject:@"-S"];
    }

    if (certPath.length > 0) {
        [args addObject:@"-M"];
        [args addObject:[@"-K" stringByAppendingString:certPath]];
    }

    [args addObject:filePath];

    NSString *output = @"";
    int ret = vp_run_process_with_output(ldidPath, args, &output);
    if (entitlementsPath) {
        [[NSFileManager defaultManager] removeItemAtPath:entitlementsPath error:nil];
    }
    if (errorOutput) *errorOutput = output;
    return ret;
}

static int vp_sign_app(NSString *appPath, NSString *certPath, NSString *ldidPath, NSString **errorOutput) {
    if (!vp_info_dictionary_for_app_path(appPath)) {
        if (errorOutput) *errorOutput = @"missing app Info.plist";
        return 172;
    }

    NSString *mainExecutablePath = vp_app_main_executable_path_for_app_path(appPath);
    if (mainExecutablePath.length == 0 || ![[NSFileManager defaultManager] fileExistsAtPath:mainExecutablePath]) {
        if (errorOutput) *errorOutput = @"missing main executable";
        return 174;
    }

    NSURL *fileURL = nil;
    NSDirectoryEnumerator *enumerator = [[NSFileManager defaultManager]
        enumeratorAtURL:[NSURL fileURLWithPath:appPath]
        includingPropertiesForKeys:nil
        options:0
        errorHandler:nil];
    while ((fileURL = [enumerator nextObject])) {
        NSString *filePath = fileURL.path;
        if (![filePath.lastPathComponent isEqualToString:@"Info.plist"]) {
            continue;
        }

        NSDictionary *infoDict = [NSDictionary dictionaryWithContentsOfFile:filePath];
        NSString *bundleId = infoDict[@"CFBundleIdentifier"];
        NSString *bundleExecutable = infoDict[@"CFBundleExecutable"];
        if (bundleId.length == 0 || bundleExecutable.length == 0) {
            continue;
        }

        NSString *bundleMainExecutablePath = [[filePath stringByDeletingLastPathComponent]
            stringByAppendingPathComponent:bundleExecutable];
        if (![[NSFileManager defaultManager] fileExistsAtPath:bundleMainExecutablePath]) {
            continue;
        }

        NSString *packageType = infoDict[@"CFBundlePackageType"];
        if ([packageType isEqualToString:@"FMWK"]) {
            continue;
        }

        NSMutableDictionary *entitlementsToUse = [vp_dump_entitlements_from_binary_at_path(bundleMainExecutablePath) mutableCopy];
        if (!entitlementsToUse && [bundleMainExecutablePath isEqualToString:mainExecutablePath]) {
            entitlementsToUse = [@{
                @"application-identifier": @"TROLLTROLL.*",
                @"com.apple.developer.team-identifier": @"TROLLTROLL",
                @"get-task-allow": @YES,
                @"keychain-access-groups": @[@"TROLLTROLL.*", @"com.apple.token"],
            } mutableCopy];
        }
        if (!entitlementsToUse) {
            entitlementsToUse = [NSMutableDictionary dictionary];
        }

        NSObject *containerRequired = entitlementsToUse[@"com.apple.private.security.container-required"];
        BOOL shouldWriteContainerRequired = YES;
        if ([containerRequired isKindOfClass:[NSString class]]) {
            shouldWriteContainerRequired = NO;
        } else if ([containerRequired isKindOfClass:[NSNumber class]]) {
            shouldWriteContainerRequired = [(NSNumber *)containerRequired boolValue];
        }
        BOOL noContainer = [entitlementsToUse[@"com.apple.private.security.no-container"] respondsToSelector:@selector(boolValue)]
            ? [entitlementsToUse[@"com.apple.private.security.no-container"] boolValue]
            : NO;
        BOOL noSandbox = [entitlementsToUse[@"com.apple.private.security.no-sandbox"] respondsToSelector:@selector(boolValue)]
            ? [entitlementsToUse[@"com.apple.private.security.no-sandbox"] boolValue]
            : NO;
        if (shouldWriteContainerRequired && !noContainer && !noSandbox) {
            entitlementsToUse[@"com.apple.private.security.container-required"] = bundleId;
        }
        entitlementsToUse[@"jb.pmap_cs_custom_trust"] = @"PMAP_CS_APP_STORE";

        NSString *signOutput = @"";
        int ret = vp_sign_binary(bundleMainExecutablePath, entitlementsToUse, certPath, ldidPath, &signOutput);
        if (ret != 0) {
            if (errorOutput) *errorOutput = signOutput;
            return 173;
        }
    }

    NSString *recursiveOutput = @"";
    int recursiveRet = vp_sign_binary(appPath, nil, certPath, ldidPath, &recursiveOutput);
    if (recursiveRet != 0) {
        if (errorOutput) *errorOutput = recursiveOutput;
        return 173;
    }
    return 0;
}

static NSDictionary *vp_construct_groups_containers_for_entitlements(NSDictionary *entitlements, BOOL systemGroups) {
    if (!entitlements) return nil;

    NSString *entitlementForGroups = systemGroups
        ? @"com.apple.security.system-groups"
        : @"com.apple.security.application-groups";
    Class mcmClass = NSClassFromString(systemGroups ? @"MCMSystemDataContainer" : @"MCMSharedDataContainer");
    if (!mcmClass) return nil;

    NSArray *groupIDs = entitlements[entitlementForGroups];
    if (![groupIDs isKindOfClass:[NSArray class]]) return nil;

    NSMutableDictionary *groupContainers = [NSMutableDictionary dictionary];
    for (NSString *groupID in groupIDs) {
        MCMContainer *container = [mcmClass containerWithIdentifier:groupID createIfNecessary:YES existed:nil error:nil];
        if (container.url.path.length > 0) {
            groupContainers[groupID] = container.url.path;
        }
    }
    return groupContainers.count > 0 ? groupContainers.copy : nil;
}

static BOOL vp_construct_containerization_for_entitlements(NSDictionary *entitlements, NSString **customContainerOut) {
    NSNumber *noContainer = entitlements[@"com.apple.private.security.no-container"];
    if ([noContainer isKindOfClass:[NSNumber class]] && noContainer.boolValue) {
        return NO;
    }

    NSObject *containerRequired = entitlements[@"com.apple.private.security.container-required"];
    if ([containerRequired isKindOfClass:[NSNumber class]] && ![(NSNumber *)containerRequired boolValue]) {
        return NO;
    }
    if ([containerRequired isKindOfClass:[NSString class]]) {
        *customContainerOut = (NSString *)containerRequired;
    }
    return YES;
}

static NSString *vp_construct_team_identifier_for_entitlements(NSDictionary *entitlements) {
    NSString *teamIdentifier = entitlements[@"com.apple.developer.team-identifier"];
    return [teamIdentifier isKindOfClass:[NSString class]] ? teamIdentifier : nil;
}

static NSDictionary *vp_construct_environment_variables_for_container_path(NSString *containerPath, BOOL isContainerized) {
    NSString *homeDir = isContainerized ? containerPath : @"/var/mobile";
    NSString *tmpDir = isContainerized ? [containerPath stringByAppendingPathComponent:@"tmp"] : @"/var/tmp";
    return @{
        @"CFFIXED_USER_HOME": homeDir,
        @"HOME": homeDir,
        @"TMPDIR": tmpDir,
    };
}

static NSSet<NSString *> *vp_immutable_app_bundle_identifiers(void) {
    NSMutableSet<NSString *> *systemAppIdentifiers = [NSMutableSet set];
    LSEnumerator *enumerator = [LSEnumerator enumeratorForApplicationProxiesWithOptions:0];
    LSApplicationProxy *appProxy = nil;
    while ((appProxy = [enumerator nextObject])) {
        if (appProxy.installed && ![appProxy.bundleURL.path hasPrefix:@"/private/var/containers"]) {
            [systemAppIdentifiers addObject:appProxy.bundleIdentifier.lowercaseString];
        }
    }
    return systemAppIdentifiers.copy;
}

static BOOL vp_register_path(NSString *path, BOOL unregister, BOOL forceSystem) {
    if (path.length == 0) return NO;

    LSApplicationWorkspace *workspace = [LSApplicationWorkspace defaultWorkspace];
    if (unregister && ![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        LSApplicationProxy *app = [LSApplicationProxy applicationProxyForIdentifier:path];
        if (app.bundleURL.path.length > 0) {
            path = app.bundleURL.path;
        }
    }

    path = path.stringByResolvingSymlinksInPath.stringByStandardizingPath;
    NSDictionary *appInfoPlist = [NSDictionary dictionaryWithContentsOfFile:[path stringByAppendingPathComponent:@"Info.plist"]];
    NSString *appBundleID = appInfoPlist[@"CFBundleIdentifier"];
    if (appBundleID.length == 0) return NO;
    if ([vp_immutable_app_bundle_identifiers() containsObject:appBundleID.lowercaseString]) return NO;

    if (!unregister) {
        NSString *appExecutablePath = [path stringByAppendingPathComponent:appInfoPlist[@"CFBundleExecutable"]];
        NSDictionary *entitlements = vp_dump_entitlements_from_binary_at_path(appExecutablePath);

        NSString *appDataContainerID = appBundleID;
        BOOL appContainerized = vp_construct_containerization_for_entitlements(entitlements ?: @{}, &appDataContainerID);

        Class appDataContainerClass = NSClassFromString(@"MCMAppDataContainer");
        MCMContainer *appDataContainer = [appDataContainerClass
            containerWithIdentifier:appDataContainerID
            createIfNecessary:YES
            existed:nil
            error:nil];
        NSString *containerPath = appDataContainer.url.path;

        BOOL isRemovableSystemApp = [[NSFileManager defaultManager]
            fileExistsAtPath:[@"/System/Library/AppSignatures" stringByAppendingPathComponent:appBundleID]];
        BOOL registerAsUser = [path hasPrefix:@"/var/containers"] && !isRemovableSystemApp && !forceSystem;

        NSMutableDictionary *dictToRegister = [NSMutableDictionary dictionary];
        if (entitlements) {
            dictToRegister[@"Entitlements"] = entitlements;
        }

        dictToRegister[@"ApplicationType"] = registerAsUser ? @"User" : @"System";
        dictToRegister[@"CFBundleIdentifier"] = appBundleID;
        dictToRegister[@"CodeInfoIdentifier"] = appBundleID;
        dictToRegister[@"CompatibilityState"] = @0;
        dictToRegister[@"IsContainerized"] = @(appContainerized);
        if (containerPath.length > 0) {
            dictToRegister[@"Container"] = containerPath;
            dictToRegister[@"EnvironmentVariables"] =
                vp_construct_environment_variables_for_container_path(containerPath, appContainerized);
        }
        dictToRegister[@"IsDeletable"] = @YES;
        dictToRegister[@"Path"] = path;
        dictToRegister[@"SignerOrganization"] = @"Apple Inc.";
        dictToRegister[@"SignatureVersion"] = @132352;
        dictToRegister[@"SignerIdentity"] = @"Apple iPhone OS Application Signing";
        dictToRegister[@"IsAdHocSigned"] = @YES;
        dictToRegister[@"LSInstallType"] = @1;
        dictToRegister[@"HasMIDBasedSINF"] = @0;
        dictToRegister[@"MissingSINF"] = @0;
        dictToRegister[@"FamilyID"] = @0;
        dictToRegister[@"IsOnDemandInstallCapable"] = @0;

        NSString *teamIdentifier = vp_construct_team_identifier_for_entitlements(entitlements ?: @{});
        if (teamIdentifier.length > 0) {
            dictToRegister[@"TeamIdentifier"] = teamIdentifier;
        }

        NSDictionary *appGroupContainers = vp_construct_groups_containers_for_entitlements(entitlements, NO);
        NSDictionary *systemGroupContainers = vp_construct_groups_containers_for_entitlements(entitlements, YES);
        NSMutableDictionary *groupContainers = [NSMutableDictionary dictionary];
        [groupContainers addEntriesFromDictionary:appGroupContainers];
        [groupContainers addEntriesFromDictionary:systemGroupContainers];
        if (groupContainers.count > 0) {
            if (appGroupContainers.count > 0) {
                dictToRegister[@"HasAppGroupContainers"] = @YES;
            }
            if (systemGroupContainers.count > 0) {
                dictToRegister[@"HasSystemGroupContainers"] = @YES;
            }
            dictToRegister[@"GroupContainers"] = groupContainers.copy;
        }

        NSString *pluginsPath = [path stringByAppendingPathComponent:@"PlugIns"];
        NSArray<NSString *> *plugins = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:pluginsPath error:nil];
        NSMutableDictionary *bundlePlugins = [NSMutableDictionary dictionary];
        for (NSString *pluginName in plugins) {
            NSString *pluginPath = [pluginsPath stringByAppendingPathComponent:pluginName];
            NSDictionary *pluginInfoPlist =
                [NSDictionary dictionaryWithContentsOfFile:[pluginPath stringByAppendingPathComponent:@"Info.plist"]];
            NSString *pluginBundleID = pluginInfoPlist[@"CFBundleIdentifier"];
            NSString *pluginExecutable = pluginInfoPlist[@"CFBundleExecutable"];
            if (pluginBundleID.length == 0 || pluginExecutable.length == 0) {
                continue;
            }
            NSString *pluginExecutablePath = [pluginPath stringByAppendingPathComponent:pluginExecutable];

            NSDictionary *pluginEntitlements = vp_dump_entitlements_from_binary_at_path(pluginExecutablePath);
            NSString *pluginDataContainerID = pluginBundleID;
            BOOL pluginContainerized =
                vp_construct_containerization_for_entitlements(pluginEntitlements ?: @{}, &pluginDataContainerID);

            Class pluginContainerClass = NSClassFromString(@"MCMPluginKitPluginDataContainer");
            MCMContainer *pluginContainer = [pluginContainerClass
                containerWithIdentifier:pluginDataContainerID
                createIfNecessary:YES
                existed:nil
                error:nil];
            NSString *pluginContainerPath = pluginContainer.url.path;

            NSMutableDictionary *pluginDict = [NSMutableDictionary dictionary];
            if (pluginEntitlements) {
                pluginDict[@"Entitlements"] = pluginEntitlements;
            }
            pluginDict[@"ApplicationType"] = @"PluginKitPlugin";
            pluginDict[@"CFBundleIdentifier"] = pluginBundleID;
            pluginDict[@"CodeInfoIdentifier"] = pluginBundleID;
            pluginDict[@"CompatibilityState"] = @0;
            pluginDict[@"IsContainerized"] = @(pluginContainerized);
            if (pluginContainerPath.length > 0) {
                pluginDict[@"Container"] = pluginContainerPath;
                pluginDict[@"EnvironmentVariables"] =
                    vp_construct_environment_variables_for_container_path(pluginContainerPath, pluginContainerized);
            }
            pluginDict[@"Path"] = pluginPath;
            pluginDict[@"PluginOwnerBundleID"] = appBundleID;
            pluginDict[@"SignerOrganization"] = @"Apple Inc.";
            pluginDict[@"SignatureVersion"] = @132352;
            pluginDict[@"SignerIdentity"] = @"Apple iPhone OS Application Signing";

            NSString *pluginTeamIdentifier = vp_construct_team_identifier_for_entitlements(pluginEntitlements ?: @{});
            if (pluginTeamIdentifier.length > 0) {
                pluginDict[@"TeamIdentifier"] = pluginTeamIdentifier;
            }

            NSDictionary *pluginAppGroupContainers =
                vp_construct_groups_containers_for_entitlements(pluginEntitlements, NO);
            NSDictionary *pluginSystemGroupContainers =
                vp_construct_groups_containers_for_entitlements(pluginEntitlements, YES);
            NSMutableDictionary *pluginGroupContainers = [NSMutableDictionary dictionary];
            [pluginGroupContainers addEntriesFromDictionary:pluginAppGroupContainers];
            [pluginGroupContainers addEntriesFromDictionary:pluginSystemGroupContainers];
            if (pluginGroupContainers.count > 0) {
                if (pluginAppGroupContainers.count > 0) {
                    pluginDict[@"HasAppGroupContainers"] = @YES;
                }
                if (pluginSystemGroupContainers.count > 0) {
                    pluginDict[@"HasSystemGroupContainers"] = @YES;
                }
                pluginDict[@"GroupContainers"] = pluginGroupContainers.copy;
            }

            bundlePlugins[pluginBundleID] = pluginDict;
        }
        dictToRegister[@"_LSBundlePlugins"] = bundlePlugins;

        if (![workspace registerApplicationDictionary:dictToRegister]) {
            return NO;
        }
        return YES;
    }

    NSURL *url = [NSURL fileURLWithPath:path];
    return [workspace unregisterApplication:url];
}

static BOOL vp_container_has_known_marker(NSString *containerPath) {
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *marker in @[VPManagedMarker, @"_TrollStoreLite", @"_TrollStore"]) {
        if ([fm fileExistsAtPath:[containerPath stringByAppendingPathComponent:marker]]) {
            return YES;
        }
    }
    return NO;
}

static BOOL vp_mark_container_as_managed(NSString *containerPath) {
    NSString *markerPath = [containerPath stringByAppendingPathComponent:VPManagedMarker];
    if ([[NSFileManager defaultManager] fileExistsAtPath:markerPath]) {
        return YES;
    }
    return [@"" writeToFile:markerPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

static int vp_install_app_from_package(
    NSString *appPackagePath,
    BOOL forceSystem,
    NSString *certPath,
    NSString *ldidPath,
    NSString **detailOutput
) {
    NSString *appPayloadPath = [appPackagePath stringByAppendingPathComponent:@"Payload"];
    NSString *appBundleToInstallPath = vp_find_app_path_in_bundle_path(appPayloadPath);
    if (appBundleToInstallPath.length == 0) {
        if (detailOutput) *detailOutput = @"IPA does not contain an .app payload";
        return 167;
    }

    NSString *appId = vp_app_id_for_app_path(appBundleToInstallPath);
    if (appId.length == 0) {
        if (detailOutput) *detailOutput = @"missing CFBundleIdentifier";
        return 176;
    }

    if ([vp_immutable_app_bundle_identifiers() containsObject:appId.lowercaseString]) {
        if (detailOutput) *detailOutput = @"cannot overwrite immutable system app";
        return 179;
    }

    NSString *signOutput = @"";
    int signRet = vp_sign_app(appBundleToInstallPath, certPath, ldidPath, &signOutput);
    if (signRet != 0) {
        if (detailOutput) *detailOutput = signOutput;
        return signRet;
    }

    Class appContainerClass = NSClassFromString(@"MCMAppContainer");
    if (!appContainerClass) {
        if (detailOutput) *detailOutput = @"MCMAppContainer unavailable";
        return 170;
    }

    MCMContainer *appContainer = [appContainerClass containerWithIdentifier:appId createIfNecessary:NO existed:nil error:nil];
    if (appContainer) {
        NSURL *bundleContainerURL = appContainer.url;
        NSURL *appBundleURL = vp_find_app_url_in_bundle_url(bundleContainerURL);
        if (appBundleURL.path.length > 0 && !vp_container_has_known_marker(bundleContainerURL.path)) {
            if (detailOutput) *detailOutput = @"a non-managed app with the same bundle identifier is already installed";
            return 171;
        }
        if (appBundleURL.path.length > 0) {
            // Kill every instance before pulling the bundle/LaunchServices record
            // out from under it. Deleting or unregistering a live app orphans the
            // process: FrontBoard loses the pid<->bundle binding, so afterwards
            // neither pidForApplication: nor the app switcher can target it, and
            // it survives until the guest reboots. vp_terminate_app already sweeps
            // by container UUID; pass the exact MCM container path too in case the
            // LS record can't be resolved here.
            vp_terminate_app(appId);
            vp_sigkill_processes_under_path(bundleContainerURL.path);
            vp_register_path(appBundleURL.path, YES, NO);
            [[NSFileManager defaultManager] removeItemAtURL:appBundleURL error:nil];
        }
    } else {
        NSError *mcmError = nil;
        appContainer = [appContainerClass containerWithIdentifier:appId createIfNecessary:YES existed:nil error:&mcmError];
        if (!appContainer || mcmError) {
            if (detailOutput) *detailOutput = mcmError.localizedDescription ?: @"failed to create app container";
            return 170;
        }
    }

    NSString *newAppBundlePath = [appContainer.url.path stringByAppendingPathComponent:appBundleToInstallPath.lastPathComponent];
    NSError *copyError = nil;
    if (![[NSFileManager defaultManager] copyItemAtPath:appBundleToInstallPath toPath:newAppBundlePath error:&copyError]) {
        if (detailOutput) *detailOutput = copyError.localizedDescription ?: @"failed to copy app bundle";
        return 178;
    }

    if (!vp_mark_container_as_managed(appContainer.url.path)) {
        if (detailOutput) *detailOutput = @"installed app but failed to write management marker";
        return 177;
    }

    NSURL *updatedAppURL = vp_find_app_url_in_bundle_url(appContainer.url);
    if (updatedAppURL.path.length == 0) {
        if (detailOutput) *detailOutput = @"installed app but failed to resolve final app path";
        return 178;
    }

    vp_fix_permissions_of_app_bundle(updatedAppURL.path);
    if (!vp_register_path(updatedAppURL.path, NO, forceSystem)) {
        if (detailOutput) *detailOutput = @"install copied files but LaunchServices registration failed";
        return 181;
    }

    if (detailOutput) {
        *detailOutput = [NSString stringWithFormat:@"%@ (%@)", updatedAppURL.lastPathComponent, appId];
    }
    return 0;
}

static int vp_extract_package_to_directory(
    NSString *fileToExtract,
    NSString *extractionPath,
    NSString **detailOutput
) {
    NSString *archiveError = nil;
    int ret = vp_extract_archive(fileToExtract, extractionPath, &archiveError);
    if (ret != 0) {
        if (detailOutput) *detailOutput = archiveError ?: @"libarchive extraction failed";
        return 168;
    }
    return 0;
}

BOOL vp_custom_installer_available(void) {
    vp_load_private_frameworks();
    return NSClassFromString(@"MCMAppContainer") != Nil
        && NSClassFromString(@"LSApplicationWorkspace") != Nil;
}

static BOOL vp_is_safe_container_path(NSString *path, NSString *component) {
    if (path.length == 0) return NO;
    NSString *standardized = path.stringByResolvingSymlinksInPath.stringByStandardizingPath;
    if (![standardized containsString:component]) return NO;
    return standardized.lastPathComponent.length >= 16;
}

static BOOL vp_remove_item_if_present(NSString *path, NSString **detailOutput) {
    if (path.length == 0 || ![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        return YES;
    }
    NSError *error = nil;
    if ([[NSFileManager defaultManager] removeItemAtPath:path error:&error]) {
        return YES;
    }
    if (detailOutput) {
        *detailOutput = error.localizedDescription ?: [NSString stringWithFormat:@"failed to remove %@", path];
    }
    return NO;
}

static BOOL vp_launchservices_has_bundle_id(NSString *bundleID) {
    if (bundleID.length == 0) return NO;

    LSApplicationWorkspace *workspace = [LSApplicationWorkspace defaultWorkspace];
    if ([workspace respondsToSelector:@selector(allInstalledApplications)]) {
        for (LSApplicationProxy *proxy in [workspace allInstalledApplications]) {
            if ([proxy.bundleIdentifier isEqualToString:bundleID]) {
                NSString *bundlePath = proxy.bundleURL.path;
                return bundlePath.length > 0 && [[NSFileManager defaultManager] fileExistsAtPath:bundlePath];
            }
        }
        return NO;
    }

    LSApplicationProxy *app = [LSApplicationProxy applicationProxyForIdentifier:bundleID];
    NSString *bundlePath = app.bundleURL.path;
    return bundlePath.length > 0 && [[NSFileManager defaultManager] fileExistsAtPath:bundlePath];
}

static BOOL vp_wait_for_launchservices_removal(NSString *bundleID) {
    for (int i = 0; i < 30; i++) {
        if (!vp_launchservices_has_bundle_id(bundleID)) {
            return YES;
        }
        usleep(100 * 1000);
    }
    return !vp_launchservices_has_bundle_id(bundleID);
}

static BOOL vp_sqlite_exec_bundle_statement(sqlite3 *db, const char *sql, NSString *bundleID, NSString **detailOutput) {
    sqlite3_stmt *stmt = NULL;
    int rc = sqlite3_prepare_v2(db, sql, -1, &stmt, NULL);
    if (rc != SQLITE_OK) {
        if (detailOutput) *detailOutput = [NSString stringWithUTF8String:sqlite3_errmsg(db)];
        return NO;
    }

    sqlite3_bind_text(stmt, 1, bundleID.UTF8String, -1, SQLITE_TRANSIENT);
    rc = sqlite3_step(stmt);
    sqlite3_finalize(stmt);
    if (rc != SQLITE_DONE) {
        if (detailOutput) *detailOutput = [NSString stringWithUTF8String:sqlite3_errmsg(db)];
        return NO;
    }
    return YES;
}

static BOOL vp_sqlite_exec_literal(sqlite3 *db, const char *sql, NSString **detailOutput) {
    char *error = NULL;
    int rc = sqlite3_exec(db, sql, NULL, NULL, &error);
    if (rc != SQLITE_OK) {
        if (detailOutput) {
            *detailOutput = error ? [NSString stringWithUTF8String:error] : [NSString stringWithUTF8String:sqlite3_errmsg(db)];
        }
        if (error) sqlite3_free(error);
        return NO;
    }
    return YES;
}

static BOOL vp_sqlite_exec_bundle_transaction(NSString *dbPath, NSArray<NSString *> *statements, NSString *bundleID, NSString **detailOutput) {
    if (![[NSFileManager defaultManager] fileExistsAtPath:dbPath]) {
        return YES;
    }

    sqlite3 *db = NULL;
    int rc = sqlite3_open_v2(dbPath.fileSystemRepresentation, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, NULL);
    if (rc != SQLITE_OK) {
        if (detailOutput) {
            const char *msg = db ? sqlite3_errmsg(db) : "sqlite open failed";
            *detailOutput = [NSString stringWithFormat:@"%@: %s", dbPath.lastPathComponent, msg];
        }
        if (db) sqlite3_close(db);
        return NO;
    }

    sqlite3_busy_timeout(db, 1000);
    BOOL ok = vp_sqlite_exec_literal(db, "BEGIN IMMEDIATE", detailOutput);
    for (NSString *statement in statements) {
        if (!ok) break;
        ok = vp_sqlite_exec_bundle_statement(db, statement.UTF8String, bundleID, detailOutput);
    }
    ok = ok
        ? vp_sqlite_exec_literal(db, "COMMIT", detailOutput)
        : (vp_sqlite_exec_literal(db, "ROLLBACK", NULL), NO);
    sqlite3_wal_checkpoint_v2(db, NULL, SQLITE_CHECKPOINT_PASSIVE, NULL, NULL);
    sqlite3_close(db);

    if (!ok && detailOutput && (*detailOutput).length > 0) {
        *detailOutput = [NSString stringWithFormat:@"%@: %@", dbPath.lastPathComponent, *detailOutput];
    }
    return ok;
}

static BOOL vp_remove_frontboard_state(NSString *bundleID, NSString **detailOutput) {
    return vp_sqlite_exec_bundle_transaction(
        @"/private/var/mobile/Library/FrontBoard/applicationState.db",
        @[
            @"DELETE FROM kvs WHERE application_identifier IN (SELECT id FROM application_identifier_tab WHERE application_identifier = ?)",
            @"DELETE FROM application_identifier_tab WHERE application_identifier = ?",
        ],
        bundleID,
        detailOutput
    );
}

static BOOL vp_destroy_mobile_containers(NSString *bundleID, NSString **detailOutput) {
    Class managerClass = NSClassFromString(@"MCMContainerManager");
    if (!managerClass) {
        if (detailOutput) *detailOutput = @"MCMContainerManager unavailable";
        return NO;
    }

    MCMContainerManager *manager = [managerClass defaultManager];
    if (!manager) {
        if (detailOutput) *detailOutput = @"MCMContainerManager defaultManager unavailable";
        return NO;
    }

    NSMutableArray *containers = [NSMutableArray array];
    for (NSNumber *contentClass in @[@2, @1]) {
        NSError *error = nil;
        id container = [manager
            containerWithContentClass:contentClass.integerValue
                           identifier:bundleID
                                error:&error];
        if (container) {
            [containers addObject:container];
        } else if (error) {
            NSLog(@"vphoned: MCM lookup failed for %@ class %@: %@", bundleID, contentClass, error);
        }
    }

    if (containers.count == 0) {
        return YES;
    }

    @try {
        [manager deleteContainers:containers withCompletion:nil];
    } @catch (NSException *exception) {
        if (detailOutput) {
            *detailOutput = [NSString stringWithFormat:@"MCM deleteContainers threw: %@", exception];
        }
        return NO;
    }
    return YES;
}

static void vp_sync_launchservices(void) {
    LSApplicationWorkspace *workspace = [LSApplicationWorkspace defaultWorkspace];
    SEL syncSelector = sel_registerName("_LSPrivateSyncWithMobileInstallation");
    if ([workspace respondsToSelector:syncSelector]) {
        ((void (*)(id, SEL))objc_msgSend)(workspace, syncSelector);
    }
}

static BOOL vp_invoke_bool_unregistration(SEL selector, NSString *bundleID, BOOL hasPrecondition, NSInteger operation) {
    LSApplicationWorkspace *workspace = [LSApplicationWorkspace defaultWorkspace];
    if (![workspace respondsToSelector:selector]) return NO;

    NSError *error = nil;
    NSUUID *operationUUID = [NSUUID UUID];
    id saveObserver = nil;
    BOOL result = NO;
    @try {
        if (hasPrecondition) {
            typedef BOOL (*UnregisterWithPreconditionFn)(id, SEL, id, id, unsigned int, id, id, id, NSError **);
            result = ((UnregisterWithPreconditionFn)objc_msgSend)(
                workspace,
                selector,
                bundleID,
                operationUUID,
                (unsigned int)operation,
                nil,
                nil,
                saveObserver,
                &error
            );
        } else {
            typedef BOOL (*UnregisterFn)(id, SEL, id, id, unsigned int, id, id, NSError **);
            result = ((UnregisterFn)objc_msgSend)(
                workspace,
                selector,
                bundleID,
                operationUUID,
                (unsigned int)operation,
                nil,
                saveObserver,
                &error
            );
        }
    } @catch (NSException *exception) {
        NSLog(@"vphoned: %@ threw for %@: %@", NSStringFromSelector(selector), bundleID, exception);
        return NO;
    }
    if (error) {
        NSLog(@"vphoned: %@ error for %@: %@", NSStringFromSelector(selector), bundleID, error);
    }
    return result || !vp_launchservices_has_bundle_id(bundleID);
}

static BOOL vp_helper_unregister_launchservices(NSString *bundleID, NSString *appBundlePath) {
    vp_load_private_frameworks();

    SEL unregisterWithPrecondition = sel_registerName(
        "unregisterContainerizedApplicationWithBundleIdentifier:operationUUID:unregistrationOperation:precondition:requestContext:saveObserver:unregistrationError:"
    );
    SEL unregisterWithoutPrecondition = sel_registerName(
        "unregisterContainerizedApplicationWithBundleIdentifier:operationUUID:unregistrationOperation:requestContext:saveObserver:unregistrationError:"
    );

    for (NSInteger operation = 0; operation <= 1; operation++) {
        if (vp_invoke_bool_unregistration(unregisterWithPrecondition, bundleID, YES, operation)) return YES;
        if (vp_invoke_bool_unregistration(unregisterWithoutPrecondition, bundleID, NO, operation)) return YES;
    }

    if (appBundlePath.length > 0 && [[NSFileManager defaultManager] fileExistsAtPath:appBundlePath]) {
        if (vp_register_path(appBundlePath, YES, NO)) return YES;
    }
    return !vp_launchservices_has_bundle_id(bundleID);
}

int vp_uninstall_helper_main(int argc, char *argv[]) {
    @autoreleasepool {
        if (argc < 3) return 64;
        NSString *bundleID = [NSString stringWithUTF8String:argv[2] ?: ""];
        NSString *appBundlePath = argc >= 4 ? [NSString stringWithUTF8String:argv[3] ?: ""] : @"";
        return vp_helper_unregister_launchservices(bundleID, appBundlePath) ? 0 : 2;
    }
}

static int vp_run_launchservices_unregistration_helper(NSString *bundleID, NSString *appBundlePath, NSString **detailOutput) {
    NSString *executable = [NSProcessInfo processInfo].arguments.firstObject;
    if (executable.length == 0 || ![[NSFileManager defaultManager] fileExistsAtPath:executable]) {
        executable = @"/usr/bin/vphoned";
    }

    const char *path = executable.fileSystemRepresentation;
    char *const argv[] = {
        (char *)path,
        "--vphone-unregister-app",
        (char *)bundleID.fileSystemRepresentation,
        (char *)(appBundlePath ?: @"").fileSystemRepresentation,
        NULL
    };

    pid_t pid = 0;
    int spawnError = posix_spawn(&pid, path, NULL, NULL, argv, NULL);
    if (spawnError != 0) {
        if (detailOutput) *detailOutput = [NSString stringWithFormat:@"failed to spawn LaunchServices unregister helper: %s", strerror(spawnError)];
        return 191;
    }

    int status = 0;
    for (int i = 0; i < 40; i++) {
        pid_t waited = waitpid(pid, &status, WNOHANG);
        if (waited == pid) {
            if (WIFEXITED(status) && WEXITSTATUS(status) == 0) {
                return 0;
            }
            if (detailOutput) {
                *detailOutput = [NSString stringWithFormat:@"LaunchServices unregister helper failed (status=%d)", status];
            }
            return 181;
        }
        if (waited < 0) {
            if (detailOutput) *detailOutput = [NSString stringWithFormat:@"LaunchServices unregister helper wait failed: %s", strerror(errno)];
            return 191;
        }
        usleep(100 * 1000);
    }

    kill(pid, SIGKILL);
    waitpid(pid, &status, 0);
    if (detailOutput) *detailOutput = @"LaunchServices unregister helper timed out";
    return 181;
}

static int vp_uninstall_app_by_bundle_id(NSString *bundleID, NSString **detailOutput) {
    vp_load_private_frameworks();

    if (bundleID.length == 0) {
        if (detailOutput) *detailOutput = @"missing bundle_id";
        return 190;
    }
    if (!vp_custom_installer_available()) {
        if (detailOutput) *detailOutput = @"Built-in app uninstaller prerequisites are missing";
        return 170;
    }
    if ([vp_immutable_app_bundle_identifiers() containsObject:bundleID.lowercaseString]) {
        if (detailOutput) *detailOutput = @"cannot uninstall immutable system app";
        return 179;
    }

    LSApplicationProxy *app = [LSApplicationProxy applicationProxyForIdentifier:bundleID];
    NSString *appBundlePath = app.bundleURL.path;
    BOOL appBundleExists = appBundlePath.length > 0 && [[NSFileManager defaultManager] fileExistsAtPath:appBundlePath];
    BOOL launchServicesHadRecord = appBundleExists || vp_launchservices_has_bundle_id(bundleID);
    if (!launchServicesHadRecord && !appBundleExists) {
        if (detailOutput) *detailOutput = [NSString stringWithFormat:@"app not installed: %@", bundleID];
        return 404;
    }

    NSString *bundleContainerPath = appBundlePath.stringByDeletingLastPathComponent;
    if (appBundleExists && !vp_is_safe_container_path(bundleContainerPath, @"/Bundle/Application/")) {
        if (detailOutput) *detailOutput = [NSString stringWithFormat:@"refusing to remove unsafe bundle container: %@", bundleContainerPath ?: @""];
        return 182;
    }

    NSString *dataContainerPath = app.dataContainerURL.path;
    BOOL removeDataContainer = vp_is_safe_container_path(dataContainerPath, @"/Containers/Data/Application/");

    vp_terminate_app(bundleID);
    vp_sigkill_processes_under_path(bundleContainerPath);

    if (vp_launchservices_has_bundle_id(bundleID)) {
        NSString *unregisterDetail = nil;
        int unregisterRet = vp_run_launchservices_unregistration_helper(bundleID, appBundlePath, &unregisterDetail);
        if (unregisterRet != 0 && unregisterDetail.length > 0) {
            NSLog(@"vphoned: best-effort LaunchServices unregister failed for %@: %@", bundleID, unregisterDetail);
        }
    }

    if (!vp_destroy_mobile_containers(bundleID, detailOutput)) {
        return 185;
    }
    if (!vp_remove_frontboard_state(bundleID, detailOutput)) {
        return 186;
    }
    vp_sync_launchservices();

    if (appBundleExists && !vp_remove_item_if_present(bundleContainerPath, detailOutput)) {
        return 183;
    }
    if (removeDataContainer && !vp_remove_item_if_present(dataContainerPath, detailOutput)) {
        return 184;
    }
    vp_sync_launchservices();
    if (!vp_wait_for_launchservices_removal(bundleID)) {
        if (detailOutput) {
            *detailOutput = [NSString stringWithFormat:@"LaunchServices record remains for %@", bundleID];
        }
        return 181;
    }

    if (detailOutput) {
        *detailOutput = removeDataContainer
            ? [NSString stringWithFormat:@"Uninstalled %@ and removed data container", bundleID]
            : [NSString stringWithFormat:@"Uninstalled %@", bundleID];
    }
    return 0;
}

NSDictionary *vp_handle_custom_install(NSDictionary *msg) {
    vp_load_private_frameworks();
    id reqId = msg[@"id"];
    NSString *ipaPath = msg[@"path"];
    NSString *registration = msg[@"registration"];
    NSString *certPath = msg[@"cert_path"];
    NSString *ldidPath = vp_find_ldid_path();
    BOOL forceSystem = [registration isEqualToString:@"System"];

    if (ipaPath.length == 0) {
        NSMutableDictionary *response = vp_make_response(@"err", reqId);
        response[@"msg"] = @"missing ipa path";
        return response;
    }
    if (![[NSFileManager defaultManager] fileExistsAtPath:ipaPath]) {
        NSMutableDictionary *response = vp_make_response(@"err", reqId);
        response[@"msg"] = [NSString stringWithFormat:@"IPA not found: %@", ipaPath];
        return response;
    }
    if (!vp_custom_installer_available()) {
        NSMutableDictionary *response = vp_make_response(@"err", reqId);
        NSMutableArray<NSString *> *missing = [NSMutableArray array];
        if (NSClassFromString(@"MCMAppContainer") == Nil) [missing addObject:@"MCMAppContainer"];
        if (NSClassFromString(@"LSApplicationWorkspace") == Nil) [missing addObject:@"LSApplicationWorkspace"];
        NSString *detail = missing.count > 0 ? [missing componentsJoinedByString:@", "] : @"unknown";
        response[@"msg"] = [NSString stringWithFormat:@"Built-in IPA installer prerequisites are missing: %@", detail];
        return response;
    }
    if (ldidPath.length == 0) {
        NSMutableDictionary *response = vp_make_response(@"err", reqId);
        response[@"msg"] = @"Built-in IPA installer could not find a guest-side iOS ldid.";
        return response;
    }
    if (certPath.length > 0 && ![[NSFileManager defaultManager] fileExistsAtPath:certPath]) {
        certPath = nil;
    }

    NSString *tmpPackagePath = [[NSTemporaryDirectory() stringByResolvingSymlinksInPath] stringByAppendingPathComponent:[NSUUID UUID].UUIDString];
    if (![[NSFileManager defaultManager] createDirectoryAtPath:tmpPackagePath withIntermediateDirectories:NO attributes:nil error:nil]) {
        NSMutableDictionary *response = vp_make_response(@"err", reqId);
        response[@"msg"] = @"failed to create temporary extraction directory";
        return response;
    }

    NSString *detail = @"";
    int extractRet = vp_extract_package_to_directory(ipaPath, tmpPackagePath, &detail);
    int installRet = 0;
    if (extractRet == 0) {
        installRet = vp_install_app_from_package(tmpPackagePath, forceSystem, certPath, ldidPath, &detail);
    }

    [[NSFileManager defaultManager] removeItemAtPath:tmpPackagePath error:nil];
    [[NSFileManager defaultManager] removeItemAtPath:ipaPath error:nil];
    if (certPath.length > 0) {
        [[NSFileManager defaultManager] removeItemAtPath:certPath error:nil];
    }
    if (extractRet != 0 || installRet != 0) {
        NSMutableDictionary *response = vp_make_response(@"err", reqId);
        int retCode = extractRet != 0 ? extractRet : installRet;
        NSString *trimmed = vp_trimmed_output(detail ?: @"");
        response[@"msg"] = trimmed.length > 0
            ? [NSString stringWithFormat:@"built-in installer failed (%d)\n%@", retCode, trimmed]
            : [NSString stringWithFormat:@"built-in installer failed (%d)", retCode];
        return response;
    }

    NSMutableDictionary *response = vp_make_response(@"ok", reqId);
    response[@"msg"] = forceSystem
        ? [NSString stringWithFormat:@"Installed via built-in installer as System: %@", detail]
        : [NSString stringWithFormat:@"Installed via built-in installer as User: %@", detail];
    return response;
}

NSDictionary *vp_handle_custom_uninstall(NSDictionary *msg) {
    id reqId = msg[@"id"];
    NSString *bundleID = msg[@"bundle_id"];

    NSString *detail = @"";
    int ret = vp_uninstall_app_by_bundle_id(bundleID, &detail);
    if (ret != 0) {
        NSMutableDictionary *response = vp_make_response(@"err", reqId);
        NSString *trimmed = vp_trimmed_output(detail ?: @"");
        response[@"msg"] = trimmed.length > 0
            ? [NSString stringWithFormat:@"built-in uninstaller failed (%d)\n%@", ret, trimmed]
            : [NSString stringWithFormat:@"built-in uninstaller failed (%d)", ret];
        return response;
    }

    NSMutableDictionary *response = vp_make_response(@"ok", reqId);
    response[@"msg"] = detail.length > 0 ? detail : [NSString stringWithFormat:@"Uninstalled %@", bundleID];
    return response;
}
