//
//  MacAMPProjectM-Bridging-Header.h
//  Swift ↔ ObjC++ bridge for the macOS-only projectM backend.
//
//  Reached by macampMac via SWIFT_OBJC_BRIDGING_HEADER. Any target that compiles
//  the ProjectM folder must set that build setting AND define MACAMP_PROJECTM, or
//  the facade below preprocesses away and the Swift backend fails to resolve it.
//
#if MACAMP_PROJECTM
#import "MacAMPProjectMBridge.h"
#endif
