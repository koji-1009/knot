// Stub headers consumed by ffigen/linux.dart.

#include <unistd.h>
#include <fcntl.h>
#include <sys/stat.h>

// Linux glibc exposes errno via `__errno_location()`. Declare it
// explicitly so ffigen doesn't have to chase the headers' macros.
extern int *__errno_location(void);
