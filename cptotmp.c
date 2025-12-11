#include <sys/stat.h>
#include <assert.h>
#include <string.h>
#include <stdlib.h>
#include <stdio.h>
#include <time.h>
#include <mpi.h>

#define CHECK_ERROR(cond, errstr)               \
    do {                                        \
        if (cond) {                             \
            perror(errstr);                     \
            MPI_Abort(MPI_COMM_WORLD, 1);       \
        }                                       \
    } while (0)

#define GB (1L << 30)
/* tar reads in multiples of records (10240 bytes) */
#define ROUND_UP_RECORD(a) ( ((a) + 10239L) / 10240L * 10240L )

static double get_elapsed(struct timespec t1, struct timespec t2);
const char *human_size(MPI_Count bytes);

int main(int argc, char **argv) {
    struct timespec start, end;
    char command[2048];
    int rank;

    clock_gettime(CLOCK_MONOTONIC, &start);

    MPI_Init(NULL, NULL);
    MPI_Comm_rank(MPI_COMM_WORLD, &rank);

    MPI_Count total_size;
    FILE *archive;
    if (rank == 0) {
        int last_idx = strlen(argv[1]) - 1;
        if (argv[1][last_idx] == '/') {
            argv[1][last_idx] = '\0';
        }

        char *dup = strdup(argv[1]);
        char *slash = strrchr(dup, '/');
        char *left;
        char *right;
        if (slash != NULL) {
            *slash = '\0';
            left  = dup;
            right = slash + 1;
        } else {
            left = ".";
            right = dup;
        }

        /* get the size of the archive */
        char null_write[4096] = {0};
        snprintf(command, sizeof(command),
                 "tar --totals -C %s -cf /dev/null %s 2>&1 | awk '{print $4}'",
                 left, right);
        archive = popen(command, "r");
        CHECK_ERROR(!archive, "popen");
        fread(null_write, 1, 4096, archive);
        pclose(archive);
        total_size = ROUND_UP_RECORD(atol(null_write));

        /* open archive for reading */
        snprintf(command, sizeof(command), "tar -C %s -cf - %s", left, right);
        archive = popen(command, "r");
        CHECK_ERROR(!archive, "popen");
        free(dup);

        MPI_Bcast(&total_size, 1, MPI_COUNT, 0, MPI_COMM_WORLD);
    } else {
        MPI_Bcast(&total_size, 1, MPI_COUNT, 0, MPI_COMM_WORLD);
    }

    /* open destination for writing */
    int ret = system("mkdir -p /tmp/hf_home/hub");
    CHECK_ERROR(ret, "mkdir");
    snprintf(command, sizeof(command), "tar -xf - -C /tmp/hf_home/hub");
    FILE *dest = popen(command, "w");
    CHECK_ERROR(!dest, "popen");

    /* read, bcast, write archive in chunks */
    int chunks = (total_size + GB - 1) / GB;
    void *buf = malloc(GB);
    assert(buf);
    for (int i = 0; i < chunks; i++) {
        int chunk_size = i == chunks - 1 ? total_size % GB : GB;
        size_t n;

        if (rank == 0) {
            n = fread(buf, 1, chunk_size, archive);
            assert(n == chunk_size);
        }

        MPI_Bcast(buf, chunk_size, MPI_BYTE, 0, MPI_COMM_WORLD);

        n = fwrite(buf, 1, chunk_size, dest);
        assert(n == chunk_size);
    }
    pclose(dest);
    free(buf);

    clock_gettime(CLOCK_MONOTONIC, &end);
    double elapsed = get_elapsed(start, end);
    double max;
    MPI_Reduce(&elapsed, &max, 1, MPI_DOUBLE, MPI_MAX, 0, MPI_COMM_WORLD);
    if (rank == 0) {
        const char *hsize = human_size(total_size);
        printf("cptotmp: %.6f seconds to stage %s from %s\n", max, hsize, argv[1]);
    }

    MPI_Finalize();

    return 0;
}

static double get_elapsed(struct timespec t1, struct timespec t2)
{
    time_t sec = t2.tv_sec - t1.tv_sec;
    long nsec = t2.tv_nsec - t1.tv_nsec;

    if (nsec < 0) {
        sec--;
        nsec += 1000000000L;
    }

    return sec + nsec * 1e-9;
}


const char *human_size(MPI_Count bytes)
{
    static char buf[32];
    const char *units[] = { "B", "KiB", "MiB", "GiB", "TiB", "PiB" };
    int i = 0;

    double sz = (double)bytes;

    while (sz >= 1024.0 && i < (int)(sizeof(units)/sizeof(units[0])) - 1) {
        sz /= 1024.0;
        i++;
    }

    snprintf(buf, sizeof(buf), "%.2f %s", sz, units[i]);
    return buf;
}
