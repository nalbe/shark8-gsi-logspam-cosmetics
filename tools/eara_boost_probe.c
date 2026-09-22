/* Triggers the eara_io INFO logs that the module's lib_eara_io_scndet.so patch
 * silences, so the mute can be tested without launching a game.
 *
 *   aarch64-linux-android21-clang -fPIE -pie -o eara_boost_probe eara_boost_probe.c
 *   adb push eara_boost_probe /data/local/tmp/ && adb shell chmod 755 /data/local/tmp/eara_boost_probe
 *   adb shell 'logcat -c; /data/local/tmp/eara_boost_probe; logcat -d | grep eara_io@'
 *
 * eara_io_boost(level) is the exported entry point of lib_eara_io_scndet.so; it
 * is what the scene detector calls when it decides to boost. Calling it applies
 * the same 500 ms perf_lock_acq the game would, and logs
 * "eara_io@boost: [eara_io_boost] eara_io_boost %d , ta %d" at INFO.
 */

#include <dlfcn.h>
#include <stdio.h>
#include <unistd.h>

typedef int (*boost_fn)(int);
typedef void (*init_fn)(void);

int main(int argc, char **argv)
{
    int rounds = argc > 1 ? atoi(argv[1]) : 3;
    if (rounds <= 0) rounds = 3;

    void *h = dlopen("/vendor/lib64/lib_eara_io_scndet.so", RTLD_NOW);
    if (!h) {
        printf("dlopen failed: %s\n", dlerror());
        return 1;
    }

    init_fn init = (init_fn)dlsym(h, "_Z21eara_io_perf_rsc_initv");
    if (init) {
        printf("eara_io_perf_rsc_init()\n");
        init();
    } else {
        printf("no eara_io_perf_rsc_init symbol\n");
    }

    boost_fn boost = (boost_fn)dlsym(h, "_Z13eara_io_boosti");
    if (!boost) {
        printf("dlsym eara_io_boost failed: %s\n", dlerror());
        return 1;
    }

    for (int i = 1; i <= rounds; i++) {
        int rc = boost(i);
        printf("eara_io_boost(%d) = %d\n", i, rc);
        usleep(600000);
    }

    /* one unboost round hits the other logging path */
    int rc = boost(0);
    printf("eara_io_boost(0) = %d\n", rc);
    return 0;
}
