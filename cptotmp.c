#include <sys/stat.h>
#include <assert.h>
#include <string.h>
#include <stdlib.h>
#include <stdio.h>
#include <time.h>
#include <mpi.h>

#define GB (1024L*1024L*1024L)
#define ROUND_UP_RECORD(a) ( ((a) + 10239L) / 10240L * 10240L )

static double get_elapsed(struct timespec t1, struct timespec t2);

int main(int argc, char **argv) {
    struct timespec start, end;
    char command[2048];
    int rank;

    clock_gettime(CLOCK_MONOTONIC, &start);

    MPI_Init(NULL, NULL);
    MPI_Comm_rank(MPI_COMM_WORLD, &rank);

    MPI_Count total_size;
    void *buf = NULL;
    FILE *archive;
    if (rank == 0) {
        MPI_File src;
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
        if (!archive) {
            perror("popen");
            MPI_Abort(MPI_COMM_WORLD, 1);
        }
        fread(null_write, 1, 4096, archive);
        pclose(archive);
        total_size = ROUND_UP_RECORD(atol(null_write));
        MPI_Bcast(&total_size, 1, MPI_COUNT, 0, MPI_COMM_WORLD);
        buf = malloc(total_size);
        if (!buf) {
            perror("malloc");
            MPI_Abort(MPI_COMM_WORLD, 1);
        }

        /* open for reading */
        snprintf(command, sizeof(command), "tar -C %s -cf - %s", left, right);
        free(dup);
        archive = popen(command, "r");
        if (!archive) {
            perror("popen");
            MPI_Abort(MPI_COMM_WORLD, 1);
        }
    } else {
        MPI_Bcast(&total_size, 1, MPI_COUNT, 0, MPI_COMM_WORLD);
        buf = malloc(total_size);
    }

    int num_bcasts = (total_size / GB) + (total_size % GB ? 1 : 0);
    MPI_Request reqs[64];
    for (int i = 0; i < 64; i++) {
        reqs[i] = MPI_REQUEST_NULL;
    }

    if (rank == 0) {
        /* read and send 1GB at a time, batches of 64 */
        size_t n, total_read = 0;

        for (int i = 0; i < num_bcasts; i++) {
            n = fread(buf + (i * GB), 1, GB, archive);
            total_read += n;
            MPI_Ibcast(buf + (i * GB), n, MPI_BYTE, 0, MPI_COMM_WORLD, &reqs[i & 63]);
            if (i && i % 64 == 0) {
                MPI_Waitall(64, reqs, MPI_STATUSES_IGNORE);
            }
        }
        MPI_Waitall(64, reqs, MPI_STATUSES_IGNORE);
        assert(total_read == total_size);

        if (pclose(archive) != 0) {
            perror("pclose");
            MPI_Abort(MPI_COMM_WORLD, 1);
        }
    } else {
        for (int i = 0; i < num_bcasts; i++) {
            MPI_Ibcast(buf + (i * GB), GB, MPI_BYTE, 0, MPI_COMM_WORLD, &reqs[i & 63]);
            if (i && i % 64 == 0) {
                MPI_Waitall(64, reqs, MPI_STATUSES_IGNORE);
            }
        }
        MPI_Waitall(64, reqs, MPI_STATUSES_IGNORE);
    }

    if (system("mkdir -p /tmp/hf_home/hub") != 0) {
        printf("failed to create directory in /tmp\n");
        MPI_Abort(MPI_COMM_WORLD, 1);
    }
    snprintf(command, sizeof(command), "tar -xf - -C /tmp/hf_home/hub");
    FILE *dest = popen(command, "w");
    if (!dest) {
        perror("popen");
        MPI_Abort(MPI_COMM_WORLD, 1);
    }

    size_t n = fwrite(buf, 1, total_size, dest);
    assert(n == total_size);
    pclose(dest);
    free(buf);

    clock_gettime(CLOCK_MONOTONIC, &end);
    double elapsed = get_elapsed(start, end);
    double max;
    MPI_Reduce(&elapsed, &max, 1, MPI_DOUBLE, MPI_MAX, 0, MPI_COMM_WORLD);
    if (rank == 0) {
        printf("cptotmp: %.6f seconds to stage %s\n", max, argv[1]);
    }

    MPI_Finalize();

    return 0;
}

/* static functions */
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
