#include <sys/stat.h>
#include <stdio.h>
#include <stdlib.h>
#include <mpi.h>

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
    const char *archive = "/tmp/tmp.tar";
    char command[2048];
    int rank;
    MPI_Init(NULL, NULL);
    MPI_Comm_rank(MPI_COMM_WORLD, &rank);

    MPI_Offset size;
    void *buf = NULL;
    if (rank == 0) {
        char converted_name[256];
        char model_dir[2048];
        MPI_File src;

        convert_slash_to_double_dash(argv[1], converted_name, sizeof(converted_name));
        snprintf(model_dir, sizeof(model_dir),
                 "/flare/datasets/model-weights/hub/models--%s", converted_name);

        /* create archive first if directory */
        snprintf(command, sizeof(command), "tar -cf %s %s", archive, model_dir);
        if (system(command) != 0) {
            printf("failed to create directory archive\n");
            MPI_Abort(MPI_COMM_WORLD, 1);
        }

        MPI_File_open(MPI_COMM_SELF, archive, MPI_MODE_RDONLY, MPI_INFO_NULL, &src);
        MPI_File_get_size(src, &size);
        buf = malloc(size);
        MPI_File_read_c(src, buf, size, MPI_BYTE, MPI_STATUS_IGNORE);
        MPI_File_close(&src);
        MPI_Bcast(&size, 1, MPI_OFFSET, 0, MPI_COMM_WORLD);
    } else {
        MPI_Bcast(&size, 1, MPI_OFFSET, 0, MPI_COMM_WORLD);
        buf = malloc(size);
    }

    /* bcast file to everyone */
    MPI_Bcast_c(buf, size, MPI_BYTE, 0, MPI_COMM_WORLD);

    if (rank != 0) {
        MPI_File dest;
        MPI_File_open(MPI_COMM_SELF, archive, MPI_MODE_CREATE | MPI_MODE_RDWR, MPI_INFO_NULL, &dest);
        MPI_File_write_c(dest, buf, size, MPI_BYTE, MPI_STATUS_IGNORE);
        MPI_File_close(&dest);
    }
    free(buf);

    snprintf(command, sizeof(command), "tar -xf %s -C /tmp/ && rm /tmp/tmp.tar", archive);
    if (system(command) != 0) {
        printf("untar command failed\n");
        MPI_Abort(MPI_COMM_WORLD, 1);
    }

    MPI_Finalize();
    return 0;
}
