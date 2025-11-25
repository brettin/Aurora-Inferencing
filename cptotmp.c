#include <sys/stat.h>
#include <assert.h>
#include <string.h>
#include <stdlib.h>
#include <stdio.h>
#include <time.h>
#include <mpi.h>

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

static void convert_slash_to_double_dash(const char *input, char *output, size_t out_size) {
    size_t j = 0;
    for (size_t i = 0; input[i] != '\0' && j < out_size - 1; i++) {
        if (input[i] == '/') {
            if (j + 2 >= out_size) break; // prevent buffer overflow
            output[j++] = '-';
            output[j++] = '-';
        } else {
            output[j++] = input[i];
        }
    }
    output[j] = '\0';
}

int main(int argc, char **argv) {
    struct timespec start, end;
    char command[2048];
    int rank;

    clock_gettime(CLOCK_MONOTONIC, &start);

    MPI_Init(NULL, NULL);
    MPI_Comm_rank(MPI_COMM_WORLD, &rank);

    MPI_Count total_size;
    void *buf = NULL;
    if (rank == 0) {
        /* char converted_name[256]; */
        /* char model_dir[2048]; */
        MPI_File src;

        /* convert_slash_to_double_dash(argv[1], converted_name, sizeof(converted_name)); */
        /* snprintf(model_dir, sizeof(model_dir), */
        /*          "/flare/datasets/model-weights/hub/models--%s", converted_name); */

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

        /* create archive first if directory */
        snprintf(command, sizeof(command), "tar -C %s -cf - %s", left, right);
        FILE *archive = popen(command, "r");
        if (!archive) {
            perror("popen");
            MPI_Abort(MPI_COMM_WORLD, 1);
        }
        free(dup);

        MPI_Count buf_size = 16 * 1024 * 1024; // 16 MB chunks
        MPI_Count capacity = buf_size;
        total_size = 0;
        buf = malloc(capacity);
        if (!buf) {
            perror("malloc");
            MPI_Abort(MPI_COMM_WORLD, 1);
        }

        while (!feof(archive)) {
            if (total_size + buf_size > capacity) {
                capacity *= 2;
                buf = realloc(buf, capacity);
                if (!buf) {
                    perror("realloc");
                    MPI_Abort(MPI_COMM_WORLD, 1);
                }
            }
            size_t n = fread(buf + total_size, 1, buf_size, archive);
            total_size += n;
        }

        if (pclose(archive) != 0) {
            perror("pclose");
            MPI_Abort(MPI_COMM_WORLD, 1);
        }

        MPI_Bcast(&total_size, 1, MPI_COUNT, 0, MPI_COMM_WORLD);
    } else {
        MPI_Bcast(&total_size, 1, MPI_COUNT, 0, MPI_COMM_WORLD);
        buf = malloc(total_size);
    }

    /* bcast file to everyone */
    MPI_Bcast_c(buf, total_size, MPI_BYTE, 0, MPI_COMM_WORLD);

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
