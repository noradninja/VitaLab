cmake_minimum_required(VERSION 3.16)

if(NOT DEFINED CMAKE_TOOLCHAIN_FILE)
  if(DEFINED ENV{VITASDK})
    set(CMAKE_TOOLCHAIN_FILE "$ENV{VITASDK}/share/vita.toolchain.cmake" CACHE PATH "VitaSDK toolchain")
  else()
    message(FATAL_ERROR "Set VITASDK or pass -DCMAKE_TOOLCHAIN_FILE=<path>/vita.toolchain.cmake")
  endif()
endif()

project(VitaLab VERSION 0.1.0 LANGUAGES C)
include("$ENV{VITASDK}/share/vita.cmake" REQUIRED)

set(VITALAB_PORT 19600 CACHE STRING "VitaLab TCP command port")

execute_process(
  COMMAND git rev-parse --short=12 HEAD
  WORKING_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}"
  OUTPUT_VARIABLE VITALAB_GIT_COMMIT
  OUTPUT_STRIP_TRAILING_WHITESPACE
  ERROR_QUIET
)
if(NOT VITALAB_GIT_COMMIT)
  set(VITALAB_GIT_COMMIT "unknown")
endif()
string(TIMESTAMP VITALAB_BUILD_TIME "%Y%m%dT%H%M%SZ" UTC)
set(VITALAB_BUILD_ID "${VITALAB_GIT_COMMIT}-${VITALAB_BUILD_TIME}")

add_library(vitalab_protocol STATIC common/protocol.c)
target_include_directories(vitalab_protocol PUBLIC "${CMAKE_CURRENT_SOURCE_DIR}/common")
target_compile_options(vitalab_protocol PRIVATE -Wall -Wextra -Werror)
target_compile_definitions(vitalab_protocol PUBLIC
  VITALAB_VERSION="${PROJECT_VERSION}"
  VITALAB_GIT_COMMIT="${VITALAB_GIT_COMMIT}"
  VITALAB_BUILD_ID="${VITALAB_BUILD_ID}"
)

add_executable(vitalab plugin/main.c)
target_compile_options(vitalab PRIVATE
  -Wall
  -Wextra
  -Werror
  -fno-pic
  -fno-PIC
)
target_compile_definitions(vitalab PRIVATE VITALAB_PORT=${VITALAB_PORT})
target_link_libraries(vitalab
  vitalab_protocol
  gcc
  SceLibc_stub_weak
  SceIofilemgr_stub_weak
  SceKernelThreadMgr_stub_weak
  SceLibKernel_stub_weak
  SceNet_stub_weak
)
set_target_properties(vitalab PROPERTIES LINK_FLAGS "-nostdlib -Wl,-q")

vita_create_self(vitalab.suprx vitalab
  UNSAFE
  CONFIG "${CMAKE_CURRENT_SOURCE_DIR}/plugin/vitalab.yml"
)

message(STATUS "VitaLab build identity: ${VITALAB_BUILD_ID}")
