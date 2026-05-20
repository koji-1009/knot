// Stub headers consumed by ffigen/macos.dart.
//
// We don't want to pull in every transitively included macOS SDK header;
// ffigen's `Headers.include` filter handles that. This entry point just
// makes sure the symbols we bind to are visible.

#include <unistd.h>
#include <sys/clonefile.h>
#include <sys/stat.h>

// `errno` on macOS is a macro that expands to `(*__error())`. ffigen
// can't bind to a macro, so we declare the underlying function symbol
// explicitly here.
extern int *__error(void);
