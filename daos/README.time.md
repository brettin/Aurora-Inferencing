~~~
Writing to a daos posix mount on /tmp/candle_aesp_CNDA/brettin_posix.

1600 files, 400 each of 10G, 1G, 100M, 10M sizes.

time ./mount_daos_compute.sh 400
real    0m58.420s
user    0m13.084s
sys     0m22.282s

real    0m56.625s
user    0m11.611s
sys     0m6.899s

time mpiexec
real    0m14.552s
user    0m0.030s
sys     0m0.030s

time mpiexec --no-vni -n 400 -ppn 1 ./write_to_mount.sh
real    0m14.552s
user    0m0.030s
sys     0m0.030s

du -skh /tmp/candle_aesp_CNDA/
4.3T    /tmp/candle_aesp_CNDA/

# Seems that time is constant from 2 to 400 nodes at least?
time mpiexec --no-vni -n 2 -ppn 1 ./write_to_mount.sh
real    0m14.578s
user    0m0.000s
sys     0m0.009s

time rm /tmp/candle_aesp_CNDA/brettin_posix/*
real    7m12.694s
user    0m0.049s
sys     0m0.247s
~~~

