//
//  main.mm
//  xctouch
//
//  Created by André Keller on 31/03/2017.
//  Copyright © 2017 André Keller. All rights reserved.
//

#define VERBOSE 1

#import <Foundation/Foundation.h>

#include <mach-o/ldsyms.h>
#include <mach-o/dyld.h>
#include <mach/mach.h>

#include <dlfcn.h>

#if __LP64__
typedef struct mach_header_64 macho_header;
#else
typedef struct mach_header macho_header;
#endif

#include <vector>
#include <limits>

inline bool unprotect_mem(vm_address_t addr, vm_size_t size)
{
    return vm_protect(mach_task_self_, addr, size, false, VM_PROT_ALL) == KERN_SUCCESS;
}

// https://opensource.apple.com/source/dyld/dyld-519.2.1/src/ImageLoaderMachO.cpp.auto.html
static void collect_rcmds(const macho_header* mh, std::vector<struct rpath_command*>& rcmds, const char* pattern = nullptr)
{
    const uint32_t cmd_count = mh->ncmds;
    const struct load_command* const cmds = (struct load_command*)(((char*)mh) + sizeof(macho_header));
    const struct load_command* cmd = cmds;
    for (uint32_t i = 0; i < cmd_count; ++i) {
        switch (cmd->cmd) {
            case LC_RPATH:
                struct rpath_command* rc = (struct rpath_command*)cmd;
                if (!pattern || strcmp((char*)rc + rc->path.offset, pattern) == 0) {
                    rcmds.push_back(rc);
                }
                break;
        }
        cmd = (const struct load_command*)(((char*)cmd)+cmd->cmdsize);
    }
}

static bool rewrite_rcmd(struct rpath_command* rc, const char* ptr)
{
    if (!unprotect_mem((vm_address_t)&rc->path, sizeof(rc->path))) {
        return false;
    }
    size_t offset = (char*)ptr - (char*)rc;
    if (offset > std::numeric_limits<uint32_t>::max()) {
        return false;
    }
    rc->path.offset = (uint32_t)offset;
    return true;
}

#include <sysexits.h>
#include <iostream>

inline NSString *ToString(NSData *data)
{
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}

static void PrintUsage(void)
{
    std::cout << "Usage: xctouch -p <project_path>" << std::endl;
}

static NSBundle *XcodeBundle(void)
{
    NSBundle *xcodeBundle = nil;

    NSTask *task = [[NSTask alloc] init];
    task.launchPath = @"/usr/bin/xcode-select";
    task.arguments = @[@"-p"];
    task.standardOutput = [NSPipe pipe];

    // try xcode-select active developer directory?
    @try
    {
        [task launch];
        [task waitUntilExit];

        if (task.terminationStatus == 0)
        {
            NSString *output = ToString([[task.standardOutput fileHandleForReading] readDataToEndOfFile]);
            NSString *path = [[output stringByDeletingLastPathComponent] stringByDeletingLastPathComponent];
            xcodeBundle = [NSBundle bundleWithPath:path];
        }
    }
    @catch (NSException *exception)
    {
    }

    // try bundle identifier?
    if (!xcodeBundle)
    {
        xcodeBundle = [NSBundle bundleWithIdentifier:@"com.apple.dt.Xcode"];
    }

    if (!xcodeBundle)
    {
        std::cerr << "Xcode.app not found." << std::endl;
        exit(EX_SOFTWARE);
    }
#ifdef VERBOSE
    NSString *xcodeVersion = [[xcodeBundle infoDictionary] valueForKey:@"CFBundleShortVersionString"];
    NSString *xcodePath = [xcodeBundle bundlePath];
    std::cout << "Xcode.app found at: '" << [xcodePath UTF8String] << "' (" << [xcodeVersion UTF8String] << ")" << std::endl;
#endif

    return xcodeBundle;
}

#include <sys/syslimits.h>

// This function tricks the dylib loader. It rewrites the app's @rpath entries
// by adding Xcode's framework paths at runtime ;)
//
// This allows the dylib loader to load Xcode libraries with all dependencies
// automatically. There is no need to specify libraries individually, which
// is far more robust against Xcode upgrades.
//
// For each @rpath modification you need a preallocated block of memory in
// the mach-o header. You can specifiy such block by a "@placeholder" entry
// in "Build Settings -> Runpath Seach Paths".
static void TrickDylibLoader(NSBundle *xcodeBundle)
{
    // ensure 32 bit offset boundary to the mach-o header (static)
    static char privateFrameworks[PATH_MAX];
    static char sharedFrameworks[PATH_MAX];
    static char builtInPlugIns[PATH_MAX];
    strlcpy(privateFrameworks, [[xcodeBundle privateFrameworksPath] UTF8String], PATH_MAX);
    strlcpy(sharedFrameworks, [[xcodeBundle sharedFrameworksPath] UTF8String], PATH_MAX);
    strlcpy(builtInPlugIns, [[xcodeBundle builtInPlugInsPath] UTF8String], PATH_MAX);

    std::vector<struct rpath_command*> rcmds;
    collect_rcmds(&_mh_execute_header, rcmds, "@placeholder");

    // validate number of @placeholder entries
    if (rcmds.size() != 3)
    {
        exit(EX_SOFTWARE);
    }

    rewrite_rcmd(rcmds[0], privateFrameworks);
    rewrite_rcmd(rcmds[1], sharedFrameworks);
    rewrite_rcmd(rcmds[2], builtInPlugIns);
}

