namespace Timbre.Utils {

    [CCode (cname = "malloc_trim", cheader_filename = "malloc.h")]
    extern static int malloc_trim_ffi (ulong pad);

    [CCode (cname = "mallopt", cheader_filename = "malloc.h")]
    extern static int mallopt_ffi (int param, int value);

    private const int M_ARENA_MAX = -8;

    public static void set_arena_max (int max_arenas) {
        mallopt_ffi (M_ARENA_MAX, max_arenas);
    }

    public static void trim_memory () {
        malloc_trim_ffi (0);
    }
}
