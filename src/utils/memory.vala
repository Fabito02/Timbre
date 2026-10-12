namespace Timbre.Utils {

    [CCode (cname = "malloc_trim", cheader_filename = "malloc.h")]
    extern static int malloc_trim_ffi (ulong pad);

    public static void trim_memory () {
        malloc_trim_ffi (0);
    }
}