static void LoadXcodeDylibs(void)
{
    static const std::vector<const char*> libs = {
        "IDEFoundation.framework/IDEFoundation"
    };

    for (const char* path : libs)
    {
        if (!dlopen(path, RTLD_LAZY))
        {
            std::cerr << dlerror() << std::endl;
            exit(EX_SOFTWARE);
        }
    }
}

static void InitializeXcodeIDE(void)
{
    BOOL (*IDEInitialize)(int initializationOptions, NSError **error) = (BOOL (*)(int, NSError *__autoreleasing *))dlsym(RTLD_DEFAULT, "IDEInitialize");
    if (!IDEInitialize)
    {
        std::cerr << "IDEInitialize function not found." << std::endl;
        exit(EX_SOFTWARE);
    }

    NSError *error;
    BOOL initialized;
    @try
    {
        initialized = IDEInitialize(1, &error);
    }
    @catch (NSException *exception)
    {
    }

    if (!initialized)
    {
        std::cerr << "IDEInitialize failed." << std::endl;
        exit(EX_SOFTWARE);
    }
#ifdef VERBOSE
    std::cout << "IDEInitialize done." << std::endl;
#endif
}

@protocol PBXContainer <NSObject>

//- (id<PBXGroup>) rootGroup;

//- (id<PBXFileReference>) fileReferenceForPath:(NSString *)path;

@end

@protocol PBXProject <PBXContainer, NSObject>

+ (BOOL) isProjectWrapperExtension:(NSString *)extension;
+ (id<PBXProject>) projectWithFile:(NSString *)projectAbsolutePath;

//- (NSArray<PBXTarget> *) targets;
//- (id<PBXTarget>) targetNamed:(NSString *)targetName;

//- (NSString *) name;

//- (id<XCConfigurationList>) buildConfigurationList;

//- (NSString *) expandedValueForString:(NSString *)string forBuildParameters:(id<IDEBuildParameters>)buildParameters;

- (BOOL) writeToFileSystemProjectFile:(BOOL)projectWrite userFile:(BOOL)userFile checkNeedsRevert:(BOOL)checkNeedsRevert;

@end

int main(int argc, const char* argv[])
{
    @autoreleasepool
    {
        NSUserDefaults *args = [NSUserDefaults standardUserDefaults];
        NSString *projectPath = [args stringForKey:@"p"];

        if (!projectPath)
        {
            PrintUsage();
            exit(EX_USAGE);
        }

        // load and initialize the Xcode IDE
        TrickDylibLoader(XcodeBundle());
        LoadXcodeDylibs();
        InitializeXcodeIDE();

        Class PBXProject = NSClassFromString(@"PBXProject");

        // validate project extension
        if (![PBXProject isProjectWrapperExtension:[projectPath pathExtension]])
        {
            std::cerr << "The project '" << [projectPath UTF8String] << "' does not have a valid extension (*.xcodeproj)." << std::endl;
            exit(EX_DATAERR);
        }

        NSString *absolutePath = projectPath;
        if (![projectPath isAbsolutePath])
        {
            absolutePath = [[[NSFileManager defaultManager] currentDirectoryPath] stringByAppendingPathComponent:projectPath];
        }

        if (![[NSFileManager defaultManager] fileExistsAtPath:absolutePath])
        {
            std::cerr << "The project '" << [projectPath UTF8String] << "' does not exist." << std::endl;
            exit(EX_DATAERR);
        }

        // open project
        id<PBXProject> project = [PBXProject projectWithFile:absolutePath];
        if (!project)
        {
            std::cerr << "The project '" << [projectPath UTF8String] << "' cannot be opened." << std::endl;
            exit(EX_SOFTWARE);
        }
#ifdef VERBOSE
        std::cout << "The project '" << [projectPath UTF8String] << "' was opened." << std::endl;
#endif

        // write project
        BOOL written = [project writeToFileSystemProjectFile:YES userFile:NO checkNeedsRevert:NO];
        if (!written)
        {
            std::cerr << "The project '" << [projectPath UTF8String] << "' cannot be written." << std::endl;
            exit(EX_SOFTWARE);
        };
#ifdef VERBOSE
        std::cout << "The project '" << [projectPath UTF8String] << "' was written." << std::endl;
#endif
    }
    return EX_OK;
}
