set(CMAKE_BUILD_TYPE RelWithDebInfo CACHE STRING "")
set(BUILD_SHARED_LIBS YES CACHE BOOL "")

set(SwiftCore_ENABLE_BACKTRACING ON CACHE BOOL "")
set(SwiftCore_ENABLE_COMMANDLINE_SUPPORT ON CACHE BOOL "")
set(SwiftCore_ENABLE_CRASH_REPORTER_CLIENT ON CACHE BOOL "")
set(SwiftCore_ENABLE_LIBRARY_EVOLUTION ON CACHE BOOL "")
set(SwiftCore_ENABLE_OBJC_INTEROP ON CACHE BOOL "")
set(SwiftCore_ENABLE_REFLECTION ON CACHE BOOL "")
set(SwiftCore_ENABLE_TYPE_PRINTING ON CACHE BOOL "")
set(SwiftCore_ENABLE_VECTOR_TYPES ON CACHE BOOL "")
set(SwiftCore_ENABLE_RUNTIME_FUNCTION_COUNTERS ON CACHE BOOL "")
set(SwiftCore_ENABLE_BACKDEPLOYMENT_SUPPORT ON CACHE BOOL "")
set(SwiftCore_ENABLE_FILESYSTEM_SUPPORT ON CACHE BOOL "")

set(CMAKE_CXX_FLAGS_MINSIZEREL "-Os -g -DNDEBUG" CACHE STRING "")
set(CMAKE_C_FLAGS_MINSIZEREL "-Os -g -DNDEBUG" CACHE STRING "")
set(CMAKE_Swift_FLAGS_MINSIZEREL "-Osize -g" CACHE STRING "")
