/* libnx/newlib surface for platform/switch/c.zig (translated by the build). */
#undef _GNU_SOURCE
#undef _DEFAULT_SOURCE
#define _POSIX_C_SOURCE 200809L
#define wint_t __WINT_TYPE__
#define __SWITCH__ 1
#define __thread

#include <errno.h>
#include <fcntl.h>
#include <dirent.h>
#include <sys/iosupport.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <netdb.h>
#include <poll.h>
#include <unistd.h>
#include <malloc.h>
#include <stdio.h>

#include <switch/types.h>
